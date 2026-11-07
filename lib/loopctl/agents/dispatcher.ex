defmodule Loopctl.Agents.Dispatcher do
  @moduledoc """
  One dispatch pass of a `:judge` spec (Epic 48, US-48.4), a `:build` spec (US-48.7) or a
  `:draft` spec (US-48.9).

  `run/2` is what `Loopctl.Delivery.TriageDispatcher.run_with/2` and
  `Loopctl.Delivery.DispatchDriver.run_with/2` used to be, with every part that belonged to the
  KIND read from the spec instead (`triage@1`, `Loopctl.Agents.Specs.TriageV1`; `implement@1`,
  `Loopctl.Agents.Specs.ImplementV1`), so the next agent of either archetype is a new spec
  rather than a copy of the pass. The archetype decides which pass runs; see "The `:build`
  pass" below for the second.

  ## The `:judge` pass

  In order:

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
  That is the archetype's semantics, not a spec field: a `:judge` spec never reaches the claim,
  and a `:build` spec never reaches the claimless push.

  ## The `:build` pass

  It PLACES: for each candidate it CALLS `Loopctl.Delivery.Placement.place/4`, which contracts
  a pending story, mints the session dispatch, claims the story (binding
  `implementer_dispatch_id` and `assigned_agent_id`), builds the story object and pushes. None
  of that is rewritten here, and none of it is a spec field: claiming and the mint are
  archetype semantics, and `place/4` refuses a kind whose spec is not a `:build`
  (`:not_placeable_kind`). What the pass reads from the spec, per candidate:

  1. **The candidates**: `Candidates.query/2` over `spec.candidates`, as for a `:judge`.
  2. **The runners**: `runners/3` — the tenant's admission pre-check
     (`Loopctl.Runners.Capacity.admit/2`) when `spec.runner` names
     `:tenant_admission_headroom`, then `Selection.runners/3` for `spec.kind`.
  3. **The operator key**: the tenant's oldest live unlineaged `:user` key, cached per tenant
     for the pass (`operator_key/2`). It is resolved from the database, never an input.
  4. **The dispatch** (`spec.payload` `:story_payload`, `spec.refs`): the fields the caller of
     `place/4` owns. `branch` (`:story_branch_for_runner_prefixes`) is omitted, because only
     `place/4` holds the target runner's declaration it is derived from; `base_branch`
     (`:source_base_branch`) is the intake source's, judged by `DispatchPayload.fill/3` inside
     `place/4` before anything is minted. No story object: `place/4` builds it and refuses one
     a caller supplies.
  5. **The runner advance** (`spec.advance_on`): the machine refusals on which the next
     selected runner is tried. See `Loopctl.Agents.Spec` for what each one does to the answer.

  Its outcomes are `Loopctl.Delivery.DispatchDriver.outcome/0`'s — `:placed`, `:no_runner`,
  `:unplaceable`, `:blocked`, `:errored` — and its log label and actor are the driver's
  (`"DispatchDriver"`, `"worker:dispatch_driver"`), because an operator's alerts and the
  claim's audit rows read them.

  ## The `:draft` pass (US-48.9)

  The `:judge` pass's shape, because a `:draft` is the same kind of session — it reads a
  story, claims nothing, and its dispatch echoes the story's current `claim_epoch` — with the
  two differences its archetype makes:

  - **No sweep and no stage move.** A `:draft` names no transition, so nothing is ever left
    half-taken for a sweep to finish, and nothing here calls `Stages`.
  - **A ticket too large to send is REFUSED, not escalated**: `spec.screens[:payload_too_large]`
    is `[]` (moves nothing), and the pass stores a refused `reply_drafts` row with that screen
    (`Loopctl.ReplyDrafts.refuse/4`), outcome `:refused`, so the story stops being a candidate.

  What the session returns is not this module's: it arrives as `agent_result` and
  `Loopctl.Agents.AgentResult` runs the spec's effect.

  ## The verifier pass (US-48.18)

  A `:judge` whose payload is `:verify_payload` (`verify@1`) is PLACED rather than pushed:
  each candidate goes through `Loopctl.Agents.VerifierPlacement.place/4`, which mints a
  verifier dispatch rooted apart from the implementer's under the tenant's operator key,
  binds it to the story and pushes a `verify` dispatch whose id is that dispatch's. The pass
  hands it the operator key (`operator_key/2`, as for a `:build`), the spec's runner selection
  and the push. Its outcomes are the `:judge` pass's; `:escalated` is a story whose only
  runners are its implementer's agent's.

  ## Behind `:dispatch_driver_enabled`

  The SAME switch as `Loopctl.Delivery.DispatchDriver`, read once per pass
  (`DispatchDriver.enabled?/0`), on purpose: two flags would make "the loop runs unattended" a
  state an operator can be half in. Off, the pass reads nothing and moves nothing — the sweeps
  and the too-large escalation are behind it too. `:enabled?` is an INPUT defaulting to that
  read, so a test reaches the work without touching application env; the cron caller never
  passes it.

  A `:draft` pass is behind that switch AND its own, `:draft_dispatch_enabled`
  (`DRAFT_DISPATCH_ENABLED`, default OFF, `drafts_enabled?/0`): a drafter is new work on an
  operator's machines that no ticket needed before, so turning the loop on must not turn it on
  too. Off, a `:draft` pass reads nothing.

  ## What is code here and not a spec field

  - The classification of `Runners.dispatch/3`'s refusals (`@transient`, and `:runner_exhausted`
    read as `:no_runner`): those are the runner protocol's answers, the same for every kind.
  - The kind-named strings a pass writes: the log label (`"TriageDispatcher"`), the stage
    actor (`"worker:triage_dispatcher"`) and the too-large escalation reason
    (`"triage_dispatch:triage_too_large"`), derived from `spec.id` and the payload builder's
    refusal by `label/1`, `actor_label/1` and `too_large_reason/2`, so the log lines and the
    audit rows are byte-identical to the pass before it moved. A `:build` pass's label and
    actor are the ARCHETYPE's (`"DispatchDriver"`, `"worker:dispatch_driver"`), not derived
    from its id: they are what the implement pass wrote before it moved, and a second `:build`
    spec is the same driver placing another kind.
  - The classification of `Placement.place/4`'s refusals for a `:build` pass: the four states
    only a person clears (`:blocked`) are the placement protocol's answers, the same for every
    `:build` kind.
  - The runner facts (`spec.runner`): `Selection.runners/3` enforces a fixed set for every
    kind, which `triage@1` names; the pass does not re-derive selection from the list.
  """

  import Ecto.Query

  alias Loopctl.Agents.Candidates
  alias Loopctl.Agents.Spec
  alias Loopctl.Agents.VerifierPlacement
  alias Loopctl.Delivery.DispatchDriver
  alias Loopctl.Delivery.Placement
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Delivery.TriagePayload
  alias Loopctl.Delivery.TriageVerdictRecord
  alias Loopctl.GitRef
  alias Loopctl.Intake
  alias Loopctl.ReplyDrafts
  alias Loopctl.Repo
  alias Loopctl.Runners
  alias Loopctl.Runners.Capacity
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.Runner
  alias Loopctl.Runners.Selection
  alias Loopctl.WorkBreakdown.Story

  require Logger

  @typedoc "A `:judge` pass's outcomes."
  @type judge_outcome ::
          :dispatched
          | :no_runner
          | :deferred
          | :blocked
          | :escalated
          | :errored
          | {:stranded, :escalated | :blocked | :errored}

  @typedoc "A `:build` pass's outcomes: `Loopctl.Delivery.DispatchDriver.outcome/0`."
  @type build_outcome :: :placed | :no_runner | :unplaceable | :blocked | :errored

  @typedoc "A `:draft` pass's outcomes: `:refused` is a ticket too large to send."
  @type draft_outcome :: :dispatched | :no_runner | :deferred | :blocked | :refused | :errored

  @type outcome :: judge_outcome() | build_outcome() | draft_outcome()

  @type budgets :: %{wall_clock_seconds: pos_integer(), max_turns: pos_integer()}

  @type candidate :: %{tenant_id: Ecto.UUID.t(), story_id: Ecto.UUID.t()}

  @type option ::
          {:limit, pos_integer()}
          | {:budgets, budgets()}
          | {:enabled?, boolean()}
          | {:dispatch, (Ecto.UUID.t(), Ecto.UUID.t(), map() -> :ok | {:error, term()})}
          | {:place,
             (Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword() -> {:ok, map()} | {:error, term()})}
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
  @payload_builders %{fenced_intake_report: %{key: "triage", too_large: :triage_too_large}}

  # The ref sources a `:judge` pass can resolve. `:story_branch_for_runner_prefixes` is a
  # `:build` source (`DispatchPayload.fill/3`), derived per story from the target runner.
  @ref_sources [:source_base_branch]

  # The ref sources and payload builders a `:build` pass can hand `Placement.place/4`.
  @build_ref_sources [:source_base_branch, :story_branch_for_runner_prefixes]
  @build_payloads [:story_payload]

  # The ref sources `VerifierPlacement.place/4` resolves: the stage row's branch (the pull
  # request's own) and the intake source's base branch.
  @verify_ref_sources [:stage_branch, :source_base_branch]

  # The sweeps this pass can run, and the tag each one's outcomes carry.
  @sweep_tags %{stranded_triaged_unbound: :stranded}

  # `Placement.place/4`'s refusals that clear only when a person acts — no operator key, a
  # halted or agent-rooted tenant, a project with no single intake source, a runner whose own
  # declaration leaves no room for a branch — and which a `:build` pass therefore reports
  # `:blocked` at ERROR rather than `:unplaceable` at info. `{:branch_not_allowed, _, _}` and
  # `{:invalid_branch_name, :branch, _}` are absent on purpose: both refuse a CALLER-supplied
  # `branch`, and the pass sends none.
  @build_blocked [:no_operator_key, :tenant_halted, :custody_tier_required]

  @doc """
  One pass of `spec`, or `{:ok, []}` while `:dispatch_driver_enabled` is off.

  Options:

  - `:limit` (required) — the most candidates the pass attempts.
  - `:budgets` — the session budgets, already decided. Absent, `budgets/1` reads the spec's
    pair and a missing or over-ceiling value is returned as the error, before anything runs.
  - `:enabled?` — the switch; defaults to `DispatchDriver.enabled?/0`, and for a `:draft` to
    that AND `drafts_enabled?/0`.
  - `:dispatch` — a `:judge` pass's push; defaults to `&Loopctl.Runners.dispatch/3`.
  - `:place` — a `:build` pass's placement; defaults to `&Loopctl.Delivery.Placement.place/4`.
    It is handed the operator key and the actor label the pass resolved, never anything a
    caller of `run/2` supplied: the seam is the call, not the identity.
  - `:sweep_limit` — the most rows each sweep finishes per pass (default #{@sweep_limit}).

  Raises `ArgumentError` for a spec this pass cannot run: one that names a payload builder, a
  ref source or a sweep its archetype's pass has no clause for. A spec is code, so that is a
  programming error, never a runtime state.
  """
  @spec run(Spec.t(), [option()]) ::
          {:ok, [outcome()]} | {:error, {:unset, atom()} | {:over_contract_maximum, atom()}}
  def run(%Spec{} = spec, opts) when is_list(opts) do
    :ok = runnable!(spec)
    limit = Keyword.fetch!(opts, :limit)

    if Keyword.get_lazy(opts, :enabled?, fn -> enabled?(spec) end) == true do
      with {:ok, budgets} <- fetch_budgets(spec, opts),
           do: {:ok, pass(spec, limit, budgets, opts)}
    else
      {:ok, []}
    end
  end

  @doc """
  Whether `:draft` passes may run: `:draft_dispatch_enabled` (`DRAFT_DISPATCH_ENABLED`), OFF
  unless set to exactly `true`. Read with `DispatchDriver.enabled?/0`, never instead of it.
  """
  @spec drafts_enabled?() :: boolean()
  def drafts_enabled?, do: Application.get_env(:loopctl, :draft_dispatch_enabled, false) == true

  defp enabled?(%Spec{archetype: :draft}), do: DispatchDriver.enabled?() and drafts_enabled?()
  defp enabled?(%Spec{}), do: DispatchDriver.enabled?()

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
  Every runner of `tenant_id` that would accept a dispatch of `spec` for `repo` right now, in
  the order to try them (fewest slots in flight first).

  The tenant's admission headroom first, when `spec.runner` names `:tenant_admission_headroom`:
  `Loopctl.Runners.Capacity.admit/2` is one aggregate read, and a tenant at its admission cap
  has no runner for any story. Then `Loopctl.Runners.Selection.runners/3` for `spec.kind`:
  connected, not draining, the repository and the kind declared, a free slot and a
  subscription that is not exhausted.
  """
  @spec runners(Spec.t(), Ecto.UUID.t(), String.t()) :: [Runner.t()]
  def runners(%Spec{} = spec, tenant_id, repo) when is_binary(tenant_id) and is_binary(repo) do
    if admitted?(spec, tenant_id),
      do: Selection.runners(tenant_id, spec.kind, repo),
      else: []
  end

  defp admitted?(%Spec{runner: facts}, tenant_id) do
    :tenant_admission_headroom not in facts or
      Capacity.admit(Loopctl.AdminRepo, tenant_id) == :ok
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

  defp pass(%Spec{archetype: :build} = spec, limit, budgets, opts) do
    place = Keyword.get(opts, :place, &Placement.place/4)

    {outcomes, _cache} =
      spec
      |> candidates(limit)
      |> Enum.map_reduce(%{}, fn candidate, cache ->
        attempt_build(spec, candidate, budgets, place, cache)
      end)

    outcomes
  end

  # THE VERIFIER PASS (US-48.18): a `:judge` whose candidates are placed, not pushed. Each one
  # goes through `VerifierPlacement.place/4`, handed the operator key this pass resolved, the
  # spec's runner selection and the push — never an identity a caller of `run/2` supplied.
  defp pass(%Spec{archetype: :judge, payload: :verify_payload} = spec, limit, budgets, opts) do
    dispatch = Keyword.get(opts, :dispatch, &Runners.dispatch/3)

    {outcomes, _cache} =
      spec
      |> candidates(limit)
      |> Enum.map_reduce(%{}, fn candidate, cache ->
        attempt_verify(spec, candidate, budgets, dispatch, cache)
      end)

    outcomes
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
        {too_large(spec, candidate), cache}

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

  # A `:judge` takes the screen's route to a person. A `:draft` names no route (`[]`): it
  # stores the refusal instead, so the story stops being a candidate, and moves nothing.
  defp too_large(%Spec{archetype: :draft} = spec, %{tenant_id: tenant_id, story_id: story_id}) do
    case ReplyDrafts.refuse(tenant_id, story_id, :payload_too_large) do
      :ok -> :refused
      {:error, reason} -> blocked(spec, %{tenant_id: tenant_id, story_id: story_id}, reason)
    end
  end

  defp too_large(spec, candidate), do: escalate(spec, candidate, spec.screens.payload_too_large)

  # The order is the order the triage pass read in, and it is load-bearing for the outcome a
  # story gets: the refs are judged before the payload is built, so a legacy source is
  # `:blocked` even for a ticket that is also too large, and both before any runner is chosen.
  defp send_dispatch(spec, %{tenant_id: tenant_id, story_id: story_id}, budgets, dispatch) do
    with {:ok, story} <- fetch_story(tenant_id, story_id),
         {:ok, input} <- payload_input(spec, tenant_id, story),
         {:ok, source} <- Intake.source_for_project(tenant_id, story.project_id),
         {:ok, refs} <- resolve_refs(spec, source),
         {:ok, object} <- build_payload(spec, input),
         [%Runner{} = runner | _] <- runners(spec, tenant_id, source.repo_full_name) do
      dispatch.(tenant_id, runner.id, payload(spec, story, source, refs, object, budgets))
    else
      {:error, reason} -> {:error, reason}
      [] -> {:error, :no_runner}
    end
  end

  # `:fenced_intake_report` reads the intake record: the reporter's words ARE the payload,
  # which is why the candidate read requires one (`:intake_record_required`).
  defp payload_input(%Spec{payload: :fenced_intake_report}, tenant_id, story),
    do: Intake.get_record(tenant_id, story.intake_record_id)

  # `TriagePayload.build/1`: the reporter's words, fenced, refused whole when the rendered
  # object will not fit the contract.
  defp build_payload(%Spec{payload: :fenced_intake_report}, record),
    do: TriagePayload.build(record)

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

  # ── the verifier pass ───────────────────────────────────────────────────────────────────────

  # No selectable runner is `:no_runner`; a refusal that clears by itself is
  # `:deferred`; a state only a person clears is `:blocked`; an escalation is `:escalated`.
  @verify_blocked [
    :no_operator_key,
    :tenant_halted,
    :custody_tier_required,
    :invalid_branch,
    :invalid_base_branch,
    :missing_implementer_dispatch,
    :unresolvable_dispatch_lineage
  ]

  @verify_deferred [:not_verifiable, :not_pr_route] ++ @transient

  defp attempt_verify(spec, %{tenant_id: tenant_id} = candidate, budgets, dispatch, cache) do
    {key, cache} = operator_key(tenant_id, cache)

    result =
      with {:ok, key} <- key do
        VerifierPlacement.place(tenant_id, candidate.story_id, budgets,
          api_key: key,
          runners: &runners(spec, tenant_id, &1),
          dispatch: dispatch,
          actor_label: actor_label(spec)
        )
      end

    case result do
      {:ok, :dispatched} ->
        {:dispatched, cache}

      {:ok, :escalated} ->
        {:escalated, cache}

      {:error, reason} when reason in [:no_runner, :runner_exhausted] ->
        {:no_runner, Selection.note_no_runner(cache, label(spec), candidate)}

      {:error, reason} when reason in @verify_blocked ->
        {blocked(spec, candidate, reason), cache}

      {:error, reason} when reason in @verify_deferred ->
        {deferred(spec, candidate, reason), cache}

      {:error, {:verifier_mint_failed, _} = reason} ->
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

  # ── the :build pass ─────────────────────────────────────────────────────────────────────────

  # ONE STORY MAY NOT KILL THE PASS, the lesson `TriageTriggerWorker` records: the read is
  # oldest-first, so a story that raises sits at the head of every later batch too. EXITS as
  # well as raises — a pool checkout timeout exits.
  #
  # The tenant-level facts are cached ACROSS candidates and the runner facts are not: a
  # tenant's operator key does not change while a pass runs, while its runners' free slots
  # change with every story this very pass places. So is whether the tenant's `:no_runner`
  # note has been logged (`Selection.note_no_runner/3`).
  defp attempt_build(spec, candidate, budgets, place, cache) do
    {result, cache} = place_candidate(spec, candidate, budgets, place, cache)
    outcome = classify_build(spec, candidate, result)

    {outcome, note_if_no_runner(spec, outcome, candidate, cache)}
  rescue
    error -> {errored(spec, candidate, Exception.format(:error, error, __STACKTRACE__)), cache}
  catch
    kind, value ->
      {errored(spec, candidate, Exception.format(kind, value, __STACKTRACE__)), cache}
  end

  # THE ORDER IS LOAD-BEARING for the outcome a story gets: a project no runner takes is
  # `:no_runner` before the operator key is read, so a tenant with no usable key still reports
  # `:no_runner` for a story no machine would take.
  defp place_candidate(spec, %{tenant_id: tenant_id, story_id: story_id}, budgets, place, cache) do
    with {:ok, story} <- fetch_story(tenant_id, story_id),
         {:ok, source} <- Intake.source_for_project(tenant_id, story.project_id),
         [_ | _] = runners <- runners(spec, tenant_id, source.repo_full_name),
         {{:ok, key}, cache} <- operator_key(tenant_id, cache) do
      {place_on_first_usable(spec, tenant_id, runners, {story, source, budgets}, key, place),
       cache}
    else
      {{:error, _reason} = error, %{} = cache} -> {error, cache}
      {:error, reason} -> {{:error, reason}, cache}
      [] -> {{:error, :no_runner}, cache}
    end
  end

  # ONE MISCONFIGURED MACHINE MAY NOT STOP A REPOSITORY (846.2 review round 2, finding 3), so a
  # refusal `spec.advance_on` names tries the next runner rather than ending the story's turn.
  # See `Loopctl.Agents.Spec` for why only machine refusals decided before the mint qualify,
  # and for the difference between the two: `:runner_exhausted` is passed over WITHOUT becoming
  # the answer, `{:no_conforming_branch, _}` is advanced past AND kept as it, so a pass on which
  # every machine is misconfigured still reports the state that needs a person.
  #
  # A FRESH dispatch per runner: each attempt is its own `dispatch_id`, as the driver's was.
  defp place_on_first_usable(spec, tenant_id, runners, {story, source, budgets}, key, place) do
    Enum.reduce_while(runners, {:error, :no_runner}, fn runner, last ->
      result =
        place.(tenant_id, runner.id, build_dispatch(spec, story, source, budgets),
          api_key: key,
          actor_label: actor_label(spec)
        )

      advance(spec.advance_on, result, last)
    end)
  end

  defp advance(advance_on, {:error, :runner_exhausted}, last) do
    if :runner_exhausted in advance_on,
      do: {:cont, last},
      else: {:halt, {:error, :runner_exhausted}}
  end

  defp advance(advance_on, {:error, {:no_conforming_branch, _}} = result, _last) do
    if :no_conforming_branch in advance_on, do: {:cont, result}, else: {:halt, result}
  end

  defp advance(_advance_on, result, _last), do: {:halt, result}

  # THE FIELDS THE CALLER OF `place/4` OWNS, and nothing else. `spec.payload` `:story_payload`
  # adds nothing here: `place/4` builds the story object from loopctl's own rows after the
  # claim and refuses one a caller supplies. Of `spec.refs`, `:story_branch_for_runner_prefixes`
  # is OMITTED — the branch depends on what the TARGET runner declared, read off the live
  # socket the push will reach, which only `place/4` holds, so `DispatchPayload.fill/3` fills
  # it there and the two cannot disagree — and `:source_base_branch` is the intake source's,
  # judged by `fill/3` before anything is minted.
  #
  # The budgets are passed rather than re-read: a pass reads them once, so every story it
  # places spends against the same policy even if an operator changes it mid-pass.
  defp build_dispatch(%Spec{payload: :story_payload} = spec, story, source, budgets) do
    refs =
      for {field, :source_base_branch} <- spec.refs,
          into: %{},
          do: {to_string(field), source.base_branch}

    Map.merge(refs, %{
      "dispatch_id" => Ecto.UUID.generate(),
      "story_id" => story.id,
      "kind" => spec.kind,
      "repo" => source.repo_full_name,
      "wall_clock_seconds" => budgets.wall_clock_seconds,
      "max_turns" => budgets.max_turns
    })
  end

  defp classify_build(spec, candidate, result) do
    case result do
      {:ok, _placed} -> :placed
      {:error, :no_runner} -> :no_runner
      {:error, reason} when reason in @build_blocked -> blocked(spec, candidate, reason)
      {:error, {:no_intake_source, _} = reason} -> blocked(spec, candidate, reason)
      {:error, {:ambiguous_intake_source, _, _} = reason} -> blocked(spec, candidate, reason)
      {:error, {:no_conforming_branch, _} = reason} -> blocked(spec, candidate, reason)
      {:error, reason} -> deferred(spec, candidate, reason)
    end
  end

  defp note_if_no_runner(spec, :no_runner, candidate, cache),
    do: Selection.note_no_runner(cache, label(spec), candidate)

  defp note_if_no_runner(_spec, _outcome, _candidate, cache), do: cache

  # THE TENANT'S OPERATOR KEY — an unlineaged `:user` key, which is what `place/4`'s ceiling
  # admits for a caller that no dispatch minted. A pass has no request and therefore no
  # authenticated principal of its own, so it acts as the tenant's operator; anything else
  # would mean minting a credential for a worker, which is a root the custody chain does not
  # have. A tenant with no such key cannot be driven, and that is reported rather than worked
  # around. Resolved HERE, from the database: custody identity is never an input of the pass.
  #
  # NEITHER REVOKED NOR EXPIRED. `Loopctl.Auth` refuses an expired key on every request, and
  # expiry is what key ROTATION uses — `expire_api_key/2` — so a rotated-out key is expired
  # and not revoked. `Placement.resolve_caller/2` validates neither, so an expired key here
  # would mint dispatches and drive custody transitions that the HTTP pipeline would have
  # 401'd. Oldest first among what is left, which is the tenant's original operator key.
  #
  # CACHED PER PASS, keyed by tenant: it cannot change while a pass runs, and the read is on
  # the three-connection AdminRepo pool that every authenticated request in the fleet shares.
  defp operator_key(tenant_id, cache) do
    case Map.fetch(cache, {:operator_key, tenant_id}) do
      {:ok, cached} ->
        {cached, cache}

      :error ->
        now = DateTime.utc_now()

        # NOT A KEY A DISPATCH MINTED (US-48.18, AC-48.18.5). A dispatch may mint a `:user`
        # key, and such a key carries that dispatch's lineage, so `place/4`'s root ceiling
        # refuses it (`root_dispatch_forbidden`) — or, worse, a dispatch-minted operator would
        # become the ROOT every verifier dispatch hangs from, inside the very tree it must be
        # separate from. Any dispatch row naming the key excludes it, revoked or not: a key's
        # lineage is its dispatch row, and a revoked dispatch's key is not an operator's.
        key =
          Loopctl.AdminRepo.one(
            from k in Loopctl.Auth.ApiKey,
              as: :key,
              where: k.tenant_id == ^tenant_id and k.role == :user,
              where: is_nil(k.revoked_at),
              where: is_nil(k.expires_at) or k.expires_at > ^now,
              where:
                not exists(
                  from d in Loopctl.Dispatches.Dispatch,
                    where: d.tenant_id == ^tenant_id and d.api_key_id == parent_as(:key).id,
                    select: 1
                ),
              order_by: [asc: k.inserted_at],
              limit: 1
          )

        result = if key, do: {:ok, key}, else: {:error, :no_operator_key}
        {result, Map.put(cache, {:operator_key, tenant_id}, result)}
    end
  end

  # ── the kind-named strings ──────────────────────────────────────────────────────────────────

  # `"triage"` -> `"TriageDispatcher"`: the prefix every line of the pass carried before it
  # moved, so an operator's log search and alert still match. A `:build` pass is the dispatch
  # driver's, whatever its kind: `"DispatchDriver"`.
  defp label(%Spec{archetype: :build}), do: "DispatchDriver"
  defp label(%Spec{id: id}), do: Macro.camelize(id <> "_dispatcher")

  # `"worker:triage_dispatcher"`: the stage audit's actor. A `:build` pass's is the label
  # `place/4` records on the claim, the transition and any release.
  defp actor_label(%Spec{archetype: :build}), do: "worker:dispatch_driver"
  defp actor_label(%Spec{id: id}), do: "worker:" <> id <> "_dispatcher"

  # `"triage_dispatch:triage_too_large"`: the escalation reason an operator reads on the row.
  defp too_large_reason(%Spec{id: id} = spec),
    do: "#{id}_dispatch:#{payload_builder(spec).too_large}"

  # ── what this pass can run ──────────────────────────────────────────────────────────────────

  # The verifier pass: no sweep (a placement that fails revokes what it minted, so nothing is
  # left half-taken), only refs it resolves itself, and both of the screens it takes.
  defp runnable!(%Spec{archetype: :judge, payload: :verify_payload} = spec) do
    unsupported =
      [
        {:refs, Enum.uniq(Keyword.values(spec.refs)) -- @verify_ref_sources},
        {:sweeps, Map.keys(spec.sweeps)},
        {:screens, [:no_independent_verifier_runner, :verdict_stale] -- Map.keys(spec.screens)}
      ]
      |> Enum.reject(fn {_field, values} -> values == [] end)

    if unsupported == [],
      do: :ok,
      else:
        raise(
          ArgumentError,
          "#{spec.id}@#{spec.version}: Loopctl.Agents.Dispatcher cannot run the verifier " <>
            "pass over " <> inspect(unsupported)
        )
  end

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

  # A `:build` pass hands `Placement.place/4` a dispatch it can complete: no sweep (a placement
  # that fails is undone by `place/4` itself, so nothing is left half-taken for a sweep to
  # finish), the story payload `place/4` builds, and only refs `place/4`'s `fill/3` resolves.
  defp runnable!(%Spec{archetype: :build} = spec) do
    unsupported =
      [
        {:payload, [spec.payload] -- @build_payloads},
        {:refs, Enum.uniq(Keyword.values(spec.refs)) -- @build_ref_sources},
        {:sweeps, Map.keys(spec.sweeps)}
      ]
      |> Enum.reject(fn {_field, values} -> values == [] end)

    if unsupported == [],
      do: :ok,
      else:
        raise(
          ArgumentError,
          "#{spec.id}@#{spec.version}: Loopctl.Agents.Dispatcher cannot run the :build " <>
            "pass over " <> inspect(unsupported)
        )
  end

  # A `:draft` pass is the `:judge` pass with no sweep: the same payload builders and ref
  # sources, and a `:payload_too_large` screen for the builder's refusal (whose route is `[]`).
  defp runnable!(%Spec{archetype: :draft} = spec) do
    unsupported =
      [
        {:payload, [spec.payload] -- Map.keys(@payload_builders)},
        {:refs, Enum.uniq(Keyword.values(spec.refs)) -- @ref_sources},
        {:sweeps, Map.keys(spec.sweeps)},
        {:screens, if(Map.has_key?(spec.screens, :payload_too_large), do: [], else: [:missing])}
      ]
      |> Enum.reject(fn {_field, values} -> values == [] end)

    if unsupported == [],
      do: :ok,
      else:
        raise(
          ArgumentError,
          "#{spec.id}@#{spec.version}: Loopctl.Agents.Dispatcher cannot run the :draft " <>
            "pass over " <> inspect(unsupported) <> " (a :payload_too_large screen is required)"
        )
  end

  # ── log lines ───────────────────────────────────────────────────────────────────────────────

  # A state only a person clears — no intake source on the project, a record that is gone, a
  # source whose base branch is not a ref — logged at ERROR for the reason `DispatchDriver`
  # gives: a queue that never drains while every pass reports `:ok` at `info` is
  # indistinguishable from an empty one.
  #
  # The `:build` line keeps the driver's own wording, which says the one thing an operator
  # watching a queue that never drains needs to read: it will not clear by itself.
  defp blocked(spec, candidate, reason) do
    Logger.error(
      "#{label(spec)}: BLOCKED until somebody changes something#{blocked_suffix(spec)}: " <>
        "story_id=#{candidate.story_id} reason=#{inspect(reason)}",
      tenant_id: candidate.tenant_id
    )

    :blocked
  end

  defp blocked_suffix(%Spec{archetype: :build}), do: " — this will not clear by itself"
  defp blocked_suffix(%Spec{}), do: ""

  # A refusal that clears on its own: `:deferred` for a `:judge` pass, `:unplaceable` for a
  # `:build` one — the driver's name for the same thing, which its worker and its operators
  # read.
  defp deferred(spec, candidate, reason) do
    Logger.info(
      "#{label(spec)}: leaving for the next pass: story_id=#{candidate.story_id} " <>
        "reason=#{inspect(reason)}",
      tenant_id: candidate.tenant_id
    )

    transient_outcome(spec)
  end

  defp transient_outcome(%Spec{archetype: :build}), do: :unplaceable
  defp transient_outcome(%Spec{}), do: :deferred

  defp errored(spec, candidate, detail) do
    Logger.error(
      "#{label(spec)}: candidate failed, continuing with the rest of the pass: " <>
        "story_id=#{candidate.story_id} detail=#{detail}",
      tenant_id: candidate.tenant_id
    )

    :errored
  end
end
