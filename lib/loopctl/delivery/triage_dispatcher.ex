defmodule Loopctl.Delivery.TriageDispatcher do
  @moduledoc """
  Sends a TRIAGE dispatch for every story the loop has just detected (issue #803 §4).

  This is the hop that was missing between intake and everything else. `TriageTrigger` turns a
  reported issue into a story at `detected`; `TriageVerdict` applies a verdict when one comes
  back; `DispatchDriver` places stories at `queued`. Nothing asked a runner to do the triage in
  between — `dispatchable_kinds` did not include `triage` (contract 1.10.0 adds it) and nothing
  in `lib/` built the dispatch. So the trio ran only where a person ran it, and a real ticket
  stopped at `detected` for ever.

  ## It claims NOTHING, and that is the difference from `Placement.place/4`

  An implement dispatch claims the story: the session works on it, and the claim is what the
  custody gates compare against. A triage session READS — the reporter's words and the
  repository — and produces a judgement. Claiming for it would mark the story as being worked
  by the machine that is only deciding whether it is work at all, and would put it at
  `claimed`, which is the stage an implement session reports from.

  The dispatch carries the story's CURRENT `claim_epoch` instead, which is what the ledger
  fences against and what the verdict's transitions are checked on when it comes back.

  ## Eligibility, and why triage is stricter about the runner than implement is

  `Runners.accepts?/5` decides, the same reader `Runners.dispatch/3` and the driver use:
  connected, not draining, the repository declared, the KIND declared. The kind half matters
  more here than anywhere else, because `Kinds.implied_by_silence/0` stays `implement` alone —
  a runner built before the `kinds` field existed is never sent triage, and only a machine that
  says `triage` on join receives one. That asymmetry is what makes 1.10.0 safe to deploy ahead
  of the fleet, and this module must never widen it.

  ## Budgets

  Its own, and unset by default like the driver's: a triage session reads a ticket and answers,
  so it is a fraction of an implement run, and inheriting the implement budgets would hand a
  reading session a day of wall clock. `:triage_wall_clock_seconds` and `:triage_max_turns`
  have NO DEFAULT for the reason `DispatchDriver` states: a default here is loopctl's guess
  quietly becoming the operator's cost policy.

  ## What it does NOT do

  Retry or remember. A story it could not dispatch stays at `detected` and is a candidate
  again next pass — the same shape as the triage trigger and the driver, for the same reason:
  the condition either clears on its own (no runner declaring `triage` yet) or needs a person.
  The DISPATCH LEDGER is what stops a second one going out for a story already being triaged:
  a `dispatch_id` is derived from the story and its epoch, so a pass that runs while a triage
  session is live re-sends the same id, which the ledger answers rather than starting a second
  session.
  """

  import Ecto.Query

  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Delivery.TriagePayload
  alias Loopctl.Intake
  alias Loopctl.Repo
  alias Loopctl.Runners
  alias Loopctl.Runners.Runner
  alias Loopctl.WorkBreakdown.Story

  require Logger

  @type outcome :: :dispatched | :no_runner | :deferred | :blocked | :errored

  @kind "triage"

  # REFUSALS THAT CLEAR BY THEMSELVES, and the difference from `:blocked` is what an operator
  # reads. A contended capacity reservation, a runner that just filled its last slot, a tenant
  # at its admission cap: every one of these is the fleet being busy, and the story is a
  # candidate again in a minute. Calling them `:blocked` would put "somebody must change
  # something" in the log for a queue that is working exactly as intended — and the live case
  # is ordinary, because a story stays at `detected` until its verdict comes back, so a pass
  # that runs while its triage session is live meets its own reservation.
  @transient [
    :capacity_busy,
    :busy,
    :admission_limit_reached,
    :runner_at_capacity,
    :rate_limited,
    :dispatch_already_replied
  ]

  @doc """
  Stories at `detected` that came from an intake record, oldest first, fair across tenants.

  The intake record is required rather than optional: the triage payload IS the reporter's
  words, so a story with no record has nothing to triage and would be dispatched with an empty
  object. Those exist — a backfill, a story created through the API — and they are not this
  loop's work.

  Public so the selection is falsifiable rather than buried in the pass.
  """
  @spec candidates(pos_integer()) :: [%{tenant_id: Ecto.UUID.t(), story_id: Ecto.UUID.t()}]
  def candidates(limit) when is_integer(limit) and limit > 0 do
    ranked =
      from s in StoryStage,
        join: st in Story,
        on: st.id == s.story_id and st.tenant_id == s.tenant_id,
        where: s.stage == :detected,
        where: not is_nil(st.intake_record_id),
        select: %{
          tenant_id: s.tenant_id,
          story_id: s.story_id,
          updated_at: s.updated_at,
          rank:
            over(row_number(),
              partition_by: s.tenant_id,
              order_by: [asc: s.updated_at, asc: s.story_id]
            )
        }

    Loopctl.AdminRepo.all(
      from r in subquery(ranked),
        order_by: [asc: r.rank, asc: r.updated_at, asc: r.story_id],
        limit: ^limit,
        select: %{tenant_id: r.tenant_id, story_id: r.story_id}
    )
  end

  @doc "The budgets a triage session runs under, or `{:error, {:unset, key}}`."
  @spec budgets() ::
          {:ok, %{wall_clock_seconds: pos_integer(), max_turns: pos_integer()}}
          | {:error, {:unset, atom()} | {:over_contract_maximum, atom()}}
  def budgets do
    alias Loopctl.Delivery.DispatchDriver

    with {:ok, seconds} <-
           DispatchDriver.normalise_budget(
             Application.get_env(:loopctl, :triage_wall_clock_seconds),
             :triage_wall_clock_seconds
           ),
         {:ok, turns} <-
           DispatchDriver.normalise_budget(
             Application.get_env(:loopctl, :triage_max_turns),
             :triage_max_turns
           ) do
      {:ok, %{wall_clock_seconds: seconds, max_turns: turns}}
    end
  end

  @doc """
  One pass: ask a runner to triage what has been detected.

  Behind the SAME switch as the driver (`:dispatch_driver_enabled`) on purpose. Two flags
  would make "the loop runs unattended" a state an operator can be half in — triage running
  while nothing places the result, or the reverse — and the thing being authorised is the
  same: sessions started on someone's machines with nobody watching.
  """
  @spec run(pos_integer()) :: {:ok, [outcome()]} | {:error, term()}
  def run(limit) when is_integer(limit) and limit > 0 do
    alias Loopctl.Delivery.DispatchDriver

    if DispatchDriver.enabled?() do
      with {:ok, budgets} <- budgets(), do: {:ok, run_with(limit, budgets)}
    else
      {:ok, []}
    end
  end

  @doc "The pass itself, on budgets already decided — the seam a test can reach."
  @spec run_with(pos_integer(), %{wall_clock_seconds: pos_integer(), max_turns: pos_integer()}) ::
          [outcome()]
  def run_with(limit, budgets) when is_integer(limit) and limit > 0 do
    limit |> candidates() |> Enum.map(&attempt(&1, budgets))
  end

  # ONE STORY MAY NOT KILL THE PASS — the read is oldest-first, so a story that raises sits at
  # the head of every later batch too.
  defp attempt(candidate, budgets) do
    case send_triage(candidate, budgets) do
      :ok -> :dispatched
      {:error, :no_runner} -> :no_runner
      {:error, reason} when reason in @transient -> deferred(candidate, reason)
      {:error, reason} -> blocked(candidate, reason)
    end
  rescue
    error -> errored(candidate, Exception.format(:error, error, __STACKTRACE__))
  catch
    kind, value -> errored(candidate, Exception.format(kind, value, __STACKTRACE__))
  end

  defp send_triage(%{tenant_id: tenant_id, story_id: story_id}, budgets) do
    with {:ok, story} <- fetch_story(tenant_id, story_id),
         {:ok, record} <- Intake.get_record(tenant_id, story.intake_record_id),
         {:ok, source} <- Intake.source_for_project(tenant_id, story.project_id),
         {:ok, triage} <- TriagePayload.build(record),
         %Runner{} = runner <-
           available_runner(tenant_id, source.repo_full_name) || {:error, :no_runner} do
      Runners.dispatch(tenant_id, runner.id, dispatch(story, source, triage, budgets))
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :no_runner}
    end
  end

  # The same reader the push itself uses, applied BEFORE the ledger row is written: a refusal
  # discovered after it is a spent `dispatch_id` and a slot returned, once per story per pass.
  defp available_runner(tenant_id, repo) do
    ids =
      for {_name, %{metas: [meta]}} <- Runners.pool(tenant_id),
          runner_id = Map.get(meta, :runner_id),
          is_binary(runner_id),
          Runners.accepts?(tenant_id, runner_id, meta, @kind, repo) == :ok,
          do: runner_id

    if ids == [] do
      nil
    else
      Loopctl.AdminRepo.one(
        from r in Runner,
          where: r.tenant_id == ^tenant_id,
          where: is_nil(r.revoked_at),
          where: r.id in ^ids,
          where: r.in_flight < r.max_sessions,
          order_by: [asc: r.in_flight],
          limit: 1
      )
    end
  end

  # DERIVED FROM THE STORY AND ITS EPOCH, not generated, and that is what makes a second pass
  # while a triage session is live harmless: the ledger already holds this id, so the re-send
  # is answered as the retry it is instead of starting a second session on the same ticket.
  # The epoch is in it because a story whose claim was released and re-detected is a different
  # question, and its triage is a different dispatch.
  defp dispatch_id(story) do
    "triage:#{story.id}:#{story.claim_epoch}"
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, 16)
    |> Ecto.UUID.load!()
  end

  defp dispatch(story, source, triage, budgets) do
    %{
      "dispatch_id" => dispatch_id(story),
      "story_id" => story.id,
      "kind" => @kind,
      "repo" => source.repo_full_name,
      # A triage session READS the repository; it is not expected to commit. It is given the
      # base branch as its branch rather than a new one so nothing invites it to cut a
      # worktree, and `base_branch` is the source's own — `master` on a repository that has
      # not said otherwise, `main` where an operator set it.
      "branch" => source.base_branch,
      "base_branch" => source.base_branch,
      "claim_epoch" => story.claim_epoch,
      "wall_clock_seconds" => budgets.wall_clock_seconds,
      "max_turns" => budgets.max_turns,
      "triage" => Map.new(triage, fn {k, v} -> {to_string(k), v} end)
    }
  end

  defp fetch_story(tenant_id, story_id) do
    {:ok, story} =
      Repo.with_tenant(tenant_id, fn ->
        Repo.one(from s in Story, where: s.id == ^story_id and s.tenant_id == ^tenant_id)
      end)

    if story, do: {:ok, story}, else: {:error, :story_not_found}
  end

  # A state only a person clears — no intake source on the project, a record that is gone, a
  # ticket too large to describe within the contract — logged at ERROR for the reason
  # `DispatchDriver` gives: a queue that never drains while every pass reports `:ok` at `info`
  # is indistinguishable from an empty one.
  defp blocked(candidate, reason) do
    Logger.error(
      "TriageDispatcher: BLOCKED until somebody changes something: " <>
        "story_id=#{candidate.story_id} reason=#{inspect(reason)}",
      tenant_id: candidate.tenant_id
    )

    :blocked
  end

  defp deferred(candidate, reason) do
    Logger.info(
      "TriageDispatcher: leaving for the next pass: story_id=#{candidate.story_id} " <>
        "reason=#{inspect(reason)}",
      tenant_id: candidate.tenant_id
    )

    :deferred
  end

  defp errored(candidate, detail) do
    Logger.error(
      "TriageDispatcher: candidate failed, continuing with the rest of the pass: " <>
        "story_id=#{candidate.story_id} detail=#{detail}",
      tenant_id: candidate.tenant_id
    )

    :errored
  end
end
