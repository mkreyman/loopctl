defmodule Loopctl.Agents.Dispatcher do
  @moduledoc """
  One dispatch pass of a `:judge` spec (Epic 48, US-48.4).

  `run/2` is what `Loopctl.Delivery.TriageDispatcher.run_with/2` used to be, with every part
  that belonged to the triage KIND read from the spec instead (`triage@1`,
  `Loopctl.Agents.Specs.TriageV1`), so the next `:judge` agent is a new spec rather than a copy
  of the pass. A pass, in order:

  1. **The spec's sweeps** (`spec.sweeps`): control passes that finish a story a previous pass
     left half-taken. Each outcome is tagged with its sweep's tag — `{:stranded, outcome}` for
     `:stranded_triaged_unbound` — so `TriageDispatchWorker.run_result/1` can judge the pass by
     its candidates alone.
  2. **The candidates**: `Loopctl.Agents.Candidates.query/2` over `spec.candidates`.
  3. **For each candidate**: the story, the payload builder's input, the project's single
     intake source, the refs (`spec.refs`), the payload (`spec.payload`), a runner
     (`Loopctl.Runners.Selection.runners/3` for `spec.kind`), then `Runners.dispatch/3`.
  4. **Classification** of the answer: dispatched, no runner, the too-large escalation
     (`spec.screens[:payload_too_large]`), transient (`:deferred`) or `:blocked`.

  ## What a `:judge` pass never does

  It CLAIMS NOTHING. The dispatch echoes the story's current `claim_epoch`, which is what the
  ledger fences against and what the verdict's transitions are checked on when it comes back.
  That is the archetype's semantics, not a spec field, and `run/2` refuses any other archetype
  rather than running a `:build` spec down a path that does not claim.

  ## Behind `:dispatch_driver_enabled`

  The SAME switch as `Loopctl.Delivery.DispatchDriver`, read once per pass
  (`DispatchDriver.enabled?/0`), on purpose: two flags would make "the loop runs unattended" a
  state an operator can be half in. Off, the pass reads nothing and moves nothing — the sweeps
  and the too-large escalation are behind it too. `:enabled?` is an INPUT defaulting to that
  read, so a test reaches the work without touching application env; the cron caller never
  passes it.

  ## What is code here and not a spec field

  - The classification of `Runners.dispatch/3`'s refusals (`@transient`, and `:runner_exhausted`
    read as `:no_runner`): those are the runner protocol's answers, the same for every kind.
  - The kind-named strings a pass writes: the log label (`"TriageDispatcher"`), the stage
    actor (`"worker:triage_dispatcher"`) and the too-large escalation reason
    (`"triage_dispatch:triage_too_large"`), derived from `spec.id` and the payload builder's
    refusal by `label/1`, `actor_label/1` and `too_large_reason/2`, so the log lines and the
    audit rows are byte-identical to the pass before it moved.
  - The runner facts (`spec.runner`): `Selection.runners/3` enforces a fixed set for every
    kind, which `triage@1` names; the pass does not re-derive selection from the list.
  """

  import Ecto.Query

  alias Loopctl.Agents.Candidates
  alias Loopctl.Agents.Spec
  alias Loopctl.Delivery.DispatchDriver
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Delivery.TriagePayload
  alias Loopctl.Delivery.TriageVerdictRecord
  alias Loopctl.GitRef
  alias Loopctl.Intake
  alias Loopctl.Repo
  alias Loopctl.Runners
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.Runner
  alias Loopctl.Runners.Selection
  alias Loopctl.WorkBreakdown.Story

  require Logger

  @type outcome ::
          :dispatched
          | :no_runner
          | :deferred
          | :blocked
          | :escalated
          | :errored
          | {:stranded, :escalated | :blocked | :errored}

  @type budgets :: %{wall_clock_seconds: pos_integer(), max_turns: pos_integer()}

  @type candidate :: %{tenant_id: Ecto.UUID.t(), story_id: Ecto.UUID.t()}

  @type option ::
          {:limit, pos_integer()}
          | {:budgets, budgets()}
          | {:enabled?, boolean()}
          | {:dispatch, (Ecto.UUID.t(), Ecto.UUID.t(), map() -> :ok | {:error, term()})}
          | {:sweep_limit, pos_integer()}

  # REFUSALS THAT CLEAR BY THEMSELVES, and the difference from `:blocked` is what an operator
  # reads. A contended capacity reservation, a runner that just filled its last slot, a tenant
  # at its admission cap: every one of these is the fleet being busy, and the story is a
  # candidate again in a minute. Calling them `:blocked` would put "somebody must change
  # something" in the log for a queue that is working exactly as intended — and the live case
  # is ordinary, because a judged story stays at its candidate stage until its verdict comes
  # back, so a pass that runs while its session is live meets its own reservation.
  #
  # A race is transient too, and classing one as `:blocked` is the same lie in the other
  # direction: `:stale_claim_epoch` is the story's epoch moving between `fetch_story/2` and
  # `record_sent/3`, and `:runner_not_connected` / `:runner_ambiguous` are the runner dropping
  # its socket between the Presence read in `Selection.runners/3` and the push. Every one of
  # them is gone by the next pass and none has an action a person could take.
  #
  # `:dispatch_already_replied` is a genuine race against a reply landing mid-pass: the
  # candidate read excludes a story with an unreleased dispatch of the spec's kind
  # (`:no_live_dispatch_of_self`), so the permanent shape it once had is unreachable, and what
  # is left clears when the ledger row releases.
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

  # THE SWEEP IS NOT BOUND BY THE PASS'S `limit`. A stranded row whose escalation keeps failing
  # is not touched, so it keeps its place at the head of the oldest-first ranking; with the
  # pass's own `limit` (a handful of candidates), that many failing rows held every slot for
  # ever and no later half-taken story was finished. A row is stranded only when the SECOND
  # transaction of the too-large route failed, so the set is small by construction; the cap
  # only bounds a pathological pass.
  @sweep_limit 500

  # The payload builders this pass can run, the key the built object rides under, and the
  # refusal that means "a person must read this ticket" (the `:payload_too_large` screen).
  @payload_builders %{triage_payload: %{key: "triage", too_large: :triage_too_large}}

  # The ref sources this pass can resolve. `:story_branch_for_runner_prefixes` is a `:build`
  # source (`DispatchPayload.fill/3`), derived per story from the target runner.
  @ref_sources [:source_base_branch]

  # The sweeps this pass can run, and the tag each one's outcomes carry.
  @sweep_tags %{stranded_triaged_unbound: :stranded}

  @doc """
  One pass of `spec`, or `{:ok, []}` while `:dispatch_driver_enabled` is off.

  Options:

  - `:limit` (required) — the most candidates the pass attempts.
  - `:budgets` — the session budgets, already decided. Absent, `budgets/1` reads the spec's
    pair and a missing or over-ceiling value is returned as the error, before anything runs.
  - `:enabled?` — the switch; defaults to `DispatchDriver.enabled?/0`.
  - `:dispatch` — the push; defaults to `&Loopctl.Runners.dispatch/3`.
  - `:sweep_limit` — the most rows each sweep finishes per pass (default #{@sweep_limit}).

  Raises `ArgumentError` for a spec this pass cannot run: one that is not a `:judge`, or that
  names a payload builder, a ref source or a sweep this module has no clause for. A spec is
  code, so that is a programming error, never a runtime state.
  """
  @spec run(Spec.t(), [option()]) ::
          {:ok, [outcome()]} | {:error, {:unset, atom()} | {:over_contract_maximum, atom()}}
  def run(%Spec{} = spec, opts) when is_list(opts) do
    :ok = runnable!(spec)
    limit = Keyword.fetch!(opts, :limit)

    if Keyword.get_lazy(opts, :enabled?, &DispatchDriver.enabled?/0) == true do
      with {:ok, budgets} <- fetch_budgets(spec, opts),
           do: {:ok, pass(spec, limit, budgets, opts)}
    else
      {:ok, []}
    end
  end

  @doc """
  The budgets a session of `spec` runs under, from its `{wall_clock_key, max_turns_key}` pair,
  or the first key that is unset or over the contract's ceiling.
  """
  @spec budgets(Spec.t()) ::
          {:ok, budgets()} | {:error, {:unset, atom()} | {:over_contract_maximum, atom()}}
  def budgets(%Spec{budgets: {wall_clock_key, max_turns_key}}) do
    with {:ok, seconds} <-
           DispatchDriver.normalise_budget(
             Application.get_env(:loopctl, wall_clock_key),
             wall_clock_key
           ),
         {:ok, turns} <-
           DispatchDriver.normalise_budget(
             Application.get_env(:loopctl, max_turns_key),
             max_turns_key
           ) do
      {:ok, %{wall_clock_seconds: seconds, max_turns: turns}}
    end
  end

  @doc """
  The candidates of `spec`: `Loopctl.Agents.Candidates.query/2` over its predicates and order.
  """
  @spec candidates(Spec.t(), pos_integer()) :: [candidate()]
  def candidates(%Spec{} = spec, limit) when is_integer(limit) and limit > 0 do
    spec
    |> Candidates.query(limit: limit)
    |> Loopctl.AdminRepo.all()
    |> Enum.map(&Map.take(&1, [:tenant_id, :story_id]))
  end

  @doc """
  The rows `sweep` of `spec` would finish, at most `limit`.

  `:stranded_triaged_unbound` — stories the too-large route left HALF-TAKEN: at `triaged` with
  no dispatch of `spec.kind` live and no triage verdict ever recorded. "No verdict" implies
  "nothing bound": only a verdict's own step, and the migration's backfill from a recorded
  verdict, ever write `triage_dispatch_id`, so the query reads the verdict alone.

  The route is two transitions in two transactions (`Stages` refuses to nest them), so a
  failure of the second leaves the row at `triaged`. Nothing else reaches `triaged` without a
  verdict, and the candidate read sees only `detected`, so without the sweep the row stayed
  there for ever. Each pass finishes such a row over the sweep's route; its first transition
  answers `:stale_stage` and the second applies.

  RANKED PER TENANT, oldest first within each: the first row of EVERY tenant before any
  tenant's second. Rows whose escalation keeps failing keep their place; ranked across all
  tenants at once, one tenant's failures held every slot and no other tenant's row was ever
  finished (`ReclaimExpiredClaimsWorker` ranks its candidates the same way).
  """
  @spec swept(Spec.t(), atom(), pos_integer()) :: [candidate()]
  def swept(%Spec{kind: kind} = spec, :stranded_triaged_unbound, limit)
      when is_integer(limit) and limit > 0 do
    unless Map.has_key?(spec.sweeps, :stranded_triaged_unbound),
      do:
        raise(
          ArgumentError,
          "#{spec.id}@#{spec.version} names no :stranded_triaged_unbound sweep"
        )

    ranked =
      from s in StoryStage,
        left_join: d in DispatchRecord,
        on:
          d.tenant_id == s.tenant_id and d.story_id == s.story_id and d.kind == ^kind and
            is_nil(d.released_at),
        left_join: v in TriageVerdictRecord,
        on: v.tenant_id == s.tenant_id and v.story_id == s.story_id,
        where: s.stage == :triaged,
        where: is_nil(d.id) and is_nil(v.id),
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

  # ── the pass ────────────────────────────────────────────────────────────────────────────────

  defp fetch_budgets(spec, opts) do
    case Keyword.fetch(opts, :budgets) do
      {:ok, budgets} -> {:ok, budgets}
      :error -> budgets(spec)
    end
  end

  defp pass(spec, limit, budgets, opts) do
    dispatch = Keyword.get(opts, :dispatch, &Runners.dispatch/3)
    sweep_limit = Keyword.get(opts, :sweep_limit, @sweep_limit)

    finished =
      for sweep <- spec.sweeps |> Map.keys() |> Enum.sort(),
          row <- swept(spec, sweep, sweep_limit),
          do: finish_swept(spec, sweep, row)

    {outcomes, _cache} =
      spec
      |> candidates(limit)
      |> Enum.map_reduce(%{}, fn candidate, cache ->
        attempt(spec, candidate, budgets, dispatch, cache)
      end)

    finished ++ outcomes
  end

  # ONE STORY MAY NOT KILL THE PASS — the read is oldest-first, so a story that raises sits at
  # the head of every later batch too. The pass cache carries only whether a tenant's
  # `:no_runner` note has been logged (`Loopctl.Runners.Selection.note_no_runner/3`), as
  # `Loopctl.Delivery.DispatchDriver`'s does.
  #
  # `:runner_exhausted` is `Runners.dispatch/3` refusing a machine that ran dry after
  # `Selection.runners/3` chose it: this story found no runner, which is what `:no_runner`
  # says, and the next pass selects again.
  defp attempt(spec, candidate, budgets, dispatch, cache) do
    too_large = payload_builder(spec).too_large

    case send_dispatch(spec, candidate, budgets, dispatch) do
      :ok ->
        {:dispatched, cache}

      {:error, reason} when reason in [:no_runner, :runner_exhausted] ->
        {:no_runner, Selection.note_no_runner(cache, label(spec), candidate)}

      {:error, ^too_large} ->
        {escalate(spec, candidate, spec.screens.payload_too_large), cache}

      {:error, reason} when reason in @transient ->
        {deferred(spec, candidate, reason), cache}

      {:error, reason} ->
        {blocked(spec, candidate, reason), cache}
    end
  rescue
    error -> {errored(spec, candidate, Exception.format(:error, error, __STACKTRACE__)), cache}
  catch
    kind, value ->
      {errored(spec, candidate, Exception.format(kind, value, __STACKTRACE__)), cache}
  end

  # The order is the order the triage pass read in, and it is load-bearing for the outcome a
  # story gets: the refs are judged before the payload is built, so a legacy source is
  # `:blocked` even for a ticket that is also too large, and both before any runner is chosen.
  defp send_dispatch(spec, %{tenant_id: tenant_id, story_id: story_id}, budgets, dispatch) do
    with {:ok, story} <- fetch_story(tenant_id, story_id),
         {:ok, input} <- payload_input(spec, tenant_id, story),
         {:ok, source} <- Intake.source_for_project(tenant_id, story.project_id),
         {:ok, refs} <- resolve_refs(spec, source),
         {:ok, object} <- build_payload(spec, input),
         [%Runner{} = runner | _] <-
           Selection.runners(tenant_id, spec.kind, source.repo_full_name) do
      dispatch.(tenant_id, runner.id, payload(spec, story, source, refs, object, budgets))
    else
      {:error, reason} -> {:error, reason}
      [] -> {:error, :no_runner}
    end
  end

  # `:triage_payload` reads the intake record: the reporter's words ARE the payload, which is
  # why the candidate read requires one (`:intake_record_required`).
  defp payload_input(%Spec{payload: :triage_payload}, tenant_id, story),
    do: Intake.get_record(tenant_id, story.intake_record_id)

  # `TriagePayload.build/1`: the reporter's words, fenced, refused whole when the rendered
  # object will not fit the contract.
  defp build_payload(%Spec{payload: :triage_payload}, record), do: TriagePayload.build(record)

  defp payload_builder(%Spec{payload: payload}), do: Map.fetch!(@payload_builders, payload)

  # EVERY ref field from its source, as the contract's string key. `:source_base_branch` is the
  # intake source's `base_branch`, and it is JUDGED here (#874 round 2 finding 1, the half that
  # covers rows written before `Source.validate_base_branch/1`): a `:judge` dispatch never goes
  # through `DispatchPayload.fill/3`, whose second `validate_refs/2` call is what judges a value
  # the intake source supplied, so without this a legacy row's value reaches git on a dev
  # machine. A refusal is `:blocked` — an operator has to repoint the source — and the reason is
  # a bare atom so the value is not echoed into the log.
  #
  # A `:judge` session READS the repository; it is not expected to commit. `triage@1` gives it
  # the base branch as its branch rather than a new one, so nothing invites it to cut a
  # worktree.
  defp resolve_refs(%Spec{refs: refs}, source) do
    if Enum.any?(refs, fn {_field, from} -> from == :source_base_branch end) and
         not usable_ref?(source.base_branch),
       do: {:error, :invalid_base_branch},
       else: {:ok, Map.new(refs, fn {field, from} -> {to_string(field), ref(from, source)} end)}
  end

  defp ref(:source_base_branch, source), do: source.base_branch

  defp usable_ref?(branch), do: GitRef.valid_name?(branch) and byte_size(branch) <= 255

  # FRESH `dispatch_id` PER ATTEMPT, as `DispatchDriver` generates one. Deriving it from the
  # story and its epoch made a second pass during a live session harmless and bought it with
  # permanent blocks: nothing bumps `claim_epoch` on an unclaimed story, so the id could NEVER
  # differ, and a dispatch that ended badly left `:dispatch_id_conflict` against any other
  # runner, or `:dispatch_already_replied` for ever once a session accepted and then died. What
  # the derivation protected is the candidate read's `:no_live_dispatch_of_self`, and
  # `Capacity.heal/3` is what ends that.
  #
  # `claim_epoch` is the story's CURRENT epoch: a `:judge` claims nothing.
  defp payload(spec, story, source, refs, object, budgets) do
    Map.merge(refs, %{
      "dispatch_id" => Ecto.UUID.generate(),
      "story_id" => story.id,
      "kind" => spec.kind,
      "repo" => source.repo_full_name,
      "claim_epoch" => story.claim_epoch,
      "wall_clock_seconds" => budgets.wall_clock_seconds,
      "max_turns" => budgets.max_turns,
      payload_builder(spec).key => Map.new(object, fn {k, v} -> {to_string(k), v} end)
    })
  end

  # ONE SWEPT ROW MAY NOT KILL THE PASS either: a sweep ranks oldest-first, so a row whose
  # route raises would head every later pass and no candidate would ever be dispatched again.
  # Every outcome is TAGGED with the sweep's tag: `TriageDispatchWorker.run_result/1` judges
  # the pass by its CANDIDATES, and a swept row that keeps failing reappears every pass.
  defp finish_swept(spec, sweep, row) do
    tag = Map.fetch!(@sweep_tags, sweep)

    try do
      {tag, escalate(spec, row, Map.fetch!(spec.sweeps, sweep))}
    rescue
      error -> {tag, errored(spec, row, Exception.format(:error, error, __STACKTRACE__))}
    catch
      kind, value -> {tag, errored(spec, row, Exception.format(kind, value, __STACKTRACE__))}
    end
  end

  # A TICKET NO SESSION CAN BE ASKED TO READ NEEDS A PERSON, NOT ANOTHER PASS. Logged and left,
  # it was an ERROR line a minute for ever about a condition that cannot change by itself, on a
  # story at the head of the oldest-first ranking (the bound is on the RENDERED object, so no
  # candidate predicate can see it).
  #
  # `detected` has no edge to `escalated`, so the route is the spec's: `triage@1` takes
  # `detected -> triaged -> escalated` on `:triage_escalate`, which is what an escalating
  # verdict takes. One transaction per transition, so the last failing leaves the story at
  # `triaged`, which is what the `:stranded_triaged_unbound` sweep finishes.
  #
  # IT BINDS NO DISPATCH, deliberately (epic 44, US-44.1): no verdict decided this story, so
  # `triage_dispatch_id` stays NULL — no session may take it out of `triaged`, and this route,
  # which names no session dispatch, still may.
  #
  # `actor_role: :agent` with an EMPTY lineage, stated: this is a worker holding no credential,
  # and `:agent` keeps the human-only edges out of reach whatever the default becomes.
  defp escalate(spec, %{tenant_id: tenant_id, story_id: story_id} = row, route) do
    case fetch_story(tenant_id, story_id) do
      {:ok, story} -> take_route(spec, tenant_id, story, route)
      {:error, reason} -> blocked(spec, row, reason)
    end
  end

  defp take_route(spec, tenant_id, story, route) do
    opts = [
      claim_epoch: story.claim_epoch,
      actor_label: actor_label(spec),
      actor_role: :agent,
      actor_lineage: []
    ]

    # The reason rides the LAST transition, the one that reaches a person; every other carries
    # an explicit nil.
    last = length(route) - 1
    reason = too_large_reason(spec)

    route
    |> Enum.with_index()
    |> Enum.reduce_while(:escalated, fn {transition, index}, _acc ->
      reason = if index == last, do: reason

      case Stages.advance(tenant_id, story.id, transition, Keyword.put(opts, :reason, reason)) do
        {:ok, _row} ->
          {:cont, :escalated}

        # Already taken — by a verdict that landed between the size refusal and here, or by the
        # first half of an earlier attempt at this route. The next transition still applies.
        {:error, :stale_stage} ->
          {:cont, :escalated}

        {:error, refusal} ->
          {:halt,
           blocked(spec, %{tenant_id: tenant_id, story_id: story.id}, {:escalate_failed, refusal})}
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

  # ── the kind-named strings ──────────────────────────────────────────────────────────────────

  # `"triage"` -> `"TriageDispatcher"`: the prefix every line of the pass carried before it
  # moved, so an operator's log search and alert still match.
  defp label(%Spec{id: id}), do: Macro.camelize(id <> "_dispatcher")

  # `"worker:triage_dispatcher"`: the stage audit's actor.
  defp actor_label(%Spec{id: id}), do: "worker:" <> id <> "_dispatcher"

  # `"triage_dispatch:triage_too_large"`: the escalation reason an operator reads on the row.
  defp too_large_reason(%Spec{id: id} = spec),
    do: "#{id}_dispatch:#{payload_builder(spec).too_large}"

  # ── what this pass can run ──────────────────────────────────────────────────────────────────

  defp runnable!(%Spec{archetype: :judge} = spec) do
    unsupported =
      [
        {:payload, [spec.payload] -- Map.keys(@payload_builders)},
        {:refs, Enum.uniq(Keyword.values(spec.refs)) -- @ref_sources},
        {:sweeps, Map.keys(spec.sweeps) -- Map.keys(@sweep_tags)},
        {:screens, if(Map.has_key?(spec.screens, :payload_too_large), do: [], else: [:missing])}
      ]
      |> Enum.reject(fn {_field, values} -> values == [] end)

    if unsupported == [],
      do: :ok,
      else:
        raise(
          ArgumentError,
          "#{spec.id}@#{spec.version}: Loopctl.Agents.Dispatcher cannot run " <>
            inspect(unsupported) <> " (a :payload_too_large screen route is required)"
        )
  end

  defp runnable!(%Spec{} = spec),
    do:
      raise(
        ArgumentError,
        "#{spec.id}@#{spec.version} is a #{inspect(spec.archetype)} spec; " <>
          "Loopctl.Agents.Dispatcher runs only a :judge pass"
      )

  # ── log lines ───────────────────────────────────────────────────────────────────────────────

  # A state only a person clears — no intake source on the project, a record that is gone, a
  # source whose base branch is not a ref — logged at ERROR for the reason `DispatchDriver`
  # gives: a queue that never drains while every pass reports `:ok` at `info` is
  # indistinguishable from an empty one.
  defp blocked(spec, candidate, reason) do
    Logger.error(
      "#{label(spec)}: BLOCKED until somebody changes something: " <>
        "story_id=#{candidate.story_id} reason=#{inspect(reason)}",
      tenant_id: candidate.tenant_id
    )

    :blocked
  end

  defp deferred(spec, candidate, reason) do
    Logger.info(
      "#{label(spec)}: leaving for the next pass: story_id=#{candidate.story_id} " <>
        "reason=#{inspect(reason)}",
      tenant_id: candidate.tenant_id
    )

    :deferred
  end

  defp errored(spec, candidate, detail) do
    Logger.error(
      "#{label(spec)}: candidate failed, continuing with the rest of the pass: " <>
        "story_id=#{candidate.story_id} detail=#{detail}",
      tenant_id: candidate.tenant_id
    )

    :errored
  end
end
