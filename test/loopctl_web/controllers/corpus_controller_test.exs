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
  alias LoopctlWeb.CorpusController

  setup :verify_on_exit!

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp keyed_tenant(role \\ :agent) do
    tenant = fixture(:tenant)
    fixture(:tenant_llm_settings, %{tenant_id: tenant.id, embedding_api_key: "test-embed-key"})
    {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: role})
    {tenant, raw_key}
  end

  # US-43.3. Mode B carries a locally-produced vector and the client's own opaque hash.
  defp mode_b_corpus!(tenant_id, attrs \\ %{}) do
    {:ok, corpus} =
      Corpus.create_corpus(
        tenant_id,
        Map.merge(
          %{
            slug: "byo-#{System.unique_integer([:positive])}",
            name: "Client embedded",
            mode: :client_embedded,
            embedding_model: "local-nomic-embed",
            dim: 1536
          },
          attrs
        )
      )

    corpus
  end

  defp mode_b_chunk(tenant_id, attrs \\ %{}) do
    Map.merge(
      %{
        "source_ref" => "spec.pdf",
        "locator" => %{"page" => 1},
        "vector" => mode_b_vector(tenant_id),
        "content_hash" => "client-hash-one",
        "ordinal" => 1
      },
      attrs
    )
  end

  # Per-tenant separation in the shared HNSW index, the convention the corpus search
  # tests already follow.
  defp mode_b_vector(tenant_id) do
    base = rem(:erlang.phash2(tenant_id), 1500)
    hot = MapSet.new(0..7, &(base + &1))

    Enum.map(0..1535, fn i -> if MapSet.member?(hot, i), do: 1.0, else: 0.0 end)
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

    # A bare name asserts "what I carry IS the whole source". On the last batch of a split
    # document that is false, and unguarded it deleted everything the earlier batches
    # wrote — a set-based delete on a `role: :agent` key.
    test "a bare source_complete whose prune would exceed the carried set is refused",
         %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = create_corpus!(tenant.id)

      {:ok, _} =
        Indexer.index_chunks(tenant.id, corpus.id, for(page <- 1..6, do: page_chunk(page)),
          audit: [actor_type: "api_key"]
        )

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{
          "chunks" => [page_chunk(1)],
          "source_complete" => ["a.pdf"]
        })
        |> json_response(422)

      assert body["error"]["code"] == "prune_exceeds_carried"
      assert body["error"]["details"]["would_prune"] == 5
      assert body["error"]["details"]["carried"] == 1

      assert AdminRepo.aggregate(
               from(c in DocumentChunk, where: c.corpus_id == ^corpus.id),
               :count,
               :id
             ) == 6
    end

    # The manifest form: the SAME last-batch request, now declaring the document's whole
    # locator set, keeps what the earlier batches wrote and prunes only the surplus.
    test "a manifest reconciles a document larger than one batch", %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = create_corpus!(tenant.id)

      {:ok, _} =
        Indexer.index_chunks(tenant.id, corpus.id, for(page <- 1..6, do: page_chunk(page)),
          audit: [actor_type: "api_key"]
        )

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{
          # The document lost page 6. This is the batch that COMPLETES the re-index, and
          # it declares the whole surviving locator set.
          "chunks" => [page_chunk(4), page_chunk(5)],
          "source_complete" => [
            %{
              "source_ref" => "a.pdf",
              "locators" => for(page <- 1..5, do: %{"page" => page})
            }
          ]
        })
        |> json_response(200)

      assert body["meta"]["pruned"] == 1
      assert body["meta"]["pruned_by_source"] == %{"a.pdf" => 1}

      assert AdminRepo.aggregate(
               from(c in DocumentChunk, where: c.corpus_id == ^corpus.id),
               :count,
               :id
             ) == 5
    end

    # It used to take the carried refusal with an EMPTY `missing` list: the caller was
    # told a source it plainly DID carry was not carried, with nothing pointing at the
    # real fault (the type).
    test "a non-list source_complete is refused with its own code", %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = create_corpus!(tenant.id)

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{
          "chunks" => [page_chunk(1)],
          "source_complete" => "a.pdf"
        })
        |> json_response(422)

      assert body["error"]["code"] == "source_complete_invalid"
      assert body["error"]["details"]["received"] =~ "a.pdf"

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

    # A per-ITEM charge that walks the bucket item by item spends the tenant's remaining
    # budget on a request it is going to refuse anyway: with 100 of 240 consumed, a
    # 200-chunk batch used to charge 140 tokens, be denied at 141, write NOTHING, and
    # leave the tenant unable to afford even a one-chunk request it could have made. The
    # first call's post-increment count IS the headroom, so the batch is now decided
    # before the rest of it is charged.
    test "a batch that cannot fit the remaining budget is refused after ONE charge",
         %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = create_corpus!(tenant.id)

      counters = :counters.new(1, [])

      stub(Loopctl.MockRateLimiter, :check_rate, fn bucket, _window, _limit ->
        if String.starts_with?(bucket, "corpus_index:tenant:") do
          :counters.add(counters, 1, 1)
          # 100 already spent this minute against the default 240 cap.
          {:allow, 100 + :counters.get(counters, 1)}
        else
          {:allow, 1}
        end
      end)

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{
          "chunks" => for(page <- 1..200, do: page_chunk(page))
        })
        |> json_response(429)

      assert body["error"]["code"] == "rate_limited"
      # ONE token, the same one every refused request on every other bucket spends —
      # not 140.
      assert :counters.get(counters, 1) == 1
      assert AdminRepo.all(from(c in DocumentChunk, where: c.corpus_id == ^corpus.id)) == []
    end

    # Under `RATE_LIMITER=postgres` the limiter store IS `AdminRepo`, so a per-ITEM charge
    # turned ONE ordinary index request into up to `max_batch_size` sequential upserts on
    # a single hot row, taken from the 3-connection BYPASSRLS pool that also carries
    # custody writes — before the request did any work. The pin is a PURE function of the
    # configured impl precisely so it is testable: in the test env `RateLimiter.impl/0` is
    # always the Mox mock, so the clause would otherwise be dead code.
    test "the per-item index bucket is pinned away from the AdminRepo-backed limiter" do
      assert CorpusController.index_meter(Loopctl.RateLimiter.Postgres) ==
               Loopctl.RateLimiter.default_impl()

      assert CorpusController.index_meter(Loopctl.MockRateLimiter) == Loopctl.MockRateLimiter
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

    # TC-43.3.3 at the HTTP boundary: an agent reads an empty 200 as an empty corpus, so
    # a query STRING against a mode B corpus is a coded 422 naming what to send instead.
    test "a query string against a client_embedded corpus is a coded 422, not an empty 200",
         %{conn: conn} do
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

      assert body["error"]["code"] == "query_string_not_accepted"
      assert body["error"]["message"] =~ "query_vector"
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

    # The REQUEST side of the same bound. The spec declared `snippet.maxLength` and
    # nothing enforced it — the router mounts no `CastAndValidate`, and neither the
    # changeset nor the indexer looked at the length — so a 50 KB snippet was accepted
    # and stored verbatim against a cap the server did not have. Read out of the
    # GENERATED spec and held against a real request, so it cannot pass on a
    # both-sides-read-one-attribute tautology.
    test "the snippet maxLength in the request schema is a bound the server enforces",
         %{conn: conn} do
      spec = Loopctl.ApiSpec.spec()

      # US-43.3 gave `chunks.items` a `oneOf` (one item shape per corpus mode); this is
      # the server_embedded arm, which is what the mode A request below sends.
      server_schema =
        spec.paths["/api/v1/corpora/{id}/index"].post.requestBody.content["application/json"].schema.properties.chunks.items.oneOf
        |> Enum.find(&(&1.title == "ServerEmbeddedChunk"))

      documented = server_schema.properties.snippet.maxLength

      assert is_integer(documented) and documented > 0

      {tenant, raw_key} = keyed_tenant()
      corpus = create_corpus!(tenant.id)
      over = String.duplicate("y", documented + 1)

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{
          "chunks" => [Map.put(page_chunk(1), "snippet", over)]
        })
        |> json_response(422)

      assert body["error"]["code"] == "invalid_chunk"
      assert body["error"]["details"]["errors"]["snippet"] != nil
      assert AdminRepo.all(from(c in DocumentChunk, where: c.corpus_id == ^corpus.id)) == []
    end

    test "the manifest maxItems in the OpenAPI document is the enforced ceiling" do
      spec = Loopctl.ApiSpec.spec()

      [_string_form, object_form] =
        spec.paths["/api/v1/corpora/{id}/index"].post.requestBody.content["application/json"].schema.properties.source_complete.items.oneOf

      assert object_form.properties.locators.maxItems == Indexer.max_source_manifest()
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

  # --- US-43.3: mode B over HTTP ---

  describe "mode B ingest (US-43.3)" do
    test "accepts vector chunks and refuses text, a wrong-length vector and a snippet",
         %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = mode_b_corpus!(tenant.id)

      ok =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{
          "chunks" => [mode_b_chunk(tenant.id)]
        })
        |> json_response(200)

      assert [%{"status" => "inserted"}] = ok["data"]

      with_text = Map.put(mode_b_chunk(tenant.id), "text", "loop 2310B rendering provider")

      refused =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{"chunks" => [with_text]})
        |> json_response(422)

      assert refused["error"]["code"] == "text_not_accepted"
      assert refused["error"]["message"] =~ "client_embedded"

      short = Map.put(mode_b_chunk(tenant.id), "vector", List.duplicate(0.0, 768))

      mismatch =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{"chunks" => [short]})
        |> json_response(422)

      assert mismatch["error"]["code"] == "vector_dimension_mismatch"
      assert mismatch["error"]["details"]["received_dim"] == 768
      assert mismatch["error"]["details"]["corpus_dim"] == 1536

      snippetted = Map.put(mode_b_chunk(tenant.id), "snippet", "an excerpt")

      forbidden =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{"chunks" => [snippetted]})
        |> json_response(422)

      assert forbidden["error"]["code"] == "snippets_not_allowed"
    end

    test "a missing content_hash is a coded 422", %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = mode_b_corpus!(tenant.id)
      chunk = Map.delete(mode_b_chunk(tenant.id), "content_hash")

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{"chunks" => [chunk]})
        |> json_response(422)

      assert body["error"]["code"] == "invalid_chunk"
      assert body["error"]["message"] =~ "content_hash is required"
    end
  end

  describe "mode B ingest rejects a vector pgvector cannot store" do
    # `Pgvector.Ecto.Vector` DISCARDS an out-of-float32-range element on cast instead of
    # erroring, so the item reached the changeset one element short and the request
    # failed as a 500 corpus_write_failed naming numbers the caller never sent.
    test "an out-of-float32-range element is a coded 422 naming the element", %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = mode_b_corpus!(tenant.id)

      vector = List.replace_at(mode_b_vector(tenant.id), 5, -1.0e40)

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{
          "chunks" => [mode_b_chunk(tenant.id, %{"vector" => vector})]
        })
        |> json_response(422)

      assert body["error"]["code"] == "vector_out_of_range"
      assert body["error"]["details"] == %{"index" => 0, "element_index" => 5}

      assert AdminRepo.aggregate(
               from(c in DocumentChunk, where: c.corpus_id == ^corpus.id),
               :count,
               :id
             ) == 0
    end
  end

  describe "mode B search (US-43.3)" do
    test "a query vector answers pointers and names the semantic lane alone", %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = mode_b_corpus!(tenant.id)

      conn
      |> auth(raw_key)
      |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{"chunks" => [mode_b_chunk(tenant.id)]})
      |> json_response(200)

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/search", %{
          "query_vector" => mode_b_vector(tenant.id)
        })
        |> json_response(200)

      assert [%{"source_ref" => "spec.pdf", "snippet" => nil}] = body["data"]
      assert body["meta"]["lanes"] == ["semantic"]
      assert body["meta"]["search_mode"] == "semantic_only"
    end

    test "a wrong-length query vector is a coded 422 naming both dimensions", %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = mode_b_corpus!(tenant.id)

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/search", %{
          "query_vector" => List.duplicate(0.0, 768)
        })
        |> json_response(422)

      assert body["error"]["code"] == "query_vector_dimension_mismatch"
      assert body["error"]["details"] == %{"received_dim" => 768, "corpus_dim" => 1536}
    end

    test "asking for the keyword lane on a mode B corpus is a coded 422", %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = mode_b_corpus!(tenant.id)

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/search", %{
          "query_vector" => mode_b_vector(tenant.id),
          "lanes" => ["keyword"]
        })
        |> json_response(422)

      assert body["error"]["code"] == "keyword_lane_unavailable"
      assert body["error"]["message"] =~ "semantic"
    end

    test "a query vector against a mode A corpus is a coded 422", %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = create_corpus!(tenant.id)

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/search", %{
          "query_vector" => mode_b_vector(tenant.id)
        })
        |> json_response(422)

      assert body["error"]["code"] == "query_vector_not_accepted"
      assert body["error"]["message"] =~ "query"
    end

    # pgvector's element type is float32. Postgres RAISES on a larger value
    # (`infinite value not allowed in vector`), which the DB backstop renders as an
    # opaque 500 — a caller-side input error answered with a server error.
    test "an out-of-float32-range query vector is a coded 422, not a 500", %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = mode_b_corpus!(tenant.id)

      vector = List.replace_at(mode_b_vector(tenant.id), 3, 1.0e40)

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/search", %{"query_vector" => vector})
        |> json_response(422)

      assert body["error"]["code"] == "query_vector_out_of_range"
      assert body["error"]["details"] == %{"index" => 3}
    end
  end

  # The dispatch defects the enhanced review found: a search must be routed by the VALUE
  # of query_vector, and a lane set that leaves the semantic lane alone must not leak a
  # raw provider term into the FallbackController.
  describe "search dispatch and lane-failure coding" do
    # Emitting `null` for an absent optional is ordinary client serialization. Matching
    # the KEY sent this valid mode A request down the mode B path, where it was refused
    # with a message telling the caller to send the `query` it had already sent.
    test "an explicit query_vector null on a mode A corpus is a normal search", %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = create_corpus!(tenant.id)

      {:ok, _result} =
        Indexer.index_chunks(tenant.id, corpus.id, [page_chunk(1, "taxonomy code")],
          audit: [actor_type: "api_key"]
        )

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/search", %{
          "query" => "taxonomy code",
          "query_vector" => nil
        })
        |> json_response(200)

      assert [%{"source_ref" => "a.pdf"}] = body["data"]
    end

    # The mirror serialization case: a client without omitempty sends `query: ""`
    # alongside the vector it means.
    test "an empty query string alongside a query vector still runs the vector search",
         %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = mode_b_corpus!(tenant.id)

      conn
      |> auth(raw_key)
      |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{"chunks" => [mode_b_chunk(tenant.id)]})
      |> json_response(200)

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/search", %{
          "query" => "",
          "query_vector" => mode_b_vector(tenant.id)
        })
        |> json_response(200)

      assert [%{"source_ref" => "spec.pdf"}] = body["data"]
      assert body["meta"]["lanes"] == ["semantic"]
    end

    # Both given is genuinely ambiguous, and silently preferring the vector answered a
    # search the caller did not ask for.
    test "both query and query_vector given is a coded 422", %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = mode_b_corpus!(tenant.id)

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/search", %{
          "query" => "taxonomy",
          "query_vector" => mode_b_vector(tenant.id)
        })
        |> json_response(422)

      assert body["error"]["code"] == "ambiguous_query"
    end

    # The semantic lane asked for ALONE and failing leaves no degraded answer. The raw
    # provider reason has no FallbackController clause, so returning it verbatim raised
    # a FunctionClauseError and answered 500.
    test "a semantic-only request whose embedding fails is a coded 502", %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = create_corpus!(tenant.id)

      {:ok, _result} =
        Indexer.index_chunks(tenant.id, corpus.id, [page_chunk(1, "taxonomy code")],
          audit: [actor_type: "api_key"]
        )

      stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _scope, _text, _opts ->
        {:error, :circuit_open}
      end)

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/search", %{
          "query" => "taxonomy",
          "lanes" => ["semantic"]
        })
        |> json_response(502)

      assert body["error"]["code"] == "semantic_lane_unavailable"
      assert body["error"]["details"] == %{"reason" => "circuit_open"}
    end

    # The same failure with the keyword lane still available is a DEGRADATION, not an
    # error — the behaviour this fix must not have changed.
    test "the same embedding failure with both lanes still degrades to keyword-only",
         %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = create_corpus!(tenant.id)

      {:ok, _result} =
        Indexer.index_chunks(tenant.id, corpus.id, [page_chunk(1, "taxonomy code")],
          audit: [actor_type: "api_key"]
        )

      stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _scope, _text, _opts ->
        {:error, :circuit_open}
      end)

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/search", %{"query" => "taxonomy code"})
        |> json_response(200)

      assert body["meta"]["lanes"] == ["keyword"]
      assert body["meta"]["semantic_unavailable_reason"] == "circuit_open"
    end
  end

  # The mode B half of TC-43.2.5's discipline: the DOCUMENTED shape is read out of the
  # GENERATED spec, and its bounds are the attributes the runtime enforces.
  describe "the OpenAPI document describes mode B as it is enforced" do
    test "the client_embedded chunk schema has no text property and states the hash contract" do
      spec = Loopctl.ApiSpec.spec()

      chunks =
        spec.paths["/api/v1/corpora/{id}/index"].post.requestBody.content["application/json"].schema.properties.chunks

      assert chunks.maxItems == Indexer.max_batch_size()

      client_schema =
        Enum.find(chunks.items.oneOf, &(&1.title == "ClientEmbeddedChunk"))

      assert client_schema
      # There is NO parameter that accepts chunk text in mode B (AC-43.3.1).
      refute Map.has_key?(client_schema.properties, :text)
      assert :vector in Map.keys(client_schema.properties)
      assert :content_hash in client_schema.required
      assert client_schema.properties.snippet.maxLength == Search.max_snippet_chars()

      # AC-43.3.2 — the honesty the story requires, stated where a caller reads it.
      assert client_schema.description =~ "opaque idempotency token"
      assert client_schema.description =~ "cannot verify"
    end

    test "the search schema documents query_vector and says why mode B is semantic-only" do
      spec = Loopctl.ApiSpec.spec()
      search = spec.paths["/api/v1/corpora/{id}/search"].post
      request = search.requestBody.content["application/json"].schema

      assert :query_vector in Map.keys(request.properties)
      assert request.properties.lanes.items.enum == Search.lanes()
      assert search.description =~ "SEMANTIC-ONLY"
      assert search.description =~ "no text to index"
      assert search.description =~ "query_string_not_accepted"
    end

    # A status a caller can meet must be a status the document names. The 502 is
    # reachable whenever the semantic lane is the only lane attempted, which the new
    # `lanes` parameter made askable on a mode A corpus too.
    test "the statuses and codes a search can answer with are the documented ones" do
      spec = Loopctl.ApiSpec.spec()
      search = spec.paths["/api/v1/corpora/{id}/search"].post

      assert 502 in Map.keys(search.responses)
      assert search.responses[502].description =~ "semantic_lane_unavailable"
      assert search.responses[422].description =~ "ambiguous_query"
      assert search.responses[422].description =~ "query_vector_out_of_range"
    end

    # The float32 element bound is BOTH documented and enforced, so both sides read the
    # one attribute — and the documented number is then held against a real refusal so
    # the assertion is not a both-sides-read-one-attribute tautology.
    test "the documented float32 element bound is the one the ingest enforces", %{conn: conn} do
      spec = Loopctl.ApiSpec.spec()

      client_schema =
        spec.paths["/api/v1/corpora/{id}/index"].post.requestBody.content["application/json"].schema.properties.chunks.items.oneOf
        |> Enum.find(&(&1.title == "ClientEmbeddedChunk"))

      documented = client_schema.properties.vector.description

      assert documented =~ to_string(DocumentChunkEmbedding.float32_max())

      {tenant, raw_key} = keyed_tenant()
      corpus = mode_b_corpus!(tenant.id)

      over = DocumentChunkEmbedding.float32_max() * 10
      vector = List.replace_at(mode_b_vector(tenant.id), 0, over)

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{
          "chunks" => [mode_b_chunk(tenant.id, %{"vector" => vector})]
        })
        |> json_response(422)

      assert body["error"]["code"] == "vector_out_of_range"

      # And a value just INSIDE the documented bound is accepted, so the assertion above
      # is a boundary and not a blanket refusal.
      inside = List.replace_at(mode_b_vector(tenant.id), 0, 1.0e38)

      conn
      |> auth(raw_key)
      |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{
        "chunks" => [mode_b_chunk(tenant.id, %{"vector" => inside})]
      })
      |> json_response(200)
    end
  end
end
