defmodule Loopctl.Workers.ChgLedgerPruneWorker do
  @moduledoc """
  US-50.1: nightly retention for `chg_ledger_rows`. Deletes every tenant's ledger rows whose
  `at` is older than `Loopctl.Changes.Ledger.retention_days/0`, in bounded batches
  (`Loopctl.Changes.Ledger.prune/3`). Nothing else deletes from the table.

  A row is a measurement, not custody evidence: nothing in the audit chain or any gate reads
  it, so the window is a disk bound only. One tenant's failure is logged and the run moves to
  the next tenant, so a fault in one tenant never starves the rest.

  The same nightly run retires source-minted chg reviewer agents that hold no live dispatch
  (`Loopctl.Changes.ReviewDispatches.retire_idle_reviewers/2`, US-50.3): one agent exists per
  reviewed revision, and without this they would accumulate looking live.
  """

  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 3_600]

  require Logger

  alias Loopctl.Changes.Ledger
  alias Loopctl.Changes.ReviewDispatches
  alias Loopctl.Tenants

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    run(DateTime.utc_now())
    :ok
  end

  @doc """
  Prunes every tenant against `now`. Returns `%{deleted: n, failed: [tenant_id]}`. `opts` are
  passed to `Ledger.prune/3` (`:batch_size`, `:budget`).
  """
  @spec run(DateTime.t(), keyword()) :: %{deleted: non_neg_integer(), failed: [Ecto.UUID.t()]}
  def run(%DateTime{} = now, opts \\ []) do
    cutoff = DateTime.add(now, -Ledger.retention_days() * 86_400, :second)
    {:ok, tenants} = Tenants.list_tenants()

    result =
      Enum.reduce(tenants, %{deleted: 0, failed: []}, fn tenant, acc ->
        try do
          %{acc | deleted: acc.deleted + Ledger.prune(tenant.id, cutoff, opts)}
        rescue
          error ->
            Logger.error(
              "chg ledger prune failed: tenant_id=#{tenant.id} error=#{Exception.message(error)}"
            )

            %{acc | failed: [tenant.id | acc.failed]}
        end
      end)

    retired = ReviewDispatches.retire_idle_reviewers(now)

    Logger.info(
      "chg ledger prune: deleted=#{result.deleted} failed=#{length(result.failed)} " <>
        "reviewers_retired=#{retired}"
    )

    result
  end
end
