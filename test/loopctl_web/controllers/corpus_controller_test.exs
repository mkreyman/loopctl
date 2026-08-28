defmodule LoopctlWeb.CorpusControllerTest do
  @moduledoc """
  US-43.2 — the corpus tier's HTTP surface.

  Covers TC-43.2.5 (the DOCUMENTED snippet bound, read out of the GENERATED OpenAPI
  document, equals the enforced one), TC-43.2.6 (DELETE is `:user` and an agent key is
  refused), TC-43.2.9 (the index rate limit is charged per ITEM, so a ceiling is reached
  at the item count and not the request count) and AC-43.2.9's two creation-time
  refusals, plus the role gates and the audit-failure rendering.
  """

  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Corpus
  alias Loopctl.Corpus.DocumentChunk
  alias Loopctl.Corpus.DocumentChunkEmbedding
  alias Loopctl.Corpus.Indexer
  alias Loopctl.Corpus.Search

  setup :verify_on_exit!

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp keyed_tenant(role \\ :agent) do
    tenant = fixture(:tenant)
    fixture(:tenant_llm_settings, %{tenant_id: tenant.id, embedding_api_key: "test-embed-key"})
    {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: role})
    {tenant, raw_key}
  end

  defp corpus_body(attrs \\ %{}) do
    seq = System.unique_integer([:positive])

    Map.merge(
      %{
        "slug" => "guides-#{seq}",
        "name" => "Companion guides",
        "mode" => "server_embedded",
        "embedding_model" => "text-embedding-3-small",
        "dim" => 1536
      },
      attrs
    )
  end

  defp create_corpus!(tenant_id) do
    {:ok, corpus} =
      Corpus.create_corpus(tenant_id, %{
        slug: "guides-#{System.unique_integer([:positive])}",
        name: "Companion guides",
        mode: :server_embedded,
        embedding_model: "text-embedding-3-small",
        dim: 1536
      })

    corpus
  end

  defp page_chunk(page, text \\ nil) do
    %{
      "source_ref" => "a.pdf",
      "locator" => %{"page" => page},
      "text" => text || "body of page #{page}",
      "ordinal" => page
    }
  end

  defp only_audit_entry!(tenant_id, action) do
    [entry] =
      AdminRepo.all(
        from(a in Loopctl.Audit.AuditLog,
          where: a.tenant_id == ^tenant_id and a.action == ^action
        )
      )

    entry
  end

  describe "POST /api/v1/corpora" do
    test "creates a corpus for an agent key", %{conn: conn} do
      {_tenant, raw_key} = keyed_tenant()

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora", corpus_body())
        |> json_response(201)

      assert body["data"]["mode"] == "server_embedded"
      assert body["data"]["dim"] == 1536
      assert body["data"]["allow_snippets"] == true
    end

    # AC-43.2.7 — the moduledoc's role table earns `create` its agent role on "audited".
    test "records corpus_created against the calling key", %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora", corpus_body())
        |> json_response(201)

      entry = only_audit_entry!(tenant.id, "corpus_created")

      assert entry.entity_type == "corpus"
      assert entry.entity_id == body["data"]["id"]
      assert entry.actor_type == "api_key"
      assert entry.actor_id
      assert entry.new_state["slug"] == body["data"]["slug"]
    end

    # AC-43.2.9 — the failure moves from first index to creation.
    test "a tenant with no embedding credential is refused with the embedding remediation",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora", corpus_body())
        |> json_response(422)

      assert body["error"]["code"] == "no_embedding_key"
      assert body["error"]["message"] =~ "SERVER-SIDE"
      # The remediation names the EMBEDDING credential, not the Anthropic one — they
      # are different fields and the wrong one sends an agent to provision a key that
      # would not have helped.
      assert body["error"]["remediation"]["missing"] == ["embedding_api_key"]
      assert body["error"]["remediation"]["mcp_tool"]

      assert Corpus.list_corpora(tenant.id) == []
    end

    test "a declared dim that disagrees with the model's native dimension is refused",
         %{conn: conn} do
      {_tenant, raw_key} = keyed_tenant()

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora", corpus_body(%{"dim" => 768}))
        |> json_response(422)

      assert body["errors"]["dim"] || body["error"]
    end

    test "an UNKNOWN model is accepted — nil means cannot-check, never invalid",
         %{conn: conn} do
      {_tenant, raw_key} = keyed_tenant()

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora", corpus_body(%{"embedding_model" => "acme-finetune-v3"}))
        |> json_response(201)

      assert body["data"]["embedding_model"] == "acme-finetune-v3"
    end
  end

  describe "GET /api/v1/corpora and /:id and /:id/status" do
    test "lists, shows and reports per-source status", %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = create_corpus!(tenant.id)

      {:ok, _result} =
        Indexer.index_chunks(tenant.id, corpus.id, [page_chunk(1), page_chunk(2)],
          audit: [actor_type: "api_key"]
        )

      listed = conn |> auth(raw_key) |> get(~p"/api/v1/corpora") |> json_response(200)
      assert [%{"id" => id}] = listed["data"]
      assert id == corpus.id

      shown = conn |> auth(raw_key) |> get(~p"/api/v1/corpora/#{corpus.id}") |> json_response(200)
      assert shown["data"]["status"]["has_sources"] == true

      status =
        conn
        |> auth(raw_key)
        |> get(~p"/api/v1/corpora/#{corpus.slug}/status")
        |> json_response(200)

      assert [%{"source_ref" => "a.pdf", "chunk_count" => 2, "content_hash" => hash}] =
               status["data"]

      assert is_binary(hash)
      assert status["meta"]["has_more"] == false
    end

    test "the status page is BOUNDED — it never returns every source at once", %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = create_corpus!(tenant.id)

      chunks =
        for source <- 1..5 do
          %{"source_ref" => "doc-#{source}.pdf", "locator" => %{"page" => 1}, "text" => "body"}
        end

      {:ok, _result} =
        Indexer.index_chunks(tenant.id, corpus.id, chunks, audit: [actor_type: "api_key"])

      body =
        conn
        |> auth(raw_key)
        |> get(~p"/api/v1/corpora/#{corpus.id}/status?limit=2")
        |> json_response(200)

      assert length(body["data"]) == 2
      assert body["meta"]["has_more"] == true
    end
  end

  # TC-43.2.6
  describe "DELETE /api/v1/corpora/:id" do
    test "an agent key is refused and a user key succeeds, taking chunks and vectors with it",
         %{conn: conn} do
      tenant = fixture(:tenant)
      fixture(:tenant_llm_settings, %{tenant_id: tenant.id, embedding_api_key: "test-embed-key"})
      {agent_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      {user_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      corpus = create_corpus!(tenant.id)

      {:ok, _result} =
        Indexer.index_chunks(tenant.id, corpus.id, [page_chunk(1), page_chunk(2)],
          audit: [actor_type: "api_key"]
        )

      refused =
        conn
        |> auth(agent_key)
        |> delete(~p"/api/v1/corpora/#{corpus.id}")
        |> json_response(403)

      assert refused["error"]["code"] == "insufficient_role"

      assert length(AdminRepo.all(from(c in DocumentChunk, where: c.corpus_id == ^corpus.id))) ==
               2

      assert conn
             |> auth(user_key)
             |> delete(~p"/api/v1/corpora/#{corpus.id}")
             |> json_response(200)

      assert AdminRepo.all(from(c in DocumentChunk, where: c.corpus_id == ^corpus.id)) == []

      assert AdminRepo.all(from(e in DocumentChunkEmbedding, where: e.tenant_id == ^tenant.id)) ==
               []

      # AC-43.2.7 — the one verb that is both set-based and irreversible is the one whose
      # absence from the trail would matter most: it leaves a row naming who destroyed it.
      entry = only_audit_entry!(tenant.id, "corpus_deleted")

      assert entry.entity_id == corpus.id
      assert entry.actor_type == "api_key"
      assert entry.old_state["slug"] == corpus.slug
    end
  end

  describe "POST /api/v1/corpora/:id/index" do
    test "reports per-item status and prunes only the sources named complete", %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = create_corpus!(tenant.id)

      first =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{
          "chunks" => [page_chunk(1), page_chunk(2)]
        })
        |> json_response(200)

      assert Enum.map(first["data"], & &1["status"]) == ["inserted", "inserted"]
      assert first["meta"]["pruned"] == 0

      second =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{
          "chunks" => [page_chunk(1)],
          "source_complete" => ["a.pdf"]
        })
        |> json_response(200)

      assert Enum.map(second["data"], & &1["status"]) == ["unchanged"]
      assert second["meta"]["pruned"] == 1
    end

    test "naming a source the batch does not carry is a coded 422", %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = create_corpus!(tenant.id)

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{
          "chunks" => [page_chunk(1)],
          "source_complete" => ["b.pdf"]
        })
        |> json_response(422)

      assert body["error"]["code"] == "source_complete_not_carried"
      assert body["error"]["details"]["missing"] == ["b.pdf"]
    end

    test "a batch above the published ceiling is a coded 422", %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = create_corpus!(tenant.id)
      oversize = for page <- 1..(Indexer.max_batch_size() + 1), do: page_chunk(page)

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{"chunks" => oversize})
        |> json_response(422)

      assert body["error"]["code"] == "batch_too_large"
      assert body["error"]["message"] =~ Integer.to_string(Indexer.max_batch_size())
    end

    # The rate-limit plug runs BEFORE the action, and the bucket is charged once per
    # ITEM. Without the ceiling in the plug an over-size batch spent the tenant's whole
    # per-minute index budget one item at a time and came back as an opaque 429 — for a
    # request that was invalid on its face, wrote nothing, and reproduced the same 429 on
    # every retry while refusing well-formed batches in the same window.
    test "an over-size batch is refused before the rate limiter is charged at all",
         %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = create_corpus!(tenant.id)
      oversize = for page <- 1..(Indexer.max_batch_size() + 1), do: page_chunk(page)

      charges = :counters.new(1, [])

      stub(Loopctl.MockRateLimiter, :check_rate, fn bucket, _window, _limit ->
        if String.starts_with?(bucket, "corpus_index:tenant:"), do: :counters.add(charges, 1, 1)
        {:allow, 1}
      end)

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{"chunks" => oversize})
        |> json_response(422)

      assert body["error"]["code"] == "batch_too_large"
      assert :counters.get(charges, 1) == 0
    end

    # The index bucket is charged per ITEM; `rate_limit_requests_per_minute` is charged
    # once per REQUEST. Clamping the first to the second put a request count into an item
    # ceiling, so a tenant that lowered the pipeline setting had every full-size batch
    # refused in every window, permanently, with nothing in the 429 naming the cause. The
    # search bucket IS charged per request, so it stays clamped.
    test "the per-ITEM index cap is not clamped to the per-REQUEST pipeline setting",
         %{conn: conn} do
      tenant = fixture(:tenant, %{settings: %{"rate_limit_requests_per_minute" => 60}})
      fixture(:tenant_llm_settings, %{tenant_id: tenant.id, embedding_api_key: "test-embed-key"})
      {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      corpus = create_corpus!(tenant.id)

      seen = :counters.new(2, [])

      stub(Loopctl.MockRateLimiter, :check_rate, fn bucket, _window, limit ->
        cond do
          String.starts_with?(bucket, "corpus_index:tenant:") -> :counters.put(seen, 1, limit)
          String.starts_with?(bucket, "corpus_search:tenant:") -> :counters.put(seen, 2, limit)
          true -> :ok
        end

        {:allow, 1}
      end)

      conn
      |> auth(raw_key)
      |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{"chunks" => [page_chunk(1)]})
      |> json_response(200)

      conn
      |> auth(raw_key)
      |> post(~p"/api/v1/corpora/#{corpus.id}/search", %{"query" => "body of page"})
      |> json_response(200)

      # The published maxItems is the batch ceiling; a per-request setting of 60 must not
      # become the item ceiling.
      assert :counters.get(seen, 1) > Indexer.max_batch_size()
      assert :counters.get(seen, 2) == 60
    end

    # AC-43.2.9 scopes itself honestly: whether the tenant's endpoint actually SERVES
    # the named model is not knowable server-side, so it stays a FIRST-INDEX failure.
    # This is that failure, and it must roll the whole batch back rather than half-write.
    test "a model that returns the wrong dimension fails at first index, writing nothing",
         %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()

      {:ok, corpus} =
        Corpus.create_corpus(tenant.id, %{
          slug: "local-#{System.unique_integer([:positive])}",
          name: "Local model corpus",
          mode: :server_embedded,
          embedding_model: "nomic-embed-text",
          dim: 768
        })

      # The default stub returns 1536-dim vectors: the endpoint is not serving the
      # 768-dimension model the corpus pinned.
      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{"chunks" => [page_chunk(1)]})
        |> json_response(500)

      assert body["error"]["code"] == "corpus_write_failed"
      assert AdminRepo.all(from(c in DocumentChunk, where: c.corpus_id == ^corpus.id)) == []
    end

    # TC-43.2.9
    test "the rate limit is charged per ITEM, so the ceiling is reached at the item count",
         %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = create_corpus!(tenant.id)

      # A limiter that denies once a bucket has been charged more than 5 times. If the
      # limit were charged per REQUEST, ONE request of 8 chunks would spend a single
      # token and be allowed.
      counters = :counters.new(1, [])

      stub(Loopctl.MockRateLimiter, :check_rate, fn bucket, _window, limit ->
        if String.starts_with?(bucket, "corpus_index:tenant:") do
          :counters.add(counters, 1, 1)
          count = :counters.get(counters, 1)
          if count > 5, do: {:deny, limit}, else: {:allow, count}
        else
          {:allow, 1}
        end
      end)

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{
          "chunks" => for(page <- 1..8, do: page_chunk(page))
        })
        |> json_response(429)

      assert body["error"]["code"] == "rate_limited"
      assert :counters.get(counters, 1) == 6
      assert AdminRepo.all(from(c in DocumentChunk, where: c.corpus_id == ^corpus.id)) == []
    end
  end

  describe "POST /api/v1/corpora/:id/search" do
    test "returns pointers with a bounded snippet and names the lanes that ran", %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = create_corpus!(tenant.id)
      long = "taxonomy code " <> String.duplicate("y", Search.max_snippet_chars() * 3)

      {:ok, _result} =
        Indexer.index_chunks(tenant.id, corpus.id, [page_chunk(1, long)],
          audit: [actor_type: "api_key"]
        )

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/search", %{"query" => "taxonomy code"})
        |> json_response(200)

      assert [result] = body["data"]
      assert result["source_ref"] == "a.pdf"
      assert result["locator"] == %{"page" => 1}
      assert String.length(result["snippet"]) <= Search.max_snippet_chars()
      refute result["snippet"] == long
      assert body["meta"]["lanes"] == ["keyword", "semantic"]
    end

    # Both halves of the surface refuse a client_embedded corpus identically: the ingest
    # verb already answered a coded 422 while search spent a provider call and answered
    # 200 with an empty set.
    test "a client_embedded corpus is a coded 422, not an empty 200", %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()

      {:ok, corpus} =
        Corpus.create_corpus(tenant.id, %{
          slug: "byo-#{System.unique_integer([:positive])}",
          name: "Client embedded",
          mode: :client_embedded,
          embedding_model: "text-embedding-3-small",
          dim: 1536
        })

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/search", %{"query" => "taxonomy"})
        |> json_response(422)

      assert body["error"]["code"] == "mode_mismatch"
    end

    test "an empty query is a coded 422", %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = create_corpus!(tenant.id)

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/search", %{"query" => "  "})
        |> json_response(422)

      assert body["error"]["code"] == "empty_query"
    end
  end

  # TC-43.2.5 — read out of the GENERATED spec, never out of the source.
  describe "the documented bounds equal the enforced ones" do
    # Deliberately NOT `documented == Search.max_snippet_chars()` on its own: both sides
    # of that read the same attribute, so it would pass even with the truncation removed
    # entirely. The documented number is read out of the GENERATED spec and then held
    # against what a real response actually returns for a chunk that is far longer.
    test "the snippet maxLength in the OpenAPI document is the bound a real response obeys",
         %{conn: conn} do
      spec = Loopctl.ApiSpec.spec()

      documented =
        spec.paths["/api/v1/corpora/{id}/search"].post.responses[200].content["application/json"].schema.properties.data.items.properties.snippet.maxLength

      assert is_integer(documented) and documented > 0

      {tenant, raw_key} = keyed_tenant()
      corpus = create_corpus!(tenant.id)
      long = "taxonomy code " <> String.duplicate("z", documented * 3)

      {:ok, _result} =
        Indexer.index_chunks(tenant.id, corpus.id, [page_chunk(1, long)],
          audit: [actor_type: "api_key"]
        )

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/search", %{"query" => "taxonomy code"})
        |> json_response(200)

      assert [%{"snippet" => snippet}] = body["data"]
      assert String.length(snippet) == documented
      assert String.length(long) > documented
      assert documented == Search.max_snippet_chars()
    end

    test "the batch maxItems in the OpenAPI document is the enforced batch ceiling" do
      spec = Loopctl.ApiSpec.spec()

      documented =
        spec.paths["/api/v1/corpora/{id}/index"].post.requestBody.content["application/json"].schema.properties.chunks.maxItems

      assert documented == Indexer.max_batch_size()
    end

    test "the corpus endpoints are tagged, not untagged" do
      spec = Loopctl.ApiSpec.spec()

      assert Enum.any?(spec.tags, &(&1.name == "Corpus"))
      assert "Corpus" in spec.paths["/api/v1/corpora"].get.tags
    end
  end
end
