defmodule Loopctl.Workers.ChgFindingSweepWorker do
  @moduledoc """
  US-51.1 — the chg feedback loop's nightly sweep (`Loopctl.Changes.Findings.sweep/2`): derives
  findings from every tenant's chg ledger, records them, and decides which to file, within the
  daily cap. Runs once a day via Oban Cron.

  It makes no outbound call; every GitHub act it decides is an outbox row
  `Loopctl.Workers.ChgFindingActionWorker` performs. A rerun is safe: a sighting already
  counted is not counted again, and filing a finding is a compare-and-set.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 3_600, states: [:available, :scheduled, :executing, :retryable]]

  alias Loopctl.Changes.Findings

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Findings.sweep()
    :ok
  end
end
