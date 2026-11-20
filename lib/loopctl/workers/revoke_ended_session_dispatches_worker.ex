defmodule Loopctl.Workers.RevokeEndedSessionDispatchesWorker do
  @moduledoc """
  Revokes an implement session's credential once its session is over, instead of letting it
  hold its runner's agent slot until its TTL.

  ## The defect this closes

  `Loopctl.Delivery.Placement` mints each implement session an `:agent` dispatch and key for
  the RUNNER'S agent (`runners.agent_id`). `api_keys_one_role_per_agent_idx` allows one live
  key per `(tenant, agent, role)`, so while that key stands, the runner's next placement is
  refused 422 `agent already has an active key with this role` — and the dispatch driver
  places nothing on that machine.

  The key's TTL is the session's wall clock plus grace, about four hours. A session that
  escalates in its first minute (the runner refusing a repository with no `.loopctl/mode` is
  the measured case, 2026-11-20) therefore took its runner out of the pool for four hours.
  Three such escalations left every non-draining runner blocked while the e2e story sat at
  `queued` with idle machines all around it.

  Only `Progress.force_unclaim_story/3` and a placement's own compensation revoked a session
  key. A story leaves its session through many other doors — the session's own
  `POST /stories/:id/escalate`, a runner `stage` report into a terminal stage, a budget kill,
  a control-only escalation, `deployed`, a human resolution — and none of them did.

  ## Why a sweep and not a hook on each door

  One reconciliation covers every door, including the next one somebody adds. It reads the
  state ("is this session still the live one for its story?") rather than trusting each
  transition to remember a cleanup. The cost is up to one minute of delay, against the four
  hours it replaces.

  ## Which dispatches are swept

  An unrevoked `:agent` dispatch, minted for a story (`story_id` set) and for an agent that
  is a runner's agent, at least `@min_age_seconds` old, whose story is NOT both at a live
  stage AND naming this dispatch as its `implementer_dispatch_id`. Live stages are
  `StageMachine.in_flight_stages/0` plus `:merged`: the session may still escalate from
  `merged`, and a pull-request story waits at `ci` with its claim held.

    * `:agent` only. The verifier's dispatch is `:orchestrator` and is minted for the same
      runner agents and the same story while the story sits at `ci`; it is never this
      sweep's to judge.
    * `@min_age_seconds` covers the window inside a placement between the mint and the claim
      that writes `implementer_dispatch_id`. That window is one synchronous call, seconds
      long; ten minutes is far past it.
    * A story with no stage row is not a delivery-loop story and is never swept: an
      orchestrator may mint per-story agent dispatches by hand.

  Each revoke goes through `Dispatches.revoke/3`, so it cascades, appends its
  `dispatch_revoked` chain entry and busts the api-key cache like every other revoke.
  `implementer_dispatch_id` is left alone: it is custody provenance, and the lineage it
  names still resolves for a revoked row.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Runners.Runner
  alias Loopctl.WorkBreakdown.Story

  @min_age_seconds 600
  @batch 50

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    DateTime.utc_now()
    |> candidates()
    |> Enum.each(&revoke/1)

    :ok
  end

  @doc """
  The dispatches a run at `now` would revoke, as `%{id, tenant_id, story_id}`, at most
  `limit`. Cross-tenant by design, like every sweep; `tenant_id` comes back on each row.
  """
  @spec candidates(DateTime.t(), pos_integer()) :: [map()]
  def candidates(now, limit \\ @batch) do
    cutoff = DateTime.add(now, -@min_age_seconds, :second)
    live = StageMachine.in_flight_stages() ++ [:merged]

    runner_agent =
      from r in Runner,
        where: r.tenant_id == parent_as(:d).tenant_id and r.agent_id == parent_as(:d).agent_id

    from(d in Dispatch,
      as: :d,
      join: st in Story,
      on: st.tenant_id == d.tenant_id and st.id == d.story_id,
      join: s in StoryStage,
      on: s.tenant_id == d.tenant_id and s.story_id == d.story_id,
      where: is_nil(d.revoked_at) and d.role == :agent and not is_nil(d.story_id),
      where: d.created_at < ^cutoff,
      where: exists(runner_agent),
      where:
        s.stage not in ^live or is_nil(st.implementer_dispatch_id) or
          st.implementer_dispatch_id != d.id,
      order_by: [asc: d.created_at],
      limit: ^limit,
      select: %{id: d.id, tenant_id: d.tenant_id, story_id: d.story_id}
    )
    |> AdminRepo.all()
  end

  # One revoke per dispatch, each its own transaction: a failure leaves that row for the next
  # run and never stops the rest. A raise is caught for the same reason — the statements under
  # `revoke/3` are plain AdminRepo calls, and one bad row must not kill every later run.
  defp revoke(%{id: id, tenant_id: tenant_id, story_id: story_id}) do
    case Dispatches.revoke(tenant_id, id, actor_lineage: []) do
      {:ok, count} ->
        Logger.info(
          "revoked ended session dispatch: tenant_id=#{tenant_id} story_id=#{story_id} " <>
            "dispatch_id=#{id} revoked_count=#{count}"
        )

      {:error, reason} ->
        Logger.warning(
          "could not revoke ended session dispatch; the next run retries: " <>
            "tenant_id=#{tenant_id} story_id=#{story_id} dispatch_id=#{id} " <>
            "reason=#{inspect(reason)}"
        )
    end
  rescue
    error ->
      Logger.warning(
        "revoking ended session dispatch raised; the next run retries: " <>
          "tenant_id=#{tenant_id} dispatch_id=#{id} error=#{Exception.message(error)}"
      )
  end
end
