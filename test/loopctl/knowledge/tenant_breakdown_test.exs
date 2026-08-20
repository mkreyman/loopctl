defmodule Loopctl.Knowledge.TenantBreakdownTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.RetrievalMetrics
  alias Loopctl.Knowledge.RetrievalMetricSnapshot

  @day ~D[2026-08-18]

  defp snapshot_for(tenant_id, opts) do
    %RetrievalMetricSnapshot{tenant_id: tenant_id}
    |> RetrievalMetricSnapshot.changeset(
      Enum.into(opts, %{
        day: @day,
        window_seconds: 1800,
        searched: 0,
        followed_through: 0,
        precision: 0.0,
        computed_at: DateTime.utc_now()
      })
    )
    |> AdminRepo.insert!()
  end

  describe "tenant_breakdown/1" do
    test "returns one row per tenant and NO cross-tenant aggregate" do
      busy = fixture(:tenant, %{name: "AAA Busy"})
      quiet = fixture(:tenant, %{name: "BBB Quiet"})

      snapshot_for(busy.id, searched: 1000, followed_through: 40, precision: 0.04)
      snapshot_for(quiet.id, searched: 10, followed_through: 4, precision: 0.4)

      %{rows: rows, meta: meta} = RetrievalMetrics.tenant_breakdown(day: @day)

      busy_row = Enum.find(rows, &(&1.tenant_id == busy.id))
      quiet_row = Enum.find(rows, &(&1.tenant_id == quiet.id))

      assert busy_row.snapshot.searched == 1000
      assert quiet_row.snapshot.searched == 10

      assert busy_row.snapshot.precision == 0.04
      assert quiet_row.snapshot.precision == 0.4

      assert meta.aggregation == :none

      refute Map.has_key?(meta, :total_searched),
             "a cross-tenant total of a per-corpus figure describes no corpus that exists"

      refute Map.has_key?(meta, :precision),
             "averaging 4% over a large corpus with 40% over a tiny one is not a fact " <>
               "about either, and it hides the account the operator is looking for"
    end

    test "a tenant with NO snapshot is included with a nil snapshot, not dropped" do
      seen = fixture(:tenant, %{name: "AAA Seen"})
      silent = fixture(:tenant, %{name: "BBB Silent"})

      snapshot_for(seen.id, searched: 5)

      %{rows: rows} = RetrievalMetrics.tenant_breakdown(day: @day)

      silent_row = Enum.find(rows, &(&1.tenant_id == silent.id))

      assert silent_row,
             "a tenant that recorded nothing is a FINDING — a KB nobody queried " <>
               "or a broken ingest — so dropping the row hides the most " <>
               "interesting one"

      assert silent_row.snapshot == nil
      assert Enum.find(rows, &(&1.tenant_id == seen.id)).snapshot.searched == 5
    end

    test "rows carry their own metric_version and may differ within one response" do
      old_defs = fixture(:tenant, %{name: "AAA Old"})
      new_defs = fixture(:tenant, %{name: "BBB New"})

      snapshot_for(old_defs.id, searched: 1, metric_version: 0)
      snapshot_for(new_defs.id, searched: 1, metric_version: 1)

      %{rows: rows} = RetrievalMetrics.tenant_breakdown(day: @day)

      versions =
        rows
        |> Enum.filter(& &1.snapshot)
        |> Map.new(&{&1.tenant_name, &1.snapshot.metric_version})

      assert versions["AAA Old"] == 0

      assert versions["BBB New"] == 1,
             "a tenant not re-snapshotted since a definition change carries the older " <>
               "version; the payload must expose that rather than implying comparability"
    end

    test "one tenant's snapshot never appears under another tenant" do
      a = fixture(:tenant, %{name: "AAA"})
      b = fixture(:tenant, %{name: "BBB"})

      snapshot_for(a.id, searched: 777)

      %{rows: rows} = RetrievalMetrics.tenant_breakdown(day: @day)

      assert Enum.find(rows, &(&1.tenant_id == b.id)).snapshot == nil
      assert Enum.find(rows, &(&1.tenant_id == a.id)).snapshot.searched == 777
    end
  end
end
