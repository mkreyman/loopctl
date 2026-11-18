defmodule Loopctl.Repo.Migrations.AddChgLedgerVoidRoundIndex do
  use Ecto.Migration

  @moduledoc """
  Indexes the lookup `Loopctl.Changes.PrReviewOutcomes` runs to decide whether a review round
  was voided (#1044): a `review_round_void` row of the same tenant and repository whose
  `nullif(raw->>'round_id', '')` equals the round's.

  `totals/2` runs that probe for every round of every outcome in range, with no limit, and
  the closest existing index, `(tenant_id, repo, kind, at)`, narrows only to the repo's void
  rows and then reads `raw` row by row. The key expression is the query's own, `nullif`
  included, so the planner can match it.

  Partial on `kind = 'review_round_void'` because that is the only kind the probe reads.
  `CONCURRENTLY` with `create_if_not_exists`, per `20260905120200`: the ledger takes writes
  from every fleet machine, and an interrupted plain concurrent build leaves an INVALID index
  that every later deploy trips over.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up, do: create_if_not_exists(void_round_index())
  def down, do: drop_if_exists(void_round_index())

  defp void_round_index do
    index(:chg_ledger_rows, [:tenant_id, :repo, "(nullif(raw->>'round_id', ''))"],
      where: "kind = 'review_round_void'",
      name: :chg_ledger_rows_void_round_id_idx,
      concurrently: true
    )
  end
end
