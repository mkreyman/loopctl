defmodule Loopctl.Changes.LedgerTest do
  @moduledoc """
  US-50.1: the ledger's list and retention. The receipt rules are
  `LoopctlWeb.ChgLedgerControllerTest`.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Changes.Ledger
  alias Loopctl.Changes.LedgerRow
  alias Loopctl.Workers.ChgLedgerPruneWorker

  setup :verify_on_exit!

  defp insert_row(source, at, attrs \\ %{}) do
    AdminRepo.insert!(
      struct(
        %LedgerRow{
          tenant_id: source.tenant_id,
          source_id: source.id,
          repo: "mkreyman/infra",
          host: "minis",
          kind: "chg",
          at: at,
          raw: %{},
          row_hash: Ecto.UUID.generate()
        },
        attrs
      )
    )
  end

  defp days_ago(now, days), do: DateTime.add(now, -days * 86_400, :second)

  describe "TC-50.1.5: prune" do
    test "deletes the 181-day row and keeps the 179-day one" do
      %{source: source} = fixture(:chg_source, %{})
      now = DateTime.utc_now()
      old = insert_row(source, days_ago(now, 181))
      kept = insert_row(source, days_ago(now, 179))

      assert %{deleted: 1, failed: []} = ChgLedgerPruneWorker.run(now)

      ids = source.tenant_id |> Ledger.list_rows() |> Enum.map(& &1.id)
      assert kept.id in ids
      refute old.id in ids
    end

    test "works in bounded batches up to the budget" do
      %{source: source} = fixture(:chg_source, %{})
      now = DateTime.utc_now()
      for _ <- 1..5, do: insert_row(source, days_ago(now, 200))

      cutoff = days_ago(now, Ledger.retention_days())
      assert Ledger.prune(source.tenant_id, cutoff, batch_size: 2, budget: 3) == 3
      assert Ledger.prune(source.tenant_id, cutoff, batch_size: 2, budget: 3) == 2
      assert Ledger.list_rows(source.tenant_id) == []
    end
  end

  describe "list_rows/2" do
    test "filters by repo case-insensitively and by kind, newest first" do
      %{source: source} = fixture(:chg_source, %{})
      now = DateTime.utc_now()
      older = insert_row(source, days_ago(now, 2))
      newer = insert_row(source, days_ago(now, 1))
      _gate = insert_row(source, now, %{kind: "gate"})

      assert [^newer, ^older] =
               Ledger.list_rows(source.tenant_id, repo: "MKreyman/Infra", kind: "chg")
    end

    test "tenant isolation: A's prune and list never touch B's rows" do
      %{source: a} = fixture(:chg_source, %{})
      %{source: b} = fixture(:chg_source, %{})
      now = DateTime.utc_now()
      b_old = insert_row(b, days_ago(now, 300))

      assert Ledger.prune(a.tenant_id, days_ago(now, 180)) == 0
      assert Ledger.list_rows(a.tenant_id) == []
      assert [%LedgerRow{id: id}] = Ledger.list_rows(b.tenant_id)
      assert id == b_old.id
    end
  end
end
