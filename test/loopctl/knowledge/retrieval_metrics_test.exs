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
    mode = Keyword.get(opts, :mode, "combined")

    Enum.each(article_ids, fn article_id ->
      fixture(:article_access_event, %{
        tenant_id: tenant_id,
        api_key_id: api_key_id,
        article_id: article_id,
        access_type: "search",
        metadata: %{
          "search_id" => search_id,
          "results_returned" => results_returned,
          "mode" => mode
        },
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
               results_recorded: 0,
               followed_through: 0,
               precision: 0.0,
               referenced: 0,
               # nil, not 0.0: a day that surfaced nothing has no usage RATE. `precision`
               # reports 0.0 beside it only because it is a non-null column.
               reference_rate: nil,
               searches: 0,
               searches_with_follow_through: 0,
               search_follow_through: 0.0,
               results_returned: 0,
               attributed_opens: 0,
               cross_key_opens: 0,
               direct_opens: 0,
               searches_reformulated: 0,
               searches_quiet: 0,
               searches_scored: 0,
               searches_scored_with_follow_through: 0
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
      assert m.results_recorded == 3
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
      # `results_recorded` is named for the CAPPED slice, not the full surfaced set —
      # naming it `results_surfaced` here would restate the same false denominator #582
      # exists to remove.
      assert m.results_recorded == 20
      assert m.results_returned == 57
      assert m.searched < m.results_returned
      assert m.searches == 1
    end

    test "the recording cap biases search_follow_through DOWN — an open beyond the cap is invisible",
         ctx do
      # Disclosed in the moduledoc ("Two more biases"). A call returns 25 results; only the
      # first 20 get rows. The agent opens the result at rank 21, which correlates to no
      # recorded row: the call counts in `searches` but can never reach
      # `searches_with_follow_through`. Pinned so the disclosure cannot silently go stale.
      %{tenant: t, key: k} = ctx

      ids =
        for _ <- 1..20, do: fixture(:article, %{tenant_id: t.id, status: :published}).id

      beyond_cap = fixture(:article, %{tenant_id: t.id, status: :published})

      search_call(t.id, k.id, ids, ~T[12:00:00], results_returned: 25)
      event(t.id, k.id, beyond_cap.id, "get", ~T[12:10:00])

      m = RetrievalMetrics.compute(t.id, @day, 1800)

      assert m.searches == 1
      assert m.followed_through == 0
      assert m.searches_with_follow_through == 0
      assert m.search_follow_through == 0.0
    end

    test "one open credits EVERY overlapping search in the window — search_follow_through biased UP",
         ctx do
      # The other disclosed bias, pointing the other way. `with_follow_through/2` correlates
      # on (tenant, api_key, article, window) and NOT on `search_id`, so the refine-and-
      # re-search flow credits the missed search as well as the successful one.
      %{tenant: t, key: k, x: x} = ctx

      search_call(t.id, k.id, [x.id], ~T[12:00:00])
      search_call(t.id, k.id, [x.id], ~T[12:03:00])
      event(t.id, k.id, x.id, "get", ~T[12:05:00])

      m = RetrievalMetrics.compute(t.id, @day, 1800)

      assert m.searches == 2
      assert m.searches_with_follow_through == 2
      assert m.search_follow_through == 1.0
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

    test "a query-less enumeration page is NOT a search call", ctx do
      # `list_filtered/2` (mode "list") and `list_keyset/2` (mode "list_keyset") write
      # `"search"` rows too, and since #582 every batch carries a `search_id`. Counting a
      # browse page as a search inflates `searches` and drags `search_follow_through`
      # toward zero without a single search having missed — the exact undisclosed
      # denominator this field exists to state. They still surface results, so they stay
      # in `searched`/`precision`.
      %{tenant: t, key: k, x: x, y: y} = ctx

      search_call(t.id, k.id, [x.id, y.id], ~T[12:00:00],
        mode: "list_keyset",
        results_returned: 40
      )

      search_call(t.id, k.id, [x.id], ~T[13:00:00], mode: "list", results_returned: 7)

      m = RetrievalMetrics.compute(t.id, @day, 1800)

      assert m.searched == 3
      assert m.searches == 0
      assert m.searches_with_follow_through == 0
      assert m.search_follow_through == 0.0
      assert m.results_returned == 0
    end

    test "a MIXED day reports PARTIAL call-level figures, not 0", ctx do
      # The call-level filter is per ROW, not per day: the first day after deploy always
      # mixes pre-#582 rows (no search_id) with post-deploy ones, and browse pages mix in
      # on any day. Only the real search must reach the call-level series — and the day
      # must NOT read 0 just because most of its rows do not qualify.
      %{tenant: t, key: k, x: x, y: y} = ctx

      # Legacy row: no search_id.
      event(t.id, k.id, y.id, "search", ~T[11:00:00])
      # Browse page.
      search_call(t.id, k.id, [y.id], ~T[11:30:00], mode: "list", results_returned: 90)
      # One real search returning one result, followed through.
      search_call(t.id, k.id, [x.id], ~T[12:00:00], mode: "combined", results_returned: 1)
      event(t.id, k.id, x.id, "get", ~T[12:05:00])

      m = RetrievalMetrics.compute(t.id, @day, 1800)

      assert m.searched == 3
      assert m.searches == 1
      assert m.searches_with_follow_through == 1
      assert m.search_follow_through == 1.0
      assert m.results_returned == 1

      # `results_returned >= searched` was documented as a property of the field and is
      # FALSE on any mixed day: the two aggregate different row populations, so a
      # consumer encoding it as a truncation check would misread this day.
      assert m.results_returned < m.searched
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

  describe "referenced / reference_rate (the third funnel stage)" do
    defp referenced_event(tenant_id, api_key_id, article_id, search_id, time) do
      fixture(:article_access_event, %{
        tenant_id: tenant_id,
        api_key_id: api_key_id,
        article_id: article_id,
        access_type: "referenced",
        metadata: %{"recall_id" => search_id},
        origin_search_id: search_id,
        accessed_at: at(time)
      })
    end

    test "counts referenced articles and divides by the same denominator as precision", ctx do
      %{tenant: t, key: k, x: x, y: y} = ctx
      search_id = search_call(t.id, k.id, [x.id, y.id], ~T[12:00:00])
      referenced_event(t.id, k.id, x.id, search_id, ~T[12:05:00])

      m = RetrievalMetrics.compute(t.id, @day, 1800)

      assert m.searched == 2
      assert m.referenced == 1
      assert m.reference_rate == 0.5
    end

    test "repeats cannot inflate it — the count is DISTINCT (recall, article)", ctx do
      # The endpoint is safe to retry, and `article_access_events` is an immutable log, so a
      # repeat writes another row. Counting rows would let a client move a published metric
      # by posting twice, which is the whole reason this counter dedupes.
      %{tenant: t, key: k, x: x} = ctx
      search_id = search_call(t.id, k.id, [x.id], ~T[12:00:00])
      referenced_event(t.id, k.id, x.id, search_id, ~T[12:05:00])
      referenced_event(t.id, k.id, x.id, search_id, ~T[12:06:00])
      referenced_event(t.id, k.id, x.id, search_id, ~T[12:07:00])

      assert RetrievalMetrics.compute(t.id, @day, 1800).referenced == 1
    end

    test "two different recalls referencing the same article count twice", ctx do
      # The dedupe is on the PAIR, not on the article: the same article being useful to two
      # separate recalls is two data points, and collapsing them would under-report usage.
      %{tenant: t, key: k, x: x} = ctx
      first = search_call(t.id, k.id, [x.id], ~T[12:00:00])
      second = search_call(t.id, k.id, [x.id], ~T[13:00:00])
      referenced_event(t.id, k.id, x.id, first, ~T[12:05:00])
      referenced_event(t.id, k.id, x.id, second, ~T[13:05:00])

      assert RetrievalMetrics.compute(t.id, @day, 1800).referenced == 2
    end

    test "a reference is bucketed by its SURFACING day, not by when it was posted", ctx do
      # Numerator and denominator must describe ONE population. Bucketing on the reference
      # row's own timestamp put a 23:59 recall referenced at 00:01 into a day whose
      # `searched` never counted it — and let a client replaying old recall ids drive
      # `reference_rate` above 1.0 on a quiet day.
      %{tenant: t, key: k, x: x} = ctx
      search_id = search_call(t.id, k.id, [x.id], ~T[23:59:00])

      fixture(:article_access_event, %{
        tenant_id: t.id,
        api_key_id: k.id,
        article_id: x.id,
        access_type: "referenced",
        metadata: %{"recall_id" => search_id},
        origin_search_id: search_id,
        accessed_at: DateTime.add(at(~T[23:59:00]), 120, :second)
      })

      today = RetrievalMetrics.compute(t.id, @day, 1800)
      tomorrow = RetrievalMetrics.compute(t.id, Date.add(@day, 1), 1800)

      assert today.referenced == 1, "the reference belongs to the day its recall surfaced"
      assert today.reference_rate == 1.0
      assert tomorrow.referenced == 0
      assert is_nil(tomorrow.reference_rate)
    end

    test "reference_rate is nil, never 0.0, on a day that surfaced nothing", ctx do
      %{tenant: t} = ctx
      m = RetrievalMetrics.compute(t.id, @day, 1800)

      assert m.referenced == 0

      assert is_nil(m.reference_rate),
             "a day with no surfaced results has no usage RATE; 0.0 would assert " <>
               "'surfaced and never used'"
    end

    test "a reference is not a read: it changes no other figure", ctx do
      # This is the guard that matters. `referenced` is the only client-ASSERTED signal on
      # this surface, so if it leaked into a read set an agent could raise its own article's
      # precision, follow-through and open attribution by claiming to have used it.
      %{tenant: t, key: k, x: x} = ctx
      search_id = search_call(t.id, k.id, [x.id], ~T[12:00:00])
      before = RetrievalMetrics.compute(t.id, @day, 1800)

      referenced_event(t.id, k.id, x.id, search_id, ~T[12:05:00])
      later = RetrievalMetrics.compute(t.id, @day, 1800)

      assert before.followed_through == 0
      assert later.followed_through == 0
      assert later.precision == before.precision
      assert later.searched == before.searched
      assert later.attributed_opens == before.attributed_opens
      assert later.direct_opens == before.direct_opens
      assert later.referenced == 1, "the mutation is inert unless the reference was recorded"
    end

    test "snapshot stores it and list_snapshots derives the rate", ctx do
      %{tenant: t, key: k, x: x, y: y} = ctx
      search_id = search_call(t.id, k.id, [x.id, y.id], ~T[12:00:00])
      referenced_event(t.id, k.id, x.id, search_id, ~T[12:05:00])

      assert {:ok, snap} = RetrievalMetrics.snapshot(t.id, @day, 1800)
      assert snap.referenced == 1

      %{data: [row]} = RetrievalMetrics.list_snapshots(t.id)
      assert row.referenced == 1
      assert row.reference_rate == 0.5
    end
  end

  describe "metric_version" do
    # This is the mechanical half of the bump discipline. It CANNOT see a change of MEANING
    # that keeps the same keys (#711 was exactly that, and is why the rule is written down at
    # `@metric_version` rather than left to this test). It can and does see a field being
    # added, removed or renamed — the shape changes that have historically shipped without any
    # mark on the row, leaving a series where a value's meaning depends on when it was
    # computed.
    test "the published key set is pinned to the current version" do
      keys =
        RetrievalMetrics.compute(fixture(:tenant).id, @day, 1800)
        |> Map.keys()
        |> Enum.sort()

      assert RetrievalMetrics.metric_version() == 2,
             "the version changed — update the pinned key set below and RE-SNAPSHOT the " <>
               "affected days, or the series silently carries two definitions"

      assert keys == [
               :attributed_opens,
               :cross_key_opens,
               :day,
               :direct_opens,
               :followed_through,
               :precision,
               :reference_rate,
               :referenced,
               :results_recorded,
               :results_returned,
               :search_follow_through,
               :searched,
               :searches,
               :searches_quiet,
               :searches_reformulated,
               :searches_scored,
               :searches_scored_with_follow_through,
               :searches_with_follow_through,
               :window_seconds
             ],
             "the shape of the published metric changed. That is a definition change: bump " <>
               "`@metric_version`, update this list, and re-snapshot affected days."
    end

    test "a snapshot is stamped with the version that computed it" do
      tenant = fixture(:tenant)

      assert {:ok, snap} = RetrievalMetrics.snapshot(tenant.id, @day, 1800)
      assert snap.metric_version == RetrievalMetrics.metric_version()

      %{data: [row]} = RetrievalMetrics.list_snapshots(tenant.id)

      assert row.metric_version == RetrievalMetrics.metric_version(),
             "the version must reach the payload; a stamp nobody can read is not a stamp"
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
      # The self-describing twin of `searched` — same number, states its unit: RECORDED
      # surfaced results, capped per call (#582).
      assert row.results_recorded == 3
      assert row.searches == 2
      assert row.searches_with_follow_through == 1
      assert row.search_follow_through == 0.5
      assert row.results_returned == 15
    end
  end

  describe "scored_follow_through — the agent-clean rate" do
    # One SEARCH CALL that is SCOREABLE: it carries a session identity and an entrypoint
    # that is not one of the infrastructure channels, which is what puts it in
    # `searches_scored`. Built through the same batch shape production writes.
    defp scoreable_call(ctx, article_ids, time, opts \\ []) do
      search_id = Keyword.get(opts, :search_id, Ecto.UUID.generate())
      session_id = Keyword.get(opts, :session_id, Ecto.UUID.generate())

      Enum.each(article_ids, fn article_id ->
        fixture(:article_access_event, %{
          tenant_id: ctx.tenant.id,
          api_key_id: ctx.key.id,
          article_id: article_id,
          access_type: "search",
          metadata: %{
            "search_id" => search_id,
            "session_id" => session_id,
            "entrypoint" => "cli",
            "results_returned" => length(article_ids),
            "mode" => "combined"
          },
          accessed_at: at(time)
        })
      end)

      search_id
    end

    test "is the SCORED ratio, and diverges from the blended rate on unscoreable channels",
         ctx do
      %{tenant: t, key: k, x: x, y: y} = ctx

      # One agent search that follows through.
      scoreable_call(ctx, [x.id], ~T[10:00:00])
      event(t.id, k.id, x.id, "get", ~T[10:01:00])

      # Four recall-hook searches that never open anything — exactly the shape that
      # dominated the live window. `hook` is in `@no_reformulation_entrypoints`, NOT in
      # `@infra_entrypoints`: this traffic is real, so it stays in the blended denominator
      # and is dropped only from the scored population.
      for i <- 1..4 do
        fixture(:article_access_event, %{
          tenant_id: t.id,
          api_key_id: k.id,
          article_id: y.id,
          access_type: "search",
          metadata: %{
            "search_id" => Ecto.UUID.generate(),
            "session_id" => Ecto.UUID.generate(),
            "entrypoint" => "hook",
            "results_returned" => 1,
            "mode" => "combined"
          },
          accessed_at: at(Time.add(~T[11:00:00], i * 60))
        })
      end

      assert {:ok, _} = RetrievalMetrics.snapshot(t.id, @day, 1800)
      %{data: [row]} = RetrievalMetrics.list_snapshots(t.id)

      assert row.searches_scored == 1
      assert row.searches_scored_with_follow_through == 1

      assert row.scored_follow_through == 1.0,
             "the scored rate must be computed over `searches_scored` alone — the agent " <>
               "searched once and opened once"

      assert row.search_follow_through < row.scored_follow_through,
             "the blended rate must sit BELOW the scored rate when unscoreable channels " <>
               "are present; if these are equal the `@no_reformulation_entrypoints` " <>
               "filter in `reformulation_scoreable/1` has stopped narrowing the scored " <>
               "population and the published rate is misstating agent behaviour again"
    end

    test "is nil, never 0.0, when nothing was scoreable", ctx do
      %{tenant: t, key: k, y: y} = ctx

      # Traffic exists, but none of it can be scored — no session identity at all.
      search_call(t.id, k.id, [y.id], ~T[12:00:00])

      assert {:ok, _} = RetrievalMetrics.snapshot(t.id, @day, 1800)
      %{data: [row]} = RetrievalMetrics.list_snapshots(t.id)

      assert row.searches_scored == 0

      assert row.scored_follow_through == nil,
             "0.0 asserts 'agents searched and opened nothing'; the truth here is 'this " <>
               "instrument could not see'. Publishing an n/a as a number is the failure " <>
               "#711 rescoped the disposition trio to avoid"
    end

    test "the PUBLISHED payload shape is pinned, like compute/3's", ctx do
      %{tenant: t} = ctx
      assert {:ok, _} = RetrievalMetrics.snapshot(t.id, @day, 1800)
      %{data: [row]} = RetrievalMetrics.list_snapshots(t.id)

      assert RetrievalMetrics.metric_version() == 2,
             "the version changed — update the pinned key set below. A field DERIVED ON " <>
               "READ (like scored_follow_through) is exempt from the bump because it is " <>
               "computed for every row served, historical ones included, so it draws no " <>
               "boundary in the series; a STORED figure never is. See `@metric_version`."

      assert Enum.sort(Map.keys(row)) == [
               :attributed_opens,
               :cross_key_opens,
               :day,
               :direct_opens,
               :followed_through,
               :metric_version,
               :precision,
               :reference_rate,
               :referenced,
               :results_recorded,
               :results_returned,
               :scored_follow_through,
               :search_follow_through,
               :searched,
               :searches,
               :searches_quiet,
               :searches_reformulated,
               :searches_scored,
               :searches_scored_with_follow_through,
               :searches_with_follow_through,
               :window_seconds
             ],
             "the shape of the PUBLISHED payload changed. compute/3's key set is pinned " <>
               "separately; this pins what callers actually receive, which is where a " <>
               "derived field like scored_follow_through lives and where its silent " <>
               "removal would otherwise go unnoticed."
    end

    test "the SUPERADMIN breakdown publishes it too — the second published shape", ctx do
      # `present_snapshot/1` is the OTHER served shape, and the metric_version exemption
      # rests on every served row carrying the derived field. Drop it from this path only
      # and the superadmin dashboard falls back to the blended rate with no version bump.
      %{tenant: t} = ctx
      assert {:ok, _} = RetrievalMetrics.snapshot(t.id, @day, 1800)
      %{rows: rows} = RetrievalMetrics.tenant_breakdown(day: @day)

      assert rows
             |> Enum.find(&(&1.tenant_id == t.id))
             |> Map.fetch!(:snapshot)
             |> Map.has_key?(:scored_follow_through)
    end
  end
end
