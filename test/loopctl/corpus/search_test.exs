defmodule Loopctl.Corpus.SearchTest do
  @moduledoc """
  US-43.2 — `corpus_search`: pointers, two lanes, one fuser.

  Covers TC-43.2.4 (a result carries a bounded snippet and NEVER the chunk body),
  TC-43.2.8 (tenant isolation on search), the lane-naming contract of AC-43.2.5, the
  keyword-only degradation of AC-43.2.10, and the pool-sizing hazard the story names as
  the most likely source of a silently-empty search — a target corpus that is a small
  minority of the tenant's chunk rows.

  Each tenant's mock embedding is a pure function of its `tenant_id`, so tenants occupy
  well-separated points in the shared HNSW index. That separation — not a raised
  `ef_search` — is what keeps recall deterministic here.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.Corpus
  alias Loopctl.Corpus.Indexer
  alias Loopctl.Corpus.Search

  setup :verify_on_exit!

  defp create_corpus!(tenant_id, attrs \\ %{}) do
    seq = System.unique_integer([:positive])

    {:ok, corpus} =
      Corpus.create_corpus(
        tenant_id,
        Map.merge(
          %{
            slug: "guides-#{seq}",
            name: "Companion guides",
            mode: :server_embedded,
            embedding_model: "text-embedding-3-small",
            dim: 1536
          },
          attrs
        )
      )

    corpus
  end

  defp index!(tenant_id, corpus, chunks) do
    {:ok, result} =
      Indexer.index_chunks(tenant_id, corpus.id, chunks, audit: [actor_type: "api_key"])

    result
  end

  # US-43.3. A mode B corpus never receives text: the caller sends the vector it produced
  # locally, and the query arrives as a vector too.
  defp mode_b_corpus!(tenant_id, attrs \\ %{}),
    do: create_corpus!(tenant_id, Map.merge(%{mode: :client_embedded}, attrs))

  defp vector_chunk(tenant_id, source_ref, page, dims, hash, attrs \\ %{}) do
    Map.merge(
      %{
        "source_ref" => source_ref,
        "locator" => %{"page" => page},
        "vector" => client_vector(tenant_id, dims),
        "content_hash" => hash,
        "ordinal" => page
      },
      attrs
    )
  end

  # Each tenant's vectors occupy its OWN contiguous block, so tenants stay well-separated
  # points in the shared HNSW index and recall here is deterministic under `async: true`
  # — the same discipline as the per-tenant mock embeddings above.
  defp client_vector(tenant_id, dims) do
    base = rem(:erlang.phash2(tenant_id), 1500)
    hot = MapSet.new(dims, &(base + &1))

    Enum.map(0..1535, fn i -> if MapSet.member?(hot, i), do: 1.0, else: 0.0 end)
  end

  defp chunk(source_ref, page, text) do
    %{
      "source_ref" => source_ref,
      "locator" => %{"page" => page},
      "text" => text,
      "ordinal" => page
    }
  end

  describe "search/4 result contract (TC-43.2.4)" do
    test "returns pointers with a bounded snippet and never the chunk body" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      body =
        "cardiorespiratory monitoring " <>
          String.duplicate("x", Search.max_snippet_chars() * 4)

      index!(tenant.id, corpus, [chunk("hcpf/837p.pdf", 47, body)])

      {:ok, %{results: [result], meta: meta}} =
        Search.search(tenant.id, corpus.id, "cardiorespiratory monitoring")

      assert result.source_ref == "hcpf/837p.pdf"
      assert result.locator == %{"page" => 47}
      assert result.corpus_id == corpus.id
      assert is_binary(result.chunk_id)
      assert is_number(result.score)

      assert String.length(result.snippet) <= Search.max_snippet_chars()
      assert meta.snippet_max_chars == Search.max_snippet_chars()

      # No field anywhere in the response carries the whole text — the agent is told
      # the file and the page and opens it itself.
      refute inspect(result) =~ body
      refute inspect(meta) =~ body
    end

    test "the corpus can be addressed by slug, and a foreign corpus is a 404" do
      tenant = fixture(:tenant)
      other = fixture(:tenant)
      corpus = create_corpus!(tenant.id)
      index!(tenant.id, corpus, [chunk("a.pdf", 1, "rendering provider taxonomy")])

      assert {:ok, %{results: [_result]}} =
               Search.search(tenant.id, corpus.slug, "rendering provider")

      assert {:error, :not_found} = Search.search(other.id, corpus.id, "rendering provider")
    end

    # Without this clause, searching a client_embedded corpus spent a provider embedding
    # call on the tenant's own key and answered 200 with an empty set for an operation the
    # corpus can never serve. TC-43.3.3: it is a NAMED refusal, not an empty result.
    test "a query string against a client_embedded corpus is refused before any provider call" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id, %{mode: :client_embedded})

      calls = :counters.new(1, [])

      stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _scope, _text, _opts ->
        :counters.add(calls, 1, 1)
        {:ok, List.duplicate(0.01, 1536)}
      end)

      assert {:error, :query_string_not_accepted} =
               Search.search(tenant.id, corpus.id, "taxonomy code")

      assert :counters.get(calls, 1) == 0
    end

    # `allow_snippets` is a corpus POLICY and this is the only place a snippet can reach a
    # caller. Settable-but-inert is the codebase's own named anti-pattern.
    test "a corpus with allow_snippets: false serves pointers with a null snippet" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id, %{allow_snippets: false})

      index!(tenant.id, corpus, [chunk("a.pdf", 1, "rendering provider taxonomy code")])

      {:ok, %{results: [result], meta: meta}} =
        Search.search(tenant.id, corpus.id, "rendering provider")

      assert Map.has_key?(result, :snippet)
      assert result.snippet == nil
      assert meta.allow_snippets == false
      assert result.source_ref == "a.pdf"
      assert result.locator == %{"page" => 1}
    end

    test "an empty or over-long query is refused before any lane runs" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      assert {:error, :empty_query} = Search.search(tenant.id, corpus.id, "   ")

      long = String.duplicate("a", Search.max_query_chars() + 1)
      assert {:error, :query_too_long} = Search.search(tenant.id, corpus.id, long)
    end
  end

  describe "lanes (AC-43.2.5 / AC-43.2.10)" do
    test "meta NAMES the lanes that ran, so a caller never infers the mode from results" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)
      index!(tenant.id, corpus, [chunk("a.pdf", 1, "rendering provider taxonomy code")])

      {:ok, %{meta: meta}} = Search.search(tenant.id, corpus.id, "taxonomy")

      assert meta.lanes == ["keyword", "semantic"]
      assert meta.search_mode == "combined"
      assert meta.score_basis == "rrf"
      refute Map.has_key?(meta, :semantic_unavailable_reason)
    end

    test "a tenant with no embedding key degrades to keyword-only and says why" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)
      index!(tenant.id, corpus, [chunk("a.pdf", 1, "rendering provider taxonomy code")])

      stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _scope, _text, _opts ->
        {:error, :no_api_key}
      end)

      {:ok, %{results: results, meta: meta}} = Search.search(tenant.id, corpus.id, "taxonomy")

      assert meta.lanes == ["keyword"]
      assert meta.search_mode == "keyword_only"
      assert meta.semantic_unavailable_reason == "no_api_key"
      assert length(results) == 1
    end

    test "a query vector at the wrong dimension degrades rather than raising" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)
      index!(tenant.id, corpus, [chunk("a.pdf", 1, "rendering provider taxonomy code")])

      stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _scope, _text, _opts ->
        {:ok, List.duplicate(0.1, 768)}
      end)

      {:ok, %{meta: meta}} = Search.search(tenant.id, corpus.id, "taxonomy")

      assert meta.lanes == ["keyword"]
      assert meta.semantic_unavailable_reason == "dimension_mismatch"
    end

    # The semantic lane asked for ALONE and failing leaves nothing to fuse and no degraded
    # answer. The raw provider reason must never escape: the FallbackController has no
    # clause for one, so returning it verbatim answers 500 instead of a coded refusal.
    test "a semantic-only request whose embedding fails returns a NAMED error" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)
      index!(tenant.id, corpus, [chunk("a.pdf", 1, "rendering provider taxonomy code")])

      stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _scope, _text, _opts ->
        {:error, :no_api_key}
      end)

      assert {:error, {:semantic_lane_unavailable, "no_api_key"}} =
               Search.search(tenant.id, corpus.id, "taxonomy", lanes: ["semantic"])

      # The SAME failure with the keyword lane available is still a degradation, not an
      # error — the behaviour the named term must not have changed.
      assert {:ok, %{meta: %{lanes: ["keyword"]}}} =
               Search.search(tenant.id, corpus.id, "taxonomy")
    end

    test "the semantic lane alone still answers when the query matches no keyword" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)
      index!(tenant.id, corpus, [chunk("a.pdf", 1, "rendering provider taxonomy code")])

      {:ok, %{results: results, meta: meta}} =
        Search.search(tenant.id, corpus.id, "zzzzunmatchableqqq")

      # Keyword matched nothing but RAN, so both lanes are named; the semantic lane is
      # what produced the row.
      assert meta.lanes == ["keyword", "semantic"]
      assert length(results) == 1
    end
  end

  # TC-43.2.8
  describe "tenant isolation" do
    test "one tenant searching another's distinctive phrase gets nothing of theirs" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      corpus_a = create_corpus!(tenant_a.id)
      corpus_b = create_corpus!(tenant_b.id)

      index!(tenant_a.id, corpus_a, [chunk("a.pdf", 1, "alpha corpus ordinary content")])

      index!(tenant_b.id, corpus_b, [
        chunk("b.pdf", 1, "zorbitrandex is tenant B's distinctive phrase")
      ])

      {:ok, %{results: results}} = Search.search(tenant_a.id, corpus_a.id, "zorbitrandex")

      b_chunk_ids =
        Loopctl.AdminRepo.all(
          Ecto.Query.from(c in Loopctl.Corpus.DocumentChunk,
            where: c.tenant_id == ^tenant_b.id,
            select: c.id
          )
        )

      # Not merely "no keyword hit": the SEMANTIC lane ran too, and no cross-tenant
      # chunk id may appear in any field of any result.
      for result <- results do
        refute result.chunk_id in b_chunk_ids
        assert result.corpus_id == corpus_a.id
      end

      refute inspect(results) =~ "zorbitrandex"
    end
  end

  # The story's named hazard: `corpus_id` is a POST-ANN residual, so a target corpus
  # that is a small minority of the tenant's chunk rows is where a pool sized against
  # the tenant comes back empty after filtering.
  describe "a target corpus that is a small minority of the tenant's chunks" do
    test "still returns its own chunks rather than a silently empty set" do
      tenant = fixture(:tenant)
      target = create_corpus!(tenant.id)
      noise = create_corpus!(tenant.id)

      index!(tenant.id, target, [chunk("target.pdf", 1, "rendering provider taxonomy code")])

      index!(
        tenant.id,
        noise,
        for(page <- 1..40, do: chunk("noise.pdf", page, "unrelated filler #{page}"))
      )

      {:ok, %{results: results, meta: meta}} = Search.search(tenant.id, target.id, "taxonomy")

      assert meta.lanes == ["keyword", "semantic"]
      assert [%{source_ref: "target.pdf"}] = results
      refute Map.has_key?(meta, :semantic_under_filled)
    end

    # The version of the case above that CAN fail. The one above cannot: 41 rows against
    # a >=1000-row inner pool can never empty the residual, and the suite's default stub
    # is one vector per TENANT, so every chunk of a tenant sits at the same point and the
    # ANN cannot prefer the noise corpus over the target.
    #
    # Here the noise EXCEEDS the inner pool and every noise vector is strictly nearer the
    # query than the target's, so the pool can only be noise however the planner serves
    # it — an exact sort and an HNSW scan both exclude the target — and the `corpus_id`
    # residual empties it. That is the silently-empty search the story names, and what is
    # asserted is that it is no longer SILENT.
    test "an under-filled semantic lane is named rather than answering an empty set" do
      tenant = fixture(:tenant)
      target = create_corpus!(tenant.id)
      noise = create_corpus!(tenant.id)

      near = fn nudge -> [1.0, nudge] ++ List.duplicate(0.0, 1534) end
      far = [0.0, 0.0, 1.0] ++ List.duplicate(0.0, 1533)

      # Per-CHUNK distinguishable, and keyed on the TEXT so the query and the noise land
      # together while the target's single chunk lands far away.
      vector = fn
        "target " <> _rest -> far
        text -> near.(:erlang.phash2(text, 1000) / 1_000_000)
      end

      stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _scope, texts, _opts ->
        {:ok, Enum.map(texts, vector)}
      end)

      stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _scope, text, _opts ->
        {:ok, vector.(text)}
      end)

      index!(tenant.id, target, [chunk("target.pdf", 1, "target rendering provider")])

      # Above the inner pool, which is at least `max_side_table_ef_search/0` (1000).
      for batch <- Enum.chunk_every(1..1010, 200) do
        index!(
          tenant.id,
          noise,
          for(page <- batch, do: chunk("noise.pdf", page, "filler #{page}"))
        )
      end

      # A query the KEYWORD lane cannot rescue: it matches nothing in either corpus, so
      # what comes back is the semantic lane alone.
      {:ok, %{results: results, meta: meta}} =
        Search.search(tenant.id, target.id, "zorbitrandex")

      assert results == []
      assert meta.semantic_under_filled == true
      assert "semantic" in meta.lanes
    end

    # The discriminator: a corpus that simply holds fewer chunks than the lane pool has
    # NOT under-filled, and reporting every small corpus as degraded would make the
    # signal meaningless.
    test "a corpus smaller than the lane pool is not reported under-filled" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      index!(tenant.id, corpus, [chunk("a.pdf", 1, "rendering provider taxonomy code")])

      {:ok, %{results: results, meta: meta}} = Search.search(tenant.id, corpus.id, "taxonomy")

      assert length(results) == 1
      refute Map.has_key?(meta, :semantic_under_filled)
    end
  end

  # --- US-43.3: mode B retrieval ---

  describe "search_vector/4 on a client_embedded corpus (US-43.3)" do
    # TC-43.3.6 — a known neighbour, ranked. `near` shares the query's whole direction,
    # `mid` half of it, `far` none.
    test "ranks by descending similarity and names the semantic lane ALONE" do
      tenant = fixture(:tenant)
      corpus = mode_b_corpus!(tenant.id)

      index!(tenant.id, corpus, [
        vector_chunk(tenant.id, "spec.pdf", 1, 0..7, "hash-near"),
        vector_chunk(tenant.id, "spec.pdf", 2, 0..15, "hash-mid"),
        vector_chunk(tenant.id, "spec.pdf", 3, 8..15, "hash-far")
      ])

      {:ok, %{results: results, meta: meta}} =
        Search.search_vector(tenant.id, corpus.id, client_vector(tenant.id, 0..7))

      assert Enum.map(results, & &1.locator) == [
               %{"page" => 1},
               %{"page" => 2},
               %{"page" => 3}
             ]

      scores = Enum.map(results, & &1.score)
      assert scores == Enum.sort(scores, :desc)

      # STATED, not discovered: mode B is semantic-only because there is no text lane.
      assert meta.lanes == ["semantic"]
      assert meta.search_mode == "semantic_only"
      refute Map.has_key?(meta, :keyword_unavailable_reason)
    end

    # AC-43.3.7 — a mode B result carries the same pointer fields a mode A one does.
    test "a result carries {source_ref, locator, score, corpus_id, chunk_id} and a null snippet" do
      tenant = fixture(:tenant)
      corpus = mode_b_corpus!(tenant.id)

      index!(tenant.id, corpus, [vector_chunk(tenant.id, "spec.pdf", 47, 0..7, "hash-one")])

      {:ok, %{results: [result], meta: meta}} =
        Search.search_vector(tenant.id, corpus.id, client_vector(tenant.id, 0..7))

      assert result.source_ref == "spec.pdf"
      assert result.locator == %{"page" => 47}
      assert result.corpus_id == corpus.id
      assert is_binary(result.chunk_id)
      assert is_number(result.score)
      # NULL by default: allow_snippets is false for a mode B corpus that did not ask.
      assert Map.has_key?(result, :snippet)
      assert result.snippet == nil
      assert meta.allow_snippets == false
    end

    test "a stored snippet IS returned when the corpus allows them" do
      tenant = fixture(:tenant)
      corpus = mode_b_corpus!(tenant.id, %{allow_snippets: true})

      index!(tenant.id, corpus, [
        vector_chunk(tenant.id, "spec.pdf", 1, 0..7, "hash-one", %{
          "snippet" => "loop 2310B excerpt"
        })
      ])

      {:ok, %{results: [result]}} =
        Search.search_vector(tenant.id, corpus.id, client_vector(tenant.id, 0..7))

      assert result.snippet == "loop 2310B excerpt"
    end

    # TC-43.3.4, read side.
    test "a wrong-length query vector is refused at the boundary, naming both dimensions" do
      tenant = fixture(:tenant)
      corpus = mode_b_corpus!(tenant.id)

      index!(tenant.id, corpus, [vector_chunk(tenant.id, "spec.pdf", 1, 0..7, "hash-one")])

      assert {:error, {:query_vector_dimension_mismatch, 768, 1536}} =
               Search.search_vector(tenant.id, corpus.id, List.duplicate(0.0, 768))

      assert {:error, :invalid_query_vector} =
               Search.search_vector(tenant.id, corpus.id, "not a vector")

      assert {:error, :invalid_query_vector} = Search.search_vector(tenant.id, corpus.id, [])
    end

    # AC-43.3.5 — refused, never an empty set, because an agent reads an empty set as an
    # empty corpus.
    test "asking for the keyword lane on a mode B corpus is refused" do
      tenant = fixture(:tenant)
      corpus = mode_b_corpus!(tenant.id)

      index!(tenant.id, corpus, [vector_chunk(tenant.id, "spec.pdf", 1, 0..7, "hash-one")])

      assert {:error, :keyword_lane_unavailable} =
               Search.search_vector(tenant.id, corpus.id, client_vector(tenant.id, 0..7),
                 lanes: ["keyword"]
               )

      assert {:error, :keyword_lane_unavailable} =
               Search.search_vector(tenant.id, corpus.id, client_vector(tenant.id, 0..7),
                 lanes: ["keyword", "semantic"]
               )

      assert {:ok, %{results: [_result]}} =
               Search.search_vector(tenant.id, corpus.id, client_vector(tenant.id, 0..7),
                 lanes: ["semantic"]
               )

      assert {:error, {:invalid_lanes, ["graph"]}} =
               Search.search_vector(tenant.id, corpus.id, client_vector(tenant.id, 0..7),
                 lanes: ["graph"]
               )
    end

    # pgvector's element type is float32, and Postgres RAISES on a larger value rather
    # than returning an error — refused at the boundary, naming the element, the same way
    # a length mismatch is.
    test "an out-of-float32-range element in the query vector is refused at the boundary" do
      tenant = fixture(:tenant)
      corpus = mode_b_corpus!(tenant.id)

      vector = List.replace_at(client_vector(tenant.id, 0..7), 3, 1.0e40)

      assert {:error, {:query_vector_out_of_range, 3}} =
               Search.search_vector(tenant.id, corpus.id, vector)
    end

    test "a query vector against a mode A corpus is refused by name" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      assert {:error, :query_vector_not_accepted} =
               Search.search_vector(tenant.id, corpus.id, client_vector(tenant.id, 0..7))
    end

    test "a mode B corpus of another tenant is a 404, and its chunks never surface" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      corpus_a = mode_b_corpus!(tenant_a.id)
      corpus_b = mode_b_corpus!(tenant_b.id)

      index!(tenant_a.id, corpus_a, [vector_chunk(tenant_a.id, "a.pdf", 1, 0..7, "hash-a")])
      index!(tenant_b.id, corpus_b, [vector_chunk(tenant_b.id, "b.pdf", 1, 0..7, "hash-b")])

      assert {:error, :not_found} =
               Search.search_vector(tenant_a.id, corpus_b.id, client_vector(tenant_b.id, 0..7))

      # Searching its OWN corpus with tenant B's vector still reaches only tenant A's rows.
      {:ok, %{results: results}} =
        Search.search_vector(tenant_a.id, corpus_a.id, client_vector(tenant_b.id, 0..7))

      for result <- results do
        assert result.corpus_id == corpus_a.id
        assert result.source_ref == "a.pdf"
      end
    end
  end

  # TC-43.3.8 — a caller branches on `meta`, never on which mode answered.
  describe "mode A and mode B answer on ONE shape" do
    test "the result and meta key sets are identical; only meta.lanes differs" do
      tenant = fixture(:tenant)
      mode_a = create_corpus!(tenant.id)
      mode_b = mode_b_corpus!(tenant.id)

      index!(tenant.id, mode_a, [chunk("a.pdf", 1, "rendering provider taxonomy code")])
      index!(tenant.id, mode_b, [vector_chunk(tenant.id, "b.pdf", 1, 0..7, "hash-one")])

      {:ok, %{results: [a_result], meta: a_meta}} =
        Search.search(tenant.id, mode_a.id, "rendering provider")

      {:ok, %{results: [b_result], meta: b_meta}} =
        Search.search_vector(tenant.id, mode_b.id, client_vector(tenant.id, 0..7))

      assert Map.keys(a_result) == Map.keys(b_result)
      assert Map.keys(a_meta) == Map.keys(b_meta)

      assert a_meta.lanes == ["keyword", "semantic"]
      assert b_meta.lanes == ["semantic"]
      assert a_meta.search_mode == "combined"
      assert b_meta.search_mode == "semantic_only"

      # Everything else about the envelope is the same number or the same basis.
      assert a_meta.score_basis == b_meta.score_basis
      assert a_meta.snippet_max_chars == b_meta.snippet_max_chars
      assert a_meta.limit == b_meta.limit
    end

    # The mode A half of the lane contract: `lanes` is honoured there too, so a caller
    # that names one is not silently given both.
    test "a mode A corpus honours a lane restriction" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      index!(tenant.id, corpus, [chunk("a.pdf", 1, "rendering provider taxonomy code")])

      {:ok, %{meta: meta}} =
        Search.search(tenant.id, corpus.id, "rendering provider", lanes: ["keyword"])

      assert meta.lanes == ["keyword"]
      assert meta.search_mode == "keyword_only"
    end
  end
end
