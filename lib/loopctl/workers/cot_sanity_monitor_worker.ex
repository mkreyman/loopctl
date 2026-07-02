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

    flagged =
      cutoff
      |> score_recent_completions()
      |> Enum.filter(& &1.flagged)

    if flagged != [] do
      Logger.warning("CotSanityMonitor: #{length(flagged)} stories flagged for re-review")
    end

    :ok
  end

  @doc """
  Loads token-usage reports since `cutoff`, joins the owning story, and scores
  each with `LazyScore.compute/1`.

  Returns a list of `%{report:, score:, reasons:, flagged:}` maps. Exposed for
  testing so the score (which reflects the token-ratio factor + small-story
  exemption) can be asserted directly, rather than only observed via logs.
  """
  @spec score_recent_completions(DateTime.t()) :: [
          %{report: map(), score: float(), reasons: [String.t()], flagged: boolean()}
        ]
  def score_recent_completions(cutoff) do
    from(r in "token_usage_reports",
      join: s in "stories",
      on: r.story_id == s.id,
      where: r.inserted_at > ^cutoff,
      select: %{
        story_id: r.story_id,
        tenant_id: r.tenant_id,
        total_tokens: fragment("? + ?", r.input_tokens, r.output_tokens),
        tool_call_count: r.tool_call_count,
        cot_length_tokens: r.cot_length_tokens,
        tests_run_count: r.tests_run_count,
        # `stories` is queried schemaless (a string source), so Postgrex
        # would otherwise decode the NUMERIC `estimated_hours` column as a
        # %Decimal{} — which LazyScore's `is_number/1` guards silently
        # reject, disabling the token-ratio factor + small-story exemption.
        # Cast to float8 at the DB so a plain float reaches LazyScore.
        estimated_hours: fragment("?::float8", s.estimated_hours)
      }
    )
    |> AdminRepo.all()
    |> Enum.map(fn report ->
      {score, reasons} = LazyScore.compute(report)
      %{report: report, score: score, reasons: reasons, flagged: LazyScore.flagged?(score)}
    end)
  end
end
