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

  What stops a SECOND dispatch going out for a story already being triaged is `candidates/1`,
  which excludes any story holding an unreleased triage dispatch. The `dispatch_id` itself is
  generated fresh per attempt, like the driver's; see the comment above `dispatch/4` for why
  deriving it from the story blocked re-triage permanently.

  A story it can never dispatch does NOT sit here silently. `:triage_too_large` — a ticket
  whose rendered object will not fit the contract's bound — is ESCALATED, because it is the
  one refusal in this pass that needs a person rather than time, and `TriagePayload` says so
  in its own moduledoc. The two `:blocked` shapes that remain are a project with no single
  intake source and a record that has gone: neither is a candidate at all (the first is
  excluded by the query, the second logs and is rare), so neither can head-of-line the queue.
  """

  import Ecto.Query

  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Delivery.TriagePayload
  alias Loopctl.GitRef
  alias Loopctl.Intake
  alias Loopctl.Intake.Source
  alias Loopctl.Repo
  alias Loopctl.Runners
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.Runner
  alias Loopctl.Runners.Usage
  alias Loopctl.WorkBreakdown.Story

  require Logger

  @type outcome :: :dispatched | :no_runner | :deferred | :blocked | :escalated | :errored

  @kind "triage"

  # REFUSALS THAT CLEAR BY THEMSELVES, and the difference from `:blocked` is what an operator
  # reads. A contended capacity reservation, a runner that just filled its last slot, a tenant
  # at its admission cap: every one of these is the fleet being busy, and the story is a
  # candidate again in a minute. Calling them `:blocked` would put "somebody must change
  # something" in the log for a queue that is working exactly as intended — and the live case
  # is ordinary, because a story stays at `detected` until its verdict comes back, so a pass
  # that runs while its triage session is live meets its own reservation.
  #
  # A race is transient too, and classing one as `:blocked` is the same lie in the other
  # direction: `:stale_claim_epoch` is the story's epoch moving between `fetch_story/2` and
  # `record_sent/3`, and `:runner_not_connected` / `:runner_ambiguous` are the runner dropping
  # its socket between the Presence read in `available_runner/2` and the push. Every one of
  # them is gone by the next pass and none has an action a person could take. Telling an
  # operator to intervene on the conditions that fix themselves is how the log stops being
  # read at all.
  #
  # `:dispatch_already_replied` is NOT here any more, and that is the correction that matters:
  # it used to be classed transient while being the most permanent state this pass could reach
  # — an accepted session that died left it for ever, logged at `info` as the fleet being busy.
  # It is now unreachable in that shape (`candidates/1` excludes a story with an unreleased
  # dispatch), so what is left is a genuine race against a reply landing mid-pass, and a race
  # is `:blocked` only if it cannot clear. This one clears when the ledger row releases.
  @transient [
    :capacity_busy,
    :busy,
    :admission_limit_reached,
    :runner_at_capacity,
    :rate_limited,
    :stale_claim_epoch,
    :runner_not_connected,
    :runner_ambiguous,
    :dispatch_already_replied
  ]

  @doc """
  Stories at `detected` that came from an intake record, are under a project bound to exactly
  one intake source, and have no triage session already running — oldest first, fair across
  tenants.

  The intake record is required rather than optional: the triage payload IS the reporter's
  words, so a story with no record has nothing to triage and would be dispatched with an empty
  object. Those exist — a backfill, a story created through the API — and they are not this
  loop's work.

  ## The two predicates that are here rather than discovered per story

  BOTH close the same trap, which `DispatchDriver`'s own moduledoc records as a defect it
  already paid for: nothing removes a dispatched triage story from this set — no claim is
  taken and no stage row is written until the verdict lands — so a story this pass cannot
  dispatch keeps its `updated_at` frozen at detection time and sits at the HEAD of an
  oldest-first ranking for ever. Twenty of them fill every batch while the worker reports a
  clean run.

  - **One active intake source.** A project with none has no repository and a project with two
    names no single one, so every story under it is `:blocked` permanently. The same predicate,
    for the same reason, as the driver's.
  - **No unreleased triage dispatch.** This is what replaced a `dispatch_id` DERIVED from the
    story and its epoch. That derivation made a second pass during a live session harmless, and
    bought it with two permanent blocks: nothing bumps `claim_epoch` on an unclaimed `detected`
    story, so the id could never differ — a runner that took the dispatch and then went away
    left `:dispatch_id_conflict` against the next runner for ever, and one that ACCEPTED and
    then died without a verdict left `:dispatch_already_replied` for ever, logged at `info` as
    though the fleet were merely busy. The ledger row is the better answer to the same
    question, because it is the thing that ENDS: `Loopctl.Runners.Capacity.heal/3` releases a
    reservation whose session outran its wall clock, so a dead triage session stops excluding
    its story and the next pass sends a fresh dispatch.

  Public so the selection is falsifiable rather than buried in the pass.
  """
  @spec candidates(pos_integer()) :: [%{tenant_id: Ecto.UUID.t(), story_id: Ecto.UUID.t()}]
  def candidates(limit) when is_integer(limit) and limit > 0 do
    bound_projects =
      from src in Source,
        where: is_nil(src.revoked_at),
        group_by: [src.tenant_id, src.project_id],
        having: count(src.id) == 1,
        select: %{tenant_id: src.tenant_id, project_id: src.project_id}

    live_triage =
      from d in DispatchRecord,
        where: d.kind == ^@kind and is_nil(d.released_at),
        select: %{tenant_id: d.tenant_id, story_id: d.story_id}

    ranked =
      from s in StoryStage,
        join: st in Story,
        on: st.id == s.story_id and st.tenant_id == s.tenant_id,
        join: b in subquery(bound_projects),
        on: b.tenant_id == st.tenant_id and b.project_id == st.project_id,
        left_join: live in subquery(live_triage),
        on: live.tenant_id == s.tenant_id and live.story_id == s.story_id,
        where: s.stage == :detected,
        where: not is_nil(st.intake_record_id),
        where: is_nil(live.story_id),
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
    {outcomes, _cache} =
      limit
      |> candidates()
      |> Enum.map_reduce(%{}, fn candidate, cache -> attempt(candidate, budgets, cache) end)

    outcomes
  end

  # ONE STORY MAY NOT KILL THE PASS — the read is oldest-first, so a story that raises sits at
  # the head of every later batch too. The pass cache carries the tenant's exhausted runners
  # (read once per tenant per pass, and only once a connected runner passes every other fact)
  # and whether its `:no_runner` note has been logged, both `Loopctl.Runners.Usage`'s, as
  # `Loopctl.Delivery.DispatchDriver`'s does.
  defp attempt(candidate, budgets, cache) do
    {result, cache} = send_triage(candidate, budgets, cache)

    outcome =
      case result do
        :ok -> :dispatched
        {:raised, detail} -> errored(candidate, detail)
        {:error, :no_runner} -> :no_runner
        {:error, :triage_too_large} -> escalate_too_large(candidate)
        {:error, reason} when reason in @transient -> deferred(candidate, reason)
        {:error, reason} -> blocked(candidate, reason)
      end

    {outcome, cache}
  rescue
    error -> {errored(candidate, Exception.format(:error, error, __STACKTRACE__)), cache}
  catch
    kind, value -> {errored(candidate, Exception.format(kind, value, __STACKTRACE__)), cache}
  end

  defp send_triage(%{tenant_id: tenant_id, story_id: story_id} = candidate, budgets, cache) do
    with {:ok, story} <- fetch_story(tenant_id, story_id),
         {:ok, record} <- Intake.get_record(tenant_id, story.intake_record_id),
         {:ok, source} <- Intake.source_for_project(tenant_id, story.project_id),
         :ok <- usable_base_branch(source),
         {:ok, triage} <- TriagePayload.build(record),
         [_ | _] = eligible <- eligible_runners(tenant_id, source.repo_full_name) do
      payload = dispatch(story, source, triage, budgets)
      # THE PASS'S READ, made before `keeping/2` so a raise after it does not throw it away;
      # `send_to_first_usable/5` takes it from the cache.
      {_exhausted, cache} = Usage.exhausted_for_pass(cache, tenant_id)

      keeping(cache, fn cache ->
        send_to_first_usable(candidate, source.repo_full_name, eligible, payload, cache)
      end)
    else
      [] -> {{:error, :no_runner}, cache}
      {:error, reason} -> {{:error, reason}, cache}
    end
  end

  # `Runners.dispatch/3` asks the meta and nothing else — it never checks the SUBSCRIPTION — so
  # the pass's cached map, read seconds ago, was the only check between a runner that ran dry
  # during the pass and a triage session that ends `usage_exhausted`. The ONE runner picked is
  # re-read (`Usage.recheck_for_pass/3`: one read per actual dispatch) and, found dry, joins the
  # cached map, so the next pick — and every later candidate — passes it over. Bounded: each
  # turn removes a runner from a finite pool.
  defp send_to_first_usable(candidate, repo, eligible, payload, cache) do
    %{tenant_id: tenant_id} = candidate
    {exhausted, cache} = Usage.exhausted_for_pass(cache, tenant_id)

    case available_runner(tenant_id, repo, eligible, exhausted) do
      {nil, resets} ->
        {{:error, :no_runner}, Usage.note_no_runner(cache, "TriageDispatcher", candidate, resets)}

      {%Runner{} = runner, _resets} ->
        case Usage.recheck_for_pass(cache, tenant_id, runner.id) do
          {true, cache} -> send_to_first_usable(candidate, repo, eligible, payload, cache)
          {false, cache} -> {Runners.dispatch(tenant_id, runner.id, payload), cache}
        end
    end
  end

  # A RAISE AFTER THE PASS CACHE WAS UPDATED KEEPS THE UPDATE (US-44.6 review round 2): see
  # `Loopctl.Delivery.DispatchDriver`'s twin. `attempt/3`'s rescue can only return the cache it
  # was handed; this returns the one the read produced, beside `{:raised, detail}`.
  defp keeping(cache, fun) do
    fun.(cache)
  rescue
    error -> {{:raised, Exception.format(:error, error, __STACKTRACE__)}, cache}
  catch
    kind, value -> {{:raised, Exception.format(kind, value, __STACKTRACE__)}, cache}
  end

  # THE SECOND HALF OF #874 ROUND 2 FINDING 1, and the half that covers rows written before it.
  # `Source.validate_base_branch/1` now refuses a value that is not a git ref name at the WRITE,
  # but a row enrolled or repointed earlier was checked only for length — and this module is
  # the one dispatch path that never goes through `DispatchPayload.fill/3`, whose second
  # `validate_refs/2` call is what judges a value the intake source supplied. `dispatch/4`
  # below puts `source.base_branch` in as BOTH `branch` and `base_branch`, so without this the
  # legacy row reaches git on a dev machine.
  #
  # It lands on `blocked/2` — "BLOCKED until somebody changes something" — which is exactly
  # what this is: an operator has to repoint the source, and no later pass can change it. The
  # reason is a bare atom so the value is not echoed into the log; the story id names the row
  # to go and look at.
  defp usable_base_branch(%{base_branch: branch}) do
    if GitRef.valid_name?(branch) and byte_size(branch) <= 255,
      do: :ok,
      else: {:error, :invalid_base_branch}
  end

  # The same reader the push itself uses, applied BEFORE the ledger row is written: a refusal
  # discovered after it is a spent `dispatch_id` and a slot returned, once per story per pass.
  # Every fact but exhaustion here — `%{}` is "nothing is exhausted" to `Runners.accepts?/6` —
  # so the pass reads the tenant's exhausted runners only when somebody passes them.
  defp eligible_runners(tenant_id, repo) do
    for {_name, %{metas: [meta]}} <- Runners.pool(tenant_id),
        runner_id = Map.get(meta, :runner_id),
        is_binary(runner_id),
        Runners.accepts?(tenant_id, runner_id, meta, @kind, repo, %{}) == :ok,
        do: {runner_id, meta}
  end

  # The eligible runners judged on `exhausted` too: the least-loaded one whose row has a free
  # slot and is not revoked, with the effective resets of the runners refused
  # `:runner_exhausted` that pass the SAME row predicate — what the `:no_runner` note needs, and
  # a dry runner that is also full or revoked has no reset worth naming.
  defp available_runner(tenant_id, repo, eligible, exhausted) do
    judged =
      for {runner_id, meta} <- eligible,
          do: {runner_id, Runners.accepts?(tenant_id, runner_id, meta, @kind, repo, exhausted)}

    dry = for {id, {:error, :runner_exhausted}} <- judged, do: id
    wanted = for({id, :ok} <- judged, do: id) ++ dry

    {dry_rows, runners} =
      Loopctl.AdminRepo.all(
        from r in Runner,
          where: r.tenant_id == ^tenant_id,
          where: is_nil(r.revoked_at),
          where: r.id in ^wanted,
          where: r.in_flight < r.max_sessions,
          order_by: [asc: r.in_flight]
      )
      |> Enum.split_with(&(&1.id in dry))

    {List.first(runners), Enum.map(dry_rows, &Map.fetch!(exhausted, &1.id))}
  end

  # FRESH PER ATTEMPT, as `DispatchDriver` generates one. It was derived from the story and its
  # epoch, so that a second pass during a live session re-sent the same id and the ledger
  # answered it as the retry it was. That worked and cost too much: nothing bumps `claim_epoch`
  # on an unclaimed `detected` story, so the id could NEVER differ, and a dispatch that ended
  # badly left a permanent block — `:dispatch_id_conflict` against any other runner, or
  # `:dispatch_already_replied` for ever once a session accepted and then died. What the
  # derivation was protecting is now a predicate in `candidates/1`: a story with an unreleased
  # triage dispatch is not a candidate at all, and `Capacity.heal/3` is what ends that.
  defp dispatch(story, source, triage, budgets) do
    %{
      "dispatch_id" => Ecto.UUID.generate(),
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

  # A TICKET NO SESSION CAN BE ASKED TO READ NEEDS A PERSON, NOT ANOTHER PASS. `TriagePayload`
  # says so in its own moduledoc — "its caller escalates it to a human" — and this is the only
  # caller. Logged and left, it was an ERROR line a minute for ever about a condition that
  # cannot change by itself, on a story that then also sat at the head of the oldest-first
  # ranking (`candidates/1` has no size predicate and cannot have one; the bound is on the
  # RENDERED object).
  #
  # `detected` has no edge to `escalated`, so this takes the route the machine already has for
  # exactly this conclusion: `detected -> triaged -> escalated` on `:triage_escalate`, which is
  # what an escalating verdict takes. Two transactions, and the second failing leaves the story
  # at `triaged` — where nothing re-dispatches it, which is correct: this pass never sends a
  # triaged story, and an operator reading `triaged` with no verdict is looking at a story that
  # needs them either way.
  #
  # `actor_role: :agent` with an EMPTY lineage, stated: this is a worker holding no credential,
  # and `:agent` keeps the human-only edges out of reach whatever the default becomes.
  defp escalate_too_large(%{tenant_id: tenant_id, story_id: story_id}) do
    case fetch_story(tenant_id, story_id) do
      {:ok, story} -> escalate_route(tenant_id, story)
      {:error, reason} -> blocked(%{tenant_id: tenant_id, story_id: story_id}, reason)
    end
  end

  defp escalate_route(tenant_id, story) do
    opts = [
      claim_epoch: story.claim_epoch,
      actor_label: "worker:triage_dispatcher",
      actor_role: :agent,
      actor_lineage: []
    ]

    route = [
      {{:detected, :triaged, :forward}, nil},
      {{:triaged, :escalated, :triage_escalate}, "triage_dispatch:triage_too_large"}
    ]

    Enum.reduce_while(route, :escalated, fn {transition, reason}, _acc ->
      case Stages.advance(tenant_id, story.id, transition, Keyword.put(opts, :reason, reason)) do
        {:ok, _row} ->
          {:cont, :escalated}

        # Already taken — by a verdict that landed between the size refusal and here, or by the
        # first half of an earlier attempt at this route. The next transition still applies.
        {:error, :stale_stage} ->
          {:cont, :escalated}

        {:error, reason} ->
          {:halt,
           blocked(%{tenant_id: tenant_id, story_id: story.id}, {:escalate_failed, reason})}
      end
    end)
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
