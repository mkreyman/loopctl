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

  `@batch` is small because each candidate makes up to three BOUNDED forge calls
  (`Loopctl.Delivery.GitHubPullRequestSource`: 2s connect, 5s receive, no retries), and the
  ceiling on a run has to stay well inside a cron interval. Verification is also the one
  gate whose candidates all ask GitHub the SAME questions at the same time, so an
  unbounded batch is a way to spend an hourly rate limit in a minute.

  **A rate limit stops the run.** The first result carrying a `retry_after` halts the batch:
  the remaining candidates would ask a forge that has already said it is out of quota,
  burning what is left of the window and turning one limit into `@batch` unresolved counts.
  They are picked up by the next run.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.PostDeployVerification
  alias Loopctl.Delivery.PostDeployVerification.Result
  alias Loopctl.Delivery.StoryStage

  @batch 10

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

  # `reduce_while` rather than `map`: a rate-limited forge is a reason to stop asking, not a
  # reason to ask nine more times.
  defp sweep(candidates) do
    candidates
    |> Enum.reduce_while([], fn candidate, acc ->
      result = verify(candidate)
      acc = [{candidate, result} | acc]

      if rate_limited?(result), do: {:halt, acc}, else: {:cont, acc}
    end)
    |> Enum.reverse()
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

  defp rate_limited?({:ok, %Result{decision: :unresolved, retry_after: seconds}})
       when is_integer(seconds),
       do: true

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
