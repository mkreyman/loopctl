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

    # The ingest verb guards mode explicitly; without the same clause here, searching a
    # client_embedded corpus spent a provider embedding call on the tenant's own key and
    # answered 200 with an empty set for an operation the corpus can never serve.
    test "a client_embedded corpus is refused before any provider call" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id, %{mode: :client_embedded})

      calls = :counters.new(1, [])

      stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _scope, _text, _opts ->
        :counters.add(calls, 1, 1)
        {:ok, List.duplicate(0.01, 1536)}
      end)

      assert {:error, :mode_mismatch} = Search.search(tenant.id, corpus.id, "taxonomy code")
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
    end
  end
end
