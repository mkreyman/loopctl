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

  alias Loopctl.Egress
  alias Loopctl.Egress.PinCache
  alias Loopctl.Egress.Scope
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.EmbeddingClient
  alias Loopctl.Llm
  alias Loopctl.Llm.Anthropic
  alias Loopctl.Workers.ArticleEmbeddingWorker

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
      assert {:error, :egress_blocked} =
               Knowledge.generate_embedding(tenant.id, "hello", project_id: project.id)

      refute_received {:http_call, :embedding}
    end

    test "an explicit :scope is honoured identically to :project_id",
         %{tenant: tenant, project: project} do
      assert {:error, :egress_blocked} =
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

      assert {:cancel, :egress_blocked} =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"tenant_id" => tenant.id, "article_id" => marked.id}
               })

      refute_received {:http_call, :embedding}

      assert :ok =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"tenant_id" => tenant.id, "article_id" => unmarked.id}
               })

      assert_received {:http_call, :embedding}
    end
  end

  describe "Anthropic.message/5 accepts the scope as its first argument (AC-41.4.2)" do
    test "a project-scoped chat call is refused before the request is built",
         %{tenant: tenant, project: project} do
      assert {:error, :egress_blocked} =
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
    |> Loopctl.AdminRepo.update!()
  end
end
