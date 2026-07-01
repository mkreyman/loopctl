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
               precision: 0.0
             }
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
  end
end
