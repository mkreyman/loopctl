defmodule Loopctl.Knowledge.RetrievalMetricsTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.RetrievalMetrics
  alias Loopctl.Knowledge.RetrievalMetricSnapshot

  @day ~D[2026-06-15]

  defp at(time), do: DateTime.new!(@day, time, "Etc/UTC")

  defp event(tenant_id, api_key_id, article_id, type, time) do
    fixture(:article_access_event, %{
      tenant_id: tenant_id,
      api_key_id: api_key_id,
      article_id: article_id,
      access_type: type,
      accessed_at: at(time)
    })
  end

  # One SEARCH CALL surfacing `article_ids` — the batch shape
  # `Analytics.record_search_access/6` writes: one row per surfaced result, every row
  # carrying the SAME `search_id` and the call's true `results_returned`.
  defp search_call(tenant_id, api_key_id, article_ids, time, opts \\ []) do
    search_id = Keyword.get(opts, :search_id, Ecto.UUID.generate())
    results_returned = Keyword.get(opts, :results_returned, length(article_ids))

    Enum.each(article_ids, fn article_id ->
      fixture(:article_access_event, %{
        tenant_id: tenant_id,
        api_key_id: api_key_id,
        article_id: article_id,
        access_type: "search",
        metadata: %{"search_id" => search_id, "results_returned" => results_returned},
        accessed_at: at(time)
      })
    end)

    search_id
  end

  setup do
    tenant = fixture(:tenant)
    {_raw, key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
    x = fixture(:article, %{tenant_id: tenant.id, status: :published})
    y = fixture(:article, %{tenant_id: tenant.id, status: :published})
    %{tenant: tenant, key: key, x: x, y: y}
  end

  describe "compute/3" do
    test "precision = searched results that were opened within the window", ctx do
      %{tenant: t, key: k, x: x, y: y} = ctx
      # X: searched then opened 10 min later (within the 30-min window) → follow-through.
      event(t.id, k.id, x.id, "search", ~T[12:00:00])
      event(t.id, k.id, x.id, "get", ~T[12:10:00])
      # Y: searched, never opened → miss.
      event(t.id, k.id, y.id, "search", ~T[12:00:00])

      m = RetrievalMetrics.compute(t.id, @day, 1800)
      assert m.searched == 2
      assert m.followed_through == 1
      assert m.precision == 0.5
    end

    test "#569: a DRILL is follow-through — the heat-index split must not regress precision",
         ctx do
      # `"drill"` was carved out of `"get"` so `heat_index/2` cannot rank on reads it caused
      # itself. That split is about the RANKING; this metric asks a different question — was a
      # body DELIVERED after a search — and a drill delivers one. Omitting it here would
      # silently under-report follow-through by exactly the reads that changed type, and it
      # would look like a precision regression on the day the split shipped rather than a
      # definition change. The two access-type sets diverge on purpose; this pins the
      # divergence in the direction that is easy to get wrong by omission.
      %{tenant: t, key: k, x: x, y: y} = ctx
      event(t.id, k.id, x.id, "search", ~T[12:00:00])
      event(t.id, k.id, x.id, "drill", ~T[12:10:00])
      event(t.id, k.id, y.id, "search", ~T[12:00:00])

      m = RetrievalMetrics.compute(t.id, @day, 1800)
      assert m.searched == 2
      assert m.followed_through == 1
      assert m.precision == 0.5
    end

    test "an open OUTSIDE the window does not count", ctx do
      %{tenant: t, key: k, x: x} = ctx
      event(t.id, k.id, x.id, "search", ~T[12:00:00])
      event(t.id, k.id, x.id, "get", ~T[13:00:00])

      m = RetrievalMetrics.compute(t.id, @day, 1800)
      assert m.searched == 1
      assert m.followed_through == 0
    end

    test "an open by a DIFFERENT api_key does not count", ctx do
      %{tenant: t, key: k, x: x} = ctx
      {_raw, other} = fixture(:api_key, %{tenant_id: t.id, role: :agent})
      event(t.id, k.id, x.id, "search", ~T[12:00:00])
      event(t.id, other.id, x.id, "get", ~T[12:05:00])

      assert RetrievalMetrics.compute(t.id, @day, 1800).followed_through == 0
    end

    test "context access also counts as a follow-through", ctx do
      %{tenant: t, key: k, x: x} = ctx
      event(t.id, k.id, x.id, "search", ~T[12:00:00])
      event(t.id, k.id, x.id, "context", ~T[12:05:00])

      assert RetrievalMetrics.compute(t.id, @day, 1800).followed_through == 1
    end

    test "no searches → precision 0.0, no error", ctx do
      %{tenant: t} = ctx
      m = RetrievalMetrics.compute(t.id, @day, 1800)

      assert m == %{
               day: @day,
               window_seconds: 1800,
               searched: 0,
               results_surfaced: 0,
               followed_through: 0,
               precision: 0.0,
               searches: 0,
               searches_with_follow_through: 0,
               search_follow_through: 0.0,
               results_returned: 0,
               curated_searched: 0,
               curated_followed_through: 0,
               curated_precision: 0.0,
               retrieved_searched: 0,
               retrieved_followed_through: 0,
               retrieved_precision: 0.0
             }
    end
  end

  describe "compute/3 - which denominator is which (#582)" do
    test "ONE search surfacing 3 results with 1 open is precision 1/3 AND search_follow_through 1.0",
         ctx do
      # THE test whose absence let #582 live. `precision` is per SURFACED RESULT
      # (3 rows, 1 opened) and `search_follow_through` is per SEARCH CALL (1 call, it
      # led to an open). Reading either number as the other is the reported bug; this
      # pins both denominators to the same events so re-defining EITHER fails here.
      %{tenant: t, key: k, x: x, y: y} = ctx
      z = fixture(:article, %{tenant_id: t.id, status: :published})

      search_call(t.id, k.id, [x.id, y.id, z.id], ~T[12:00:00])
      event(t.id, k.id, x.id, "get", ~T[12:10:00])

      m = RetrievalMetrics.compute(t.id, @day, 1800)

      assert m.searched == 3
      assert m.results_surfaced == 3
      assert m.followed_through == 1
      assert m.precision == 1 / 3

      assert m.searches == 1
      assert m.searches_with_follow_through == 1
      assert m.search_follow_through == 1.0
      assert m.results_returned == 3
    end

    test "two searches, one followed through: the per-call rate is 0.5 while precision is 0.25",
         ctx do
      # Deliberately chosen so the two ratios DIFFER — equal values would let a wrong
      # denominator pass unnoticed.
      %{tenant: t, key: k, x: x, y: y} = ctx
      z = fixture(:article, %{tenant_id: t.id, status: :published})
      w = fixture(:article, %{tenant_id: t.id, status: :published})

      search_call(t.id, k.id, [x.id, y.id], ~T[12:00:00])
      event(t.id, k.id, x.id, "get", ~T[12:05:00])
      search_call(t.id, k.id, [z.id, w.id], ~T[13:00:00])

      m = RetrievalMetrics.compute(t.id, @day, 1800)

      assert m.searched == 4
      assert m.followed_through == 1
      assert m.precision == 0.25

      assert m.searches == 2
      assert m.searches_with_follow_through == 1
      assert m.search_follow_through == 0.5
    end

    test "a search is counted ONCE however many of its results were opened", ctx do
      %{tenant: t, key: k, x: x, y: y} = ctx

      search_call(t.id, k.id, [x.id, y.id], ~T[12:00:00])
      event(t.id, k.id, x.id, "get", ~T[12:05:00])
      event(t.id, k.id, y.id, "get", ~T[12:06:00])

      m = RetrievalMetrics.compute(t.id, @day, 1800)

      assert m.precision == 1.0
      assert m.searches == 1
      assert m.searches_with_follow_through == 1
      assert m.search_follow_through == 1.0
    end

    test "results_returned carries the TRUE count when the 20-row recording cap truncates",
         ctx do
      # The cap in `Knowledge.maybe_record_search_access/5` means `searched` is an
      # UNDERCOUNT of what the search returned. `results_returned` makes the gap
      # visible instead of the truncated figure passing as the whole result set.
      %{tenant: t, key: k} = ctx

      ids =
        for _ <- 1..20, do: fixture(:article, %{tenant_id: t.id, status: :published}).id

      search_call(t.id, k.id, ids, ~T[12:00:00], results_returned: 57)

      m = RetrievalMetrics.compute(t.id, @day, 1800)

      assert m.searched == 20
      assert m.results_returned == 57
      assert m.searched < m.results_returned
      assert m.searches == 1
    end

    test "results_returned is summed PER CALL, not per surfaced row", ctx do
      %{tenant: t, key: k, x: x, y: y} = ctx

      search_call(t.id, k.id, [x.id, y.id], ~T[12:00:00], results_returned: 9)
      search_call(t.id, k.id, [x.id], ~T[13:00:00], results_returned: 4)

      m = RetrievalMetrics.compute(t.id, @day, 1800)

      assert m.searches == 2
      # 9 + 4, NOT 9+9+4 (which is what summing the three rows would give).
      assert m.results_returned == 13
    end

    test "pre-#582 rows (no search_id) contribute 0 to the call-level fields and still count in precision",
         ctx do
      %{tenant: t, key: k, x: x, y: y} = ctx

      # Legacy shape: search rows with no `search_id` in metadata.
      event(t.id, k.id, x.id, "search", ~T[12:00:00])
      event(t.id, k.id, y.id, "search", ~T[12:00:00])
      event(t.id, k.id, x.id, "get", ~T[12:05:00])

      m = RetrievalMetrics.compute(t.id, @day, 1800)

      # Unchanged for the persisted series — this is why `precision` was NOT redefined.
      assert m.searched == 2
      assert m.followed_through == 1
      assert m.precision == 0.5

      # No call identity exists for them, so they are excluded rather than collapsed
      # into one phantom NULL-keyed "search".
      assert m.searches == 0
      assert m.searches_with_follow_through == 0
      assert m.search_follow_through == 0.0
      assert m.results_returned == 0
    end

    test "a malformed results_returned value contributes 0 instead of crashing the snapshot",
         ctx do
      %{tenant: t, key: k, x: x} = ctx

      fixture(:article_access_event, %{
        tenant_id: t.id,
        api_key_id: k.id,
        article_id: x.id,
        access_type: "search",
        metadata: %{"search_id" => Ecto.UUID.generate(), "results_returned" => "lots"},
        accessed_at: at(~T[12:00:00])
      })

      m = RetrievalMetrics.compute(t.id, @day, 1800)

      assert m.searches == 1
      assert m.results_returned == 0
    end

    test "call-level fields are tenant-scoped", ctx do
      %{tenant: t, key: k, x: x} = ctx
      other = fixture(:tenant)
      {_raw, other_key} = fixture(:api_key, %{tenant_id: other.id, role: :agent})
      other_article = fixture(:article, %{tenant_id: other.id, status: :published})

      search_call(t.id, k.id, [x.id], ~T[12:00:00])
      search_call(other.id, other_key.id, [other_article.id], ~T[12:00:00], results_returned: 99)

      assert RetrievalMetrics.compute(t.id, @day, 1800).searches == 1
      assert RetrievalMetrics.compute(t.id, @day, 1800).results_returned == 1
      assert RetrievalMetrics.compute(other.id, @day, 1800).results_returned == 99
    end
  end

  describe "compute/3 - provenance breakdown (US-31.2, AC-31.2.5)" do
    test "curated and retrieved hybrid-search events are broken out from each other and from non-hybrid events",
         ctx do
      %{tenant: t, key: k, x: x, y: y} = ctx
      z = fixture(:article, %{tenant_id: t.id, status: :published})

      # A hybrid :curated search, opened within the window -> curated follow-through.
      fixture(:article_access_event, %{
        tenant_id: t.id,
        api_key_id: k.id,
        article_id: x.id,
        access_type: "search",
        metadata: %{"mode" => "hybrid_curated"},
        accessed_at: at(~T[12:00:00])
      })

      event(t.id, k.id, x.id, "get", ~T[12:05:00])

      # A hybrid :retrieved search, never opened -> retrieved miss.
      fixture(:article_access_event, %{
        tenant_id: t.id,
        api_key_id: k.id,
        article_id: y.id,
        access_type: "search",
        metadata: %{"mode" => "hybrid_retrieved"},
        accessed_at: at(~T[12:00:00])
      })

      # A plain (non-hybrid) combined search -> counts toward the aggregate only.
      fixture(:article_access_event, %{
        tenant_id: t.id,
        api_key_id: k.id,
        article_id: z.id,
        access_type: "search",
        metadata: %{"mode" => "combined"},
        accessed_at: at(~T[12:00:00])
      })

      m = RetrievalMetrics.compute(t.id, @day, 1800)

      assert m.searched == 3
      assert m.followed_through == 1

      assert m.curated_searched == 1
      assert m.curated_followed_through == 1
      assert m.curated_precision == 1.0

      assert m.retrieved_searched == 1
      assert m.retrieved_followed_through == 0
      assert m.retrieved_precision == 0.0
    end
  end

  describe "snapshot/3 + list_snapshots/2" do
    test "records a snapshot and is idempotent per tenant/day/window", ctx do
      %{tenant: t, key: k, x: x} = ctx
      event(t.id, k.id, x.id, "search", ~T[12:00:00])
      event(t.id, k.id, x.id, "get", ~T[12:05:00])

      assert {:ok, snap} = RetrievalMetrics.snapshot(t.id, @day, 1800)
      assert snap.precision == 1.0

      # Re-run upserts the same row (no duplicate).
      assert {:ok, _} = RetrievalMetrics.snapshot(t.id, @day, 1800)
      assert 1 == AdminRepo.aggregate(RetrievalMetricSnapshot, :count, :id)

      %{data: [row], meta: %{total_count: 1}} = RetrievalMetrics.list_snapshots(t.id)
      assert row.day == @day
      assert row.precision == 1.0
    end

    test "is tenant-scoped", ctx do
      %{tenant: t, key: k, x: x} = ctx
      other = fixture(:tenant)
      event(t.id, k.id, x.id, "search", ~T[12:00:00])
      {:ok, _} = RetrievalMetrics.snapshot(t.id, @day, 1800)

      assert %{meta: %{total_count: 0}} = RetrievalMetrics.list_snapshots(other.id)
    end

    test "persists and lists the curated/retrieved provenance breakdown (US-31.2, AC-31.2.5)",
         ctx do
      %{tenant: t, key: k, x: x, y: y} = ctx

      fixture(:article_access_event, %{
        tenant_id: t.id,
        api_key_id: k.id,
        article_id: x.id,
        access_type: "search",
        metadata: %{"mode" => "hybrid_curated"},
        accessed_at: at(~T[12:00:00])
      })

      event(t.id, k.id, x.id, "get", ~T[12:05:00])

      fixture(:article_access_event, %{
        tenant_id: t.id,
        api_key_id: k.id,
        article_id: y.id,
        access_type: "search",
        metadata: %{"mode" => "hybrid_retrieved"},
        accessed_at: at(~T[12:00:00])
      })

      assert {:ok, snap} = RetrievalMetrics.snapshot(t.id, @day, 1800)
      assert snap.curated_searched == 1
      assert snap.curated_followed_through == 1
      assert snap.curated_precision == 1.0
      assert snap.retrieved_searched == 1
      assert snap.retrieved_followed_through == 0
      assert snap.retrieved_precision == 0.0

      %{data: [row]} = RetrievalMetrics.list_snapshots(t.id)
      assert row.curated_searched == 1
      assert row.curated_followed_through == 1
      assert row.curated_precision == 1.0
      assert row.retrieved_searched == 1
      assert row.retrieved_followed_through == 0
      assert row.retrieved_precision == 0.0
    end

    test "persists, upserts and lists the call-level fields (#582)", ctx do
      %{tenant: t, key: k, x: x, y: y} = ctx

      search_call(t.id, k.id, [x.id, y.id], ~T[12:00:00], results_returned: 12)
      event(t.id, k.id, x.id, "get", ~T[12:05:00])

      assert {:ok, snap} = RetrievalMetrics.snapshot(t.id, @day, 1800)
      assert snap.searched == 2
      assert snap.precision == 0.5
      assert snap.searches == 1
      assert snap.searches_with_follow_through == 1
      assert snap.search_follow_through == 1.0
      assert snap.results_returned == 12

      # A second search arriving after the first snapshot must be REPLACED into the
      # existing row, not left behind by an on_conflict list that forgot the new
      # columns (the failure mode that makes an upserted metric silently stale).
      search_call(t.id, k.id, [y.id], ~T[13:00:00], results_returned: 3)

      assert {:ok, snap2} = RetrievalMetrics.snapshot(t.id, @day, 1800)
      assert 1 == AdminRepo.aggregate(RetrievalMetricSnapshot, :count, :id)
      assert snap2.searches == 2
      assert snap2.searches_with_follow_through == 1
      assert snap2.search_follow_through == 0.5
      assert snap2.results_returned == 15

      %{data: [row]} = RetrievalMetrics.list_snapshots(t.id)
      assert row.searched == 3
      # The self-describing twin of `searched` — same number, states its unit (#582).
      assert row.results_surfaced == 3
      assert row.searches == 2
      assert row.searches_with_follow_through == 1
      assert row.search_follow_through == 0.5
      assert row.results_returned == 15
    end
  end
end
