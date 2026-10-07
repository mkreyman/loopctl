defmodule Loopctl.HeavyReadAnnDisclosureTest do
  @moduledoc """
  The iterative-scan disclosure (`HeavyRead.iterative_scan_meta/1`) end to end: what
  `Knowledge.search_semantic/3`, `Knowledge.suggest_links_with_meta/2` and
  `Memory.recall/2` put in their response `meta` when the node's capability verdict says
  the ANN read ran without `hnsw.iterative_scan`. The unit-level disclosure tests, which
  build their opts from namespaces of their own, are in `Loopctl.HeavyReadHnswEfSearchTest`.

  ## Why `async: false`

  These reads build their `HeavyRead` opts inside `Knowledge`/`Memory` from the NODE-WIDE
  `SystemConfig` keys and the node's probe verdict — what production does — so the only way
  to put a read into the degraded state is to prime those node-wide keys, which every
  concurrent ANN reader also reads. Threading a config namespace through the public read
  APIs for these tests alone is the contortion the rule exempts; the subject here is the
  node's verdict reaching the response.
  """
  use Loopctl.DataCase, async: false

  alias Loopctl.Embeddings
  alias Loopctl.Knowledge
  alias Loopctl.Memory

  setup :verify_on_exit!

  describe "iterative-scan DISCLOSURE on the vector-read response meta" do
    test "the LEGACY semantic response meta carries the disclosure, both states" do
      tenant = fixture(:tenant)
      refute Embeddings.side_table_reads_enabled?(), "precondition: legacy read path"

      prime_iterative_scan(1)
      prime_iterative_scan_supported(false)

      assert {:ok, %{meta: degraded}} = Knowledge.search_semantic(tenant.id, test_vec(1536))
      assert degraded.ann_iterative_scan == "unavailable"
      assert degraded.ann_iterative_scan_reason =~ "may be missing from these results"

      prime_iterative_scan_supported(true)

      assert {:ok, %{meta: healthy}} = Knowledge.search_semantic(tenant.id, test_vec(1536))
      assert healthy.ann_iterative_scan == "applied"

      refute Map.has_key?(healthy, :ann_iterative_scan_reason),
             "a healthy read states the state and adds no degradation prose"
    end

    test "the SUGGESTED-LINKS meta discloses, and the no-embedding short-circuit does not" do
      # `:suggested_links` is an ANN endpoint whose meta already flags one incompleteness
      # cause (`recall_truncated` = the anti-join cutting a FULL pool) and could not name
      # the other: an index batch that never reached this tenant's rows reads as
      # `recall_truncated: false` plus a short list, i.e. "this article has no neighbours".
      # Both halves are pinned — the merge onto a REAL read, and its absence on the
      # short-circuit that runs no vector read at all.
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      prime_iterative_scan(1)
      prime_iterative_scan_supported(false)

      assert {:ok, [], bare} = Knowledge.suggest_links_with_meta(tenant.id, article.id)

      refute Map.has_key?(bare, :ann_iterative_scan),
             "the no-embedding short-circuit runs no vector read and must say nothing"

      {:ok, _} = Knowledge.update_embedding(tenant.id, article.id, test_vec(1536))

      assert {:ok, _suggestions, meta} =
               Knowledge.suggest_links_with_meta(tenant.id, article.id)

      assert meta.ann_iterative_scan == "unavailable"
      assert meta.ann_iterative_scan_reason =~ "may be missing from these results"

      prime_iterative_scan_supported(true)

      assert {:ok, _suggestions, healthy} =
               Knowledge.suggest_links_with_meta(tenant.id, article.id)

      assert healthy.ann_iterative_scan == "applied"
    end

    test "the SIDE-TABLE semantic response meta carries the disclosure too" do
      tenant = fixture(:tenant)
      stub(Loopctl.MockEmbeddingReadPath, :side_table_reads_enabled?, fn -> true end)
      assert Embeddings.side_table_reads_enabled?(), "precondition: side-table read path"

      prime_iterative_scan(1)
      prime_iterative_scan_supported(false)

      assert {:ok, %{meta: meta}} = Knowledge.search_semantic(tenant.id, test_vec(1536))
      assert meta.ann_iterative_scan == "unavailable"
    end
  end

  describe "iterative-scan DISCLOSURE on AGENT MEMORY recall (#634)" do
    # `Memory.recall/2` runs the SAME `:memory_recall` ANN through the same `HeavyRead`,
    # with the same post-index residual filter — and disclosed nothing, so an
    # under-returning recall was indistinguishable from a complete one. That is the
    # condition #631 removed from knowledge search, on the surface where a short recall is
    # LEAST likely to be noticed: nothing downstream cross-checks it, and `underfilled`
    # is already true for a genuinely sparse scope.
    test "the semantic recall meta carries the disclosure, both states" do
      scope = fixture(:memory_scope)
      Knowledge.reset_circuit_breaker(scope.tenant_id)
      {:ok, _} = Memory.remember(scope, %{tier: :long_term, text: "ecto multi is atomic"})

      prime_iterative_scan(1)
      prime_iterative_scan_supported(false)

      degraded = Memory.recall(scope, query: "ecto", limit: 5).meta

      assert degraded.ann_iterative_scan == "unavailable"
      assert degraded.ann_iterative_scan_reason =~ "may be missing from these results"
      assert degraded.fallback == false, "precondition: the SEMANTIC path, not the ILIKE one"

      prime_iterative_scan_supported(true)

      healthy = Memory.recall(scope, query: "ecto", limit: 5).meta

      assert healthy.ann_iterative_scan == "applied"

      refute Map.has_key?(healthy, :ann_iterative_scan_reason),
             "a healthy read states the state and adds no degradation prose"
    end

    test "the field names and values MATCH knowledge search exactly" do
      # One vocabulary across both surfaces, not two for the same fact. Asserted by
      # comparing the two metas' disclosure slices under one primed verdict rather than
      # by re-listing the strings. Both slices are asserted NON-EMPTY first: they derive
      # from ONE function, so a rename propagates to both and the equality alone would
      # degenerate to `%{} == %{}` and pass vacuously (the sibling tests above pin the
      # literal key names).
      scope = fixture(:memory_scope)
      Knowledge.reset_circuit_breaker(scope.tenant_id)

      prime_iterative_scan(1)
      prime_iterative_scan_supported(false)

      disclosure_keys = [:ann_iterative_scan, :ann_iterative_scan_reason]

      assert {:ok, %{meta: knowledge_meta}} =
               Knowledge.search_semantic(scope.tenant_id, test_vec(1536))

      memory_meta = Memory.recall(scope, query: "anything", limit: 5).meta

      memory_slice = Map.take(memory_meta, disclosure_keys)

      assert map_size(memory_slice) == length(disclosure_keys),
             "both disclosure keys must be present, or this comparison is vacuous"

      assert memory_slice == Map.take(knowledge_meta, disclosure_keys)
    end

    test "the include_superseded SIDE-TABLE recall discloses NOTHING — it runs no HNSW scan" do
      # `include_superseded: true` drops the `live_denorm` predicate, so no per-dimension
      # PARTIAL index matches and the read plans as a bounded top-k SORT — an exact top-k
      # that cannot under-return. A verdict there describes a scan that never ran, the same
      # rule the ILIKE fallback follows. The LIVE read in the same shape still discloses,
      # which is what keeps this exclusion narrow rather than a blanket opt-out.
      scope = fixture(:memory_scope)
      stub(Loopctl.MockEmbeddingReadPath, :side_table_reads_enabled?, fn -> true end)
      Knowledge.reset_circuit_breaker(scope.tenant_id)

      prime_iterative_scan(1)
      prime_iterative_scan_supported(false)

      meta = Memory.recall(scope, query: "ecto", limit: 5, include_superseded: true).meta

      assert meta.fallback == false, "precondition: the SEMANTIC path"
      refute Map.has_key?(meta, :ann_iterative_scan)

      live = Memory.recall(scope, query: "ecto", limit: 5).meta
      assert live.ann_iterative_scan == "unavailable"
    end

    test "the ILIKE FALLBACK path discloses NOTHING — it runs no vector read" do
      # These opts DO carry the resolved state (`:memory_recall` is an ANN endpoint, so
      # `opts/1` stamps every read on it), so disclosing here is one `Map.merge` away and
      # would be WRONG: the fallback query is a recency-ordered ILIKE that never touches
      # the HNSW index, and an "unavailable" verdict about a scan that was never attempted
      # is a degradation report for nothing. Same rule combined search applies when its
      # semantic half fell back to keyword-only.
      scope = fixture(:memory_scope)

      prime_iterative_scan(1)
      prime_iterative_scan_supported(false)

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _scope, _text ->
        {:error, :provider_unavailable}
      end)

      meta = Memory.recall(scope, query: "ecto", limit: 5).meta

      assert meta.fallback == true, "precondition: the ILIKE fallback path"
      refute Map.has_key?(meta, :ann_iterative_scan)
      refute Map.has_key?(meta, :ann_iterative_scan_reason)
    end
  end

  @probe_cache_key {Loopctl.HeavyRead, :iterative_scan_supported}

  # `provenance` is HOW the cached verdict was reached (`:conclusive` | `:reused` | `:guess`),
  # which is what the disclosure classifies on. Defaults to the non-committal `:reused`.
  # Node-wide, and erased on exit.
  defp prime_iterative_scan_supported(verdict, provenance \\ :reused) do
    :persistent_term.put(
      @probe_cache_key,
      {verdict, System.monotonic_time(:millisecond) + 60_000, provenance}
    )

    on_exit(fn -> :persistent_term.erase(@probe_cache_key) end)
  end

  defp prime_iterative_scan(code) do
    pt_key = {Loopctl.SystemConfig, "hnsw_iterative_scan"}
    :persistent_term.put(pt_key, code)
    on_exit(fn -> :persistent_term.erase(pt_key) end)
  end
end
