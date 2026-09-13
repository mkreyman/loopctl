defmodule Loopctl.Workers.PostDeployVerificationWorker do
  @moduledoc """
  #803 §9 — decides `verified` or `escalated` for every story waiting at `deployed`. Runs
  every two minutes via Oban Cron.

  ## Why a sweep and not an endpoint

  By `deployed` THE SESSION HAS ENDED. `Loopctl.Delivery.StageMachine.session_ends_at/0`
  includes the stage and the runner's capacity slot has already gone back, so there is no
  caller left to poll one. The deploy also finishes minutes AFTER the story reaches the
  stage — that is the whole reason the check is control's — so anything that ran once, at
  the moment the runner reported the deploy, would ask before there was an answer.

  A sweep is also how it resumes: it holds no state, so a node that dies mid-run loses
  nothing and the next run re-reads every fact from Postgres and the forge.

  ## Idempotent, and safe to run twice

  Two overlapping runs, or one run twice, cannot double-write. Every decision is applied
  through `Loopctl.Delivery.Stages`' compare-and-set from `deployed`: the first commits and
  the second is refused `:stale_stage` — a story cannot be verified twice, escalated twice,
  or verified by one run while another escalates it. The unresolved count is a fenced write
  on the same row. Nothing here closes an issue or makes any other outward change.

  ## The candidate read, and what bounds a run

  Stories at `deployed`, fleet-wide, on `AdminRepo` (BYPASSRLS, so its explicit predicates
  are the only scoping) — the same shape as `HealRunnerCapacityWorker`. Every candidate
  genuinely has work, so a decided story drops out of the next run's candidates by itself.
  Oldest `updated_at` first, and each sweep touches the row it wrote, so a backlog past
  `@batch` drains round-robin rather than starving its tail.

  **Three things bound a run, and the count alone was not enough.** Each candidate makes up
  to a handful of BOUNDED forge calls (`Loopctl.Delivery.GitHubPullRequestSource`: 2s
  connect, 5s receive, no retries), so a slow forge could take a `@batch` run past the
  two-minute cron interval and have the next run start on top of it — re-reading the same
  candidates and doubling the load on a forge that is already struggling.

  - `@batch` candidates, so one run cannot spend an hourly rate limit in a minute.
    Verification is the one gate whose candidates all ask GitHub the SAME questions at once.
  - `@run_budget_ms` of WALL CLOCK, checked between candidates. The count bounds how many
    stories a healthy run touches; only the clock bounds how long an unhealthy one takes.
  - Oban `unique` over the cron interval, so a run that overruns anyway does not get a
    second copy of itself. Overlapping runs were always SAFE — every write is a
    compare-and-set — but two of them are twice the forge traffic for one run's work.

  **A rate limit stops the run.** The first result carrying a `retry_after` halts the batch:
  the remaining candidates would ask a forge that has already said it is out of quota. That
  reads the result's `retry_after` WHATEVER the decision, which is why
  `PostDeployVerification` keeps the field when an unresolved result converts to `:failed`
  at its bound — the pass that crosses the bound is exactly the pass that just heard "out of
  quota", and reading it only on `:unresolved` disarmed the halt there.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 120, states: [:available, :scheduled, :executing]]

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.PostDeployVerification
  alias Loopctl.Delivery.PostDeployVerification.Result
  alias Loopctl.Delivery.StoryStage

  @batch 10

  # Wall clock for one run, checked BETWEEN candidates so a slow forge cannot carry a run
  # past the cron interval. Under the interval on purpose: the remainder of the batch is not
  # lost, it is the next run's first candidates (oldest `updated_at` first).
  @run_budget_ms 90_000

  @actor_label "worker:post_deploy_verification"

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    results = sweep(candidates())

    tally = Enum.frequencies_by(results, fn {_candidate, result} -> outcome(result) end)

    if map_size(tally) > 0 do
      Logger.info("PostDeployVerificationWorker: #{inspect(tally)}")
    end

    :ok
  end

  @doc false
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch

  @doc false
  @spec run_budget_ms() :: pos_integer()
  def run_budget_ms, do: @run_budget_ms

  # `reduce_while` rather than `map`: a rate-limited forge is a reason to stop asking, not a
  # reason to ask nine more times — and so is a run that has used its wall clock.
  defp sweep(candidates) do
    deadline = System.monotonic_time(:millisecond) + @run_budget_ms

    candidates
    |> Enum.reduce_while([], fn candidate, acc ->
      result = verify(candidate)
      acc = [{candidate, result} | acc]

      cond do
        rate_limited?(result) -> {:halt, acc}
        System.monotonic_time(:millisecond) >= deadline -> {:halt, log_budget_spent(acc)}
        true -> {:cont, acc}
      end
    end)
    |> Enum.reverse()
  end

  defp log_budget_spent(acc) do
    Logger.info(
      "PostDeployVerificationWorker: wall-clock budget spent after #{length(acc)} " <>
        "candidate(s); the rest are the next run's"
    )

    acc
  end

  defp verify(candidate) do
    result =
      PostDeployVerification.enforce(candidate.tenant_id, candidate.story_id,
        claim_epoch: candidate.claim_epoch,
        actor_label: @actor_label,
        # A cron sweep holds no key, so it has no dispatch lineage. `[]` is an ATTESTED
        # absence, which is what `Stages.advance/4` requires on the chained escalation —
        # omitting it is refused, precisely so "resolved, and empty" cannot be confused
        # with "forgot to resolve". `actor_label` is what names the actor.
        actor_lineage: []
      )

    log(candidate, result)
    result
  end

  # WHATEVER the decision. A `:failed` result carrying a `retry_after` is an unresolved run
  # that just crossed its bound, and it heard "out of quota" on the way — matching only
  # `:unresolved` disarmed the halt on precisely that pass.
  defp rate_limited?({:ok, %Result{retry_after: seconds}}) when is_integer(seconds), do: true
  defp rate_limited?(_result), do: false

  defp outcome({:ok, %Result{decision: decision}}), do: decision
  defp outcome({:error, reason}), do: reason

  # An `:unresolved` sweep is the ordinary case for a story whose deploy is still running,
  # so it is not logged per story; a decision and an error are.
  defp log(_candidate, {:ok, %Result{decision: :unresolved}}), do: :ok

  defp log(candidate, {:ok, %Result{decision: decision} = result}) do
    Logger.info(
      "PostDeployVerificationWorker: #{decision}: tenant_id=#{candidate.tenant_id} " <>
        "story_id=#{candidate.story_id} merge_sha=#{inspect(result.merge_sha)} " <>
        "deployed_sha=#{inspect(result.deployed_sha)} reasons=#{inspect(result.reasons)}",
      tenant_id: candidate.tenant_id,
      story_id: candidate.story_id
    )
  end

  # The story moved between the candidate read and the evaluation — a human resolved it, a
  # claim was released. Not an error to act on; the next run reads a fresh candidate set.
  defp log(candidate, {:error, reason}) do
    Logger.info(
      "PostDeployVerificationWorker: skipped: tenant_id=#{candidate.tenant_id} " <>
        "story_id=#{candidate.story_id} reason=#{inspect(reason)}",
      tenant_id: candidate.tenant_id,
      story_id: candidate.story_id
    )
  end

  defp candidates do
    from(s in StoryStage,
      where: s.stage == :deployed,
      order_by: [asc: s.updated_at, asc: s.id],
      limit: @batch,
      select: %{tenant_id: s.tenant_id, story_id: s.story_id, claim_epoch: s.claim_epoch}
    )
    |> AdminRepo.all()
  end
end
