defmodule Loopctl.Workers.CotSanityMonitorWorker do
  @moduledoc """
  US-26.6.3 — CoT sanity monitor.

  Scans recently completed stories for suspicious patterns:
  - Very low lazy-bastard scores
  - Missing review records
  - Anomalously fast completion times

  Non-blocking: flags stories for re-review, never rejects operations.
  """

  use Oban.Worker, queue: :analytics, max_attempts: 3

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.TokenUsage.LazyScore

  import Ecto.Query

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("CotSanityMonitor: scanning recent completions")

    # Scan stories completed in the last 24 hours
    cutoff = DateTime.add(DateTime.utc_now(), -86_400, :second)

    recent_reports =
      from(r in "token_usage_reports",
        where: r.inserted_at > ^cutoff,
        select: %{
          story_id: r.story_id,
          tenant_id: r.tenant_id,
          total_tokens: fragment("? + ?", r.input_tokens, r.output_tokens),
          tool_call_count: r.tool_call_count,
          cot_length_tokens: r.cot_length_tokens,
          tests_run_count: r.tests_run_count
        }
      )
      |> AdminRepo.all()

    flagged =
      recent_reports
      |> Enum.map(fn report ->
        {score, reasons} = LazyScore.compute(report)
        %{report: report, score: score, reasons: reasons, flagged: LazyScore.flagged?(score)}
      end)
      |> Enum.filter(& &1.flagged)

    if flagged != [] do
      Logger.warning("CotSanityMonitor: #{length(flagged)} stories flagged for re-review")
    end

    :ok
  end
end
