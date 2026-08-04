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
               followed_through: 0,
               precision: 0.0,
               curated_searched: 0,
               curated_followed_through: 0,
               curated_precision: 0.0,
               retrieved_searched: 0,
               retrieved_followed_through: 0,
               retrieved_precision: 0.0
             }
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
  end
end
