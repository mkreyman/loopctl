defmodule Loopctl.Knowledge.VectorSearchUnderFillTest do
  @moduledoc """
  US-27.6b: the observable (non-silent) under-fill signal for the `suggested_links`
  vector read (TC-27.6b.2 / TC-27.6b.3, AC-27.6b.2/.5/.6).

  The crux distinction this proves:

    * **under_fill**  — the nearest pool was FILLED to cap but the post-ANN filters
      (already-linked anti-join / threshold) cut the result below `limit`. A
      `[:loopctl, :knowledge, :vector_search, :under_fill]` event fires AND
      `meta.recall_truncated` is true (TC-27.6b.2).
    * **NOT under_fill** — the corpus simply has plenty of unlinked above-threshold
      neighbors and the full `limit` is returned: NO event, `meta.recall_truncated`
      false (TC-27.6b.3). And the genuinely-small-corpus case (returned < limit but
      the pool was NEVER full) is also NOT under_fill.

  The async suite shrinks the over-fetch pool to 6 (config/test.exs) so the pool can
  be deterministically FILLED with a handful of seeded rows — no 100-row corpus and
  no `Application.put_env` in a test body. The dense-hub assertion is ALSO proven at
  prod scale in `vector_search_under_fill_scale_test.exs` (`:scale_nightly`).
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.VectorSearch
  alias Loopctl.TelemetryEvents

  @dims 1536

  # A sparse-prefix embedding (rest zero-filled). Cosine is magnitude-independent, so
  # e([1.0]) vs e([1.0]) = 1.0 (identical direction) — every candidate here is a near
  # neighbor of the target, which is exactly what makes the anti-join the only thing
  # that can cut the result (isolating the under-fill condition).
  defp e(prefix), do: prefix ++ List.duplicate(0.0, @dims - length(prefix))

  defp embedded(tenant_id, title, prefix) do
    a = fixture(:article, %{tenant_id: tenant_id, title: title, status: :published})
    {:ok, _} = Knowledge.update_embedding(tenant_id, a.id, e(prefix))
    a
  end

  defp link!(tenant_id, source_id, target_id) do
    fixture(:article_link, %{
      tenant_id: tenant_id,
      source_article_id: source_id,
      target_article_id: target_id,
      relationship_type: :relates_to
    })
  end

  # Attach a telemetry handler that forwards under_fill events to `self()`, with
  # guaranteed detach (try/after). The handler is process-GLOBAL, so we scope it to
  # events emitted from THIS test process (`self()` inside a telemetry handler is the
  # emitting process, and our `suggest_links_with_meta/3` call runs synchronously in
  # the test process) — otherwise a concurrent async test's under_fill could leak a
  # false event into our mailbox and break `refute_received`.
  defp with_under_fill_handler(fun) do
    test_pid = self()
    handler_id = "under-fill-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      TelemetryEvents.vector_search_under_fill(),
      fn event, measurements, metadata, _ ->
        if self() == test_pid do
          send(test_pid, {:under_fill, event, measurements, metadata})
        end
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  describe "under-fill emits a telemetry signal + meta flag (TC-27.6b.2, AC-27.6b.2/.6)" do
    test "dense hub: nearest pool full but all near neighbors already-linked → signal fires" do
      tenant = fixture(:tenant)
      target = embedded(tenant.id, "Hub", [1.0, 0.0])

      # Fill the (test) 6-row pool: 6 near-identical neighbors so the inner ANN returns
      # a FULL pool. Pre-link ALL of them so the anti-join cuts the result below limit=5.
      neighbors = for i <- 1..6, do: embedded(tenant.id, "N#{i}", [1.0, 0.0])
      for n <- neighbors, do: link!(tenant.id, target.id, n.id)

      # Sanity: the pool is exactly the count we filled (so available >= pool holds).
      assert VectorSearch.pool_size(5) == 6

      {result, meta} =
        with_under_fill_handler(fn ->
          {:ok, suggestions, meta} =
            Knowledge.suggest_links_with_meta(tenant.id, target.id, limit: 5, threshold: 0.5)

          {suggestions, meta}
        end)

      # Fewer than the requested 5 (the anti-join exhausted the full pool).
      assert length(result) < 5

      # The structured signal fired exactly once, with id-only, non-content payload.
      assert_received {:under_fill, event, measurements, metadata}
      assert event == [:loopctl, :knowledge, :vector_search, :under_fill]
      assert measurements.requested == 5
      assert measurements.returned == length(result)
      assert measurements.returned < 5
      assert measurements.pool == 6
      assert measurements.available >= measurements.pool
      # excluded_total is the COMBINED post-ANN exclusion count (anti-join + threshold),
      # a measurement (numeric), NOT a per-reason split (deferred to US-27.15).
      assert measurements.excluded_total == measurements.pool - measurements.returned
      assert measurements.excluded_total >= 1
      assert metadata.tenant_id == tenant.id
      assert metadata.endpoint == :suggested_links

      # Exactly ONE event (AC-27.6b.5: one per request, not per filtered candidate).
      refute_received {:under_fill, _, _, _}

      # No content leaks in the payload (AC-27.6b.5): no vector literals, no bodies.
      flat = inspect({measurements, metadata})
      refute flat =~ "1.0"
      refute flat =~ "embedding"
      refute flat =~ "::vector"

      # Consumer-facing meta carries the recall-truncated flag (AC-27.6b.6).
      assert meta.recall_truncated == true
      assert meta.pool_exhausted == true
      assert meta.requested == 5
      assert meta.returned == length(result)
    end
  end

  describe "a full result emits NO under-fill signal (TC-27.6b.3)" do
    test "plenty of unlinked above-threshold neighbors → k returned, no event, meta false" do
      tenant = fixture(:tenant)
      target = embedded(tenant.id, "Target", [1.0, 0.0])

      # 6 unlinked near-identical neighbors → the full limit of 5 is returned.
      for i <- 1..6, do: embedded(tenant.id, "Free#{i}", [1.0, 0.0])

      {result, meta} =
        with_under_fill_handler(fn ->
          {:ok, suggestions, meta} =
            Knowledge.suggest_links_with_meta(tenant.id, target.id, limit: 5, threshold: 0.5)

          {suggestions, meta}
        end)

      assert length(result) == 5
      refute_received {:under_fill, _, _, _}
      assert meta.recall_truncated == false
      assert meta.pool_exhausted == false
      assert meta.returned == 5
    end
  end

  describe "a genuinely-small corpus is NOT under-fill (AC-27.6b.2 — the key distinction)" do
    test "returned < limit but the pool was NEVER full → no event, meta false" do
      tenant = fixture(:tenant)
      target = embedded(tenant.id, "Target", [1.0, 0.0])

      # Only 2 eligible neighbors exist corpus-wide — fewer than the 6-row pool. This
      # returns < limit (5) but it is a genuinely-empty-ish corpus, NOT a recall
      # incident: the pool was never filled, so NO signal must fire.
      _c1 = embedded(tenant.id, "C1", [1.0, 0.0])
      _c2 = embedded(tenant.id, "C2", [1.0, 0.0])

      {result, meta} =
        with_under_fill_handler(fn ->
          {:ok, suggestions, meta} =
            Knowledge.suggest_links_with_meta(tenant.id, target.id, limit: 5, threshold: 0.5)

          {suggestions, meta}
        end)

      assert length(result) == 2
      assert length(result) < 5

      # Crucially: NO under_fill event despite returned < limit (available < pool).
      refute_received {:under_fill, _, _, _}
      assert meta.recall_truncated == false
      assert meta.pool_exhausted == false
    end

    test "no-embedding target → empty result is NOT under-fill" do
      tenant = fixture(:tenant)

      target =
        fixture(:article, %{tenant_id: tenant.id, title: "No Embedding", status: :published})

      {result, meta} =
        with_under_fill_handler(fn ->
          {:ok, suggestions, meta} =
            Knowledge.suggest_links_with_meta(tenant.id, target.id, limit: 5)

          {suggestions, meta}
        end)

      assert result == []
      refute_received {:under_fill, _, _, _}
      assert meta.recall_truncated == false
    end
  end

  describe "the under-fill probe is a single bounded extra read, gated on the truncated path (AC-27.6b.5)" do
    test "a FULL result issues NO available-count probe; the truncated path adds exactly one" do
      # When returned >= limit there is nothing to detect, so the bounded `count(*)` probe
      # must not run at all. We isolate the probe by counting ONLY the count-aggregate
      # query (its source is the `articles` candidate subquery; the `SELECT count(...)`
      # SQL is the discriminator) — not raw repo events, which carry sandbox noise. Two
      # ISOLATED tenants so each hub's pool contains only its own neighbors.
      t_full = fixture(:tenant)
      target = embedded(t_full.id, "Target", [1.0, 0.0])
      for i <- 1..6, do: embedded(t_full.id, "Free#{i}", [1.0, 0.0])

      full_probes =
        count_probe_queries(fn ->
          {:ok, r, _m} = Knowledge.suggest_links_with_meta(t_full.id, target.id, limit: 5)
          assert length(r) == 5
        end)

      # A separate tenant whose hub has ONLY already-linked neighbors → probe DOES run.
      t_hub = fixture(:tenant)
      hub = embedded(t_hub.id, "Hub", [1.0, 0.0])
      linked = for i <- 1..6, do: embedded(t_hub.id, "L#{i}", [1.0, 0.0])
      for n <- linked, do: link!(t_hub.id, hub.id, n.id)

      under_probes =
        count_probe_queries(fn ->
          with_under_fill_handler(fn ->
            {:ok, r, _m} = Knowledge.suggest_links_with_meta(t_hub.id, hub.id, limit: 5)
            assert length(r) < 5
          end)
        end)

      # The hot (full) path runs ZERO probes; the truncated path runs EXACTLY ONE — a
      # single bounded extra read, never per-candidate.
      assert full_probes == 0, "full-result path must issue no count probe (got #{full_probes})"

      assert under_probes == 1,
             "truncated path must issue exactly one count probe (got #{under_probes})"
    end
  end

  # Count ONLY the under-fill `available_candidate_count` probe queries during `fun`.
  # The probe is the lone `SELECT count(...)` over the candidate subquery on the heavy
  # pool (AdminRepo in test); we discriminate by the decoded SQL. CRITICAL for an async
  # suite: the telemetry handler is process-GLOBAL, so we ALSO scope to queries issued
  # from THIS test process — the handler runs synchronously in the emitting process, so
  # `self()` inside it is the query-issuing process. Without this, a concurrent test's
  # `count(... articles ...)` query would leak into the count and make this flaky.
  defp count_probe_queries(fun) do
    test_pid = self()
    ref = make_ref()
    handler_id = "probe-count-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:loopctl, :admin_repo, :query],
      fn _e, _m, meta, _ ->
        sql = to_string(meta[:query] || "")

        if self() == test_pid and sql =~ ~r/SELECT count\(/i and sql =~ ~r/FROM\b/i and
             sql =~ "articles" do
          send(test_pid, {ref, :probe})
        end
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    drain(ref, 0)
  end

  defp drain(ref, acc) do
    receive do
      {^ref, :probe} -> drain(ref, acc + 1)
    after
      0 -> acc
    end
  end
end
