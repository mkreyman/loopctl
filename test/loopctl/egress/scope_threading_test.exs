defmodule Loopctl.Egress.ScopeThreadingTest do
  @moduledoc """
  US-41.4 (AC-41.4.2) — the egress scope is THREADED through the public embedding
  and chat entry points, not reconstructed as a tenant-only scope at the client.

  `Loopctl.Egress.Policy` resolving most-restrictive-wins is unit-tested in
  `policy_test.exs`. That resolution is worth nothing if no caller ever hands it a
  project: this file drives the REAL clients through the ordinary entry points a
  PROJECT-only marking has to catch — `Knowledge.generate_embedding/3`, the article
  embedding worker (articles carry a nullable `project_id`), and
  `Llm.Anthropic.message/5` — and asserts that a tenant-wide caller in the SAME
  tenant is untouched. Endpoint resolution stays tenant-scoped throughout; only the
  MARKING narrows.
  """

  use Loopctl.DataCase, async: true

  import Mox

  alias Loopctl.AdminRepo
  alias Loopctl.Egress
  alias Loopctl.Egress.PinCache
  alias Loopctl.Egress.Scope
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.EmbeddingClient
  alias Loopctl.Knowledge.ProposalGate
  alias Loopctl.Llm
  alias Loopctl.Llm.Anthropic
  alias Loopctl.Workers.ArticleEmbeddingWorker
  alias Loopctl.Workers.ContentIngestionWorker
  alias Loopctl.Workers.KnowledgeReclassifyWorker

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})

    {:ok, _} =
      Llm.upsert_settings(tenant.id, %{
        "api_key" => "test-anthropic-key-SCOPE",
        "embedding_api_key" => "test-openai-key-SCOPE",
        "embedding_model" => "text-embedding-3-small"
      })

    stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn scope, text ->
      EmbeddingClient.generate_embedding(scope, text)
    end)

    test_pid = self()

    Req.Test.stub(EmbeddingClient, fn conn ->
      send(test_pid, {:http_call, :embedding})

      Req.Test.json(conn, %{"data" => [%{"index" => 0, "embedding" => List.duplicate(0.1, 1536)}]})
    end)

    Req.Test.stub(Anthropic, fn conn ->
      send(test_pid, {:http_call, :anthropic})
      Req.Test.json(conn, %{"content" => [%{"text" => "ok"}], "usage" => %{}})
    end)

    # ONLY the project is marked. The tenant is deliberately left unmarked, so any
    # assertion below that blocks can only be explained by the project scope having
    # actually reached the guard.
    {:ok, _} = Egress.enable_local_only(tenant.id, project.id, acknowledge: true)
    PinCache.invalidate_tenant(tenant.id)
    on_exit(fn -> PinCache.invalidate_tenant(tenant.id) end)

    {:ok, tenant: tenant, project: project}
  end

  describe "Knowledge.generate_embedding/3 (AC-41.4.2)" do
    test "a PROJECT-only marking blocks when the caller supplies the project",
         %{tenant: tenant, project: project} do
      assert {:error, {:egress_blocked, _}} =
               Knowledge.generate_embedding(tenant.id, "hello", project_id: project.id)

      refute_received {:http_call, :embedding}
    end

    test "an explicit :scope is honoured identically to :project_id",
         %{tenant: tenant, project: project} do
      assert {:error, {:egress_blocked, _}} =
               Knowledge.generate_embedding(tenant.id, "hello",
                 scope: Scope.new(tenant.id, project.id)
               )
    end

    test "the SAME tenant's project-less path is unaffected — default-off holds",
         %{tenant: tenant} do
      assert {:ok, embedding} = Knowledge.generate_embedding(tenant.id, "hello")
      assert length(embedding) == 1536
      assert_received {:http_call, :embedding}
    end
  end

  describe "the article embedding worker threads the ARTICLE's project (AC-41.4.2)" do
    test "an article inside the marked project is refused; a tenant-wide article is not",
         %{tenant: tenant, project: project} do
      marked = published_article(tenant.id, %{project_id: project.id})
      unmarked = published_article(tenant.id, %{})

      # AC-41.4.6: the cancel reason NAMES the scope and the offending endpoint.
      assert {:cancel, reason} =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"tenant_id" => tenant.id, "article_id" => marked.id}
               })

      assert reason =~ "egress_blocked"
      assert reason =~ "project:#{project.id}"
      assert reason =~ "api.openai.com"

      refute_received {:http_call, :embedding}

      assert :ok =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"tenant_id" => tenant.id, "article_id" => unmarked.id}
               })

      assert_received {:http_call, :embedding}
    end
  end

  # AC-41.4.9 verbatim: "There is exactly ONE egress policy module and every
  # outbound path consults it: the provider guard, the US-41.2 probe, INGESTION,
  # and (in US-41.5) webhook delivery." Only webhook delivery is deferred by the AC.
  # The ingestion FETCH previously issued a raw `Req.get/1` that consulted only
  # `UrlGuard`, so a local_only scope could still make an outbound request to a
  # tenant-supplied URL.
  describe "the ingestion FETCH consults the ONE policy module (AC-41.4.9)" do
    test "a local_only scope refuses a tenant-supplied URL fetch",
         %{tenant: tenant, project: project} do
      test_pid = self()

      Req.Test.stub(ContentIngestionWorker, fn conn ->
        send(test_pid, {:http_call, :ingest_fetch})
        Req.Test.text(conn, "should never be fetched")
      end)

      assert {:cancel, reason} =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 1,
                 args: %{
                   "tenant_id" => tenant.id,
                   "project_id" => project.id,
                   "source_type" => "web_article",
                   "content_hash" => "hash-#{System.unique_integer([:positive])}",
                   "url" => "https://untrusted.example.com/post"
                 }
               })

      assert reason =~ "egress_blocked"
      assert reason =~ "untrusted.example.com"

      # Nothing left the boundary.
      refute_received {:http_call, :ingest_fetch}
    end
  end

  describe "Anthropic.message/5 accepts the scope as its first argument (AC-41.4.2)" do
    test "a project-scoped chat call is refused before the request is built",
         %{tenant: tenant, project: project} do
      assert {:error, {:egress_blocked, _}} =
               Anthropic.message(
                 Scope.new(tenant.id, project.id),
                 :extraction,
                 fn _model -> %{messages: []} end
               )

      refute_received {:http_call, :anthropic}
    end

    test "a bare tenant_id still means the tenant-wide scope (backwards compatible)",
         %{tenant: tenant} do
      assert {:ok, "ok"} =
               Anthropic.message(tenant.id, :extraction, fn _model -> %{messages: []} end)

      assert_received {:http_call, :anthropic}
    end
  end

  # REGRESSION (review): `Anthropic.message/5` was widened to accept a Scope, but
  # NOT ONE production caller passed one — every chat call site handed it a bare
  # tenant_id, which coerces to the TENANT-wide scope. A project-only marking
  # therefore did not stop extraction, classification, merge or memory promotion
  # from POSTing project content to the provider, and the only test asserting the
  # widened API called `message/5` directly, so the caller-level gap was invisible.
  # These tests assert at the CALLER, where the gap was.
  describe "the CHAT path threads the project scope at every caller (AC-41.4.2)" do
    test "ingestion extraction passes the article's project scope, not a bare tenant_id",
         %{tenant: tenant, project: project} do
      test_pid = self()

      Mox.stub(Loopctl.MockContentExtractor, :extract_from_content, fn scope, _chunk, _opts ->
        send(test_pid, {:extractor_scope, scope})
        {:ok, []}
      end)

      # Inline content: the FETCH is skipped entirely, so this exercises exactly the
      # path that previously reached the extractor with no guard at all.
      ContentIngestionWorker.perform(%Oban.Job{
        id: 2,
        args: %{
          "tenant_id" => tenant.id,
          "project_id" => project.id,
          "source_type" => "web_article",
          "content_hash" => "hash-#{System.unique_integer([:positive])}",
          "content" => "some inline content to extract from"
        }
      })

      assert_received {:extractor_scope, %Scope{project_id: scoped_project}}
      assert scoped_project == project.id
    end

    test "reclassification passes the ARTICLE's project scope", %{
      tenant: tenant,
      project: project
    } do
      article = published_article(tenant.id, %{project_id: project.id})
      test_pid = self()

      Mox.stub(Loopctl.MockCategoryClassifier, :classify, fn scope, _title, _body, _opts ->
        send(test_pid, {:classifier_scope, scope})
        {:error, :unparseable_classification}
      end)

      KnowledgeReclassifyWorker.perform(%Oban.Job{
        args: %{"tenant_id" => tenant.id, "batch_size" => 10}
      })

      assert_received {:classifier_scope, %Scope{project_id: scoped_project}}
      assert scoped_project == project.id
      assert article.project_id == project.id
    end

    test "merge synthesis runs under the MOST RESTRICTIVE of the two articles' scopes",
         %{tenant: tenant, project: project} do
      marked = published_article(tenant.id, %{project_id: project.id})
      unmarked = published_article(tenant.id, %{})
      test_pid = self()

      Mox.stub(Loopctl.MockMergeSynthesizer, :synthesize, fn scope, _a, _b ->
        send(test_pid, {:merge_scope, scope})
        {:error, :unparseable_merge}
      end)

      %ArticleLink{tenant_id: tenant.id}
      |> ArticleLink.changeset(%{
        source_article_id: unmarked.id,
        target_article_id: marked.id,
        relationship_type: :potential_conflict,
        metadata: %{"auto_generated" => true, "similarity_score" => 0.95}
      })
      |> AdminRepo.insert!()

      # Recorded as an orchestrator: `:high` is granted from the recording role, and it is
      # the confidence the nightly executor acts on — an agent-recorded verdict is capped
      # to `:medium` and never reaches the synthesizer.
      {:ok, resolution} =
        Knowledge.annotate_conflict(
          tenant.id,
          %{
            "source_article_id" => unmarked.id,
            "target_article_id" => marked.id,
            "disposition" => "merge",
            "authoritative_article_id" => marked.id,
            "confidence" => "high"
          },
          actor_role: :orchestrator
        )

      Knowledge.execute_conflict_resolutions(tenant.id, limit: 10)

      assert_received {:merge_scope, %Scope{project_id: scoped_project}}
      # The tenant-wide article must NOT relax the marked article's project scope.
      assert scoped_project == project.id
      assert resolution.disposition == :merge
    end

    test "the novelty gate embeds the PROPOSAL's own project scope",
         %{tenant: tenant, project: project} do
      # The gate runs synchronously on the write path and falls OPEN, so a refusal
      # here is silent — the only way to see the scope is at the embedding call.
      assert %{verdict: :unknown} =
               ProposalGate.assess(tenant.id, %{
                 "title" => "Proposed",
                 "body" => "Body",
                 "project_id" => project.id
               })

      refute_received {:http_call, :embedding}
    end
  end

  defp published_article(tenant_id, attrs) do
    base = %{
      title: "Scoped #{System.unique_integer([:positive])}",
      body: "Body #{System.unique_integer([:positive])}",
      category: :pattern,
      status: :draft
    }

    {:ok, article} = Knowledge.create_article(tenant_id, Map.merge(base, attrs))

    article
    |> Ecto.Changeset.change(%{status: :published})
    |> AdminRepo.update!()
  end
end
