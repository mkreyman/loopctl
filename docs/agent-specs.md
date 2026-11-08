# Agent specs

An agent spec is the compiled description of one dispatch kind: which stories it picks, what it
sends a runner, what the runner's session may answer, and what that answer may do to custody
state. Epic 48 built the mechanism. This document describes the code as it shipped; where it and
the PRD (`docs/user_stories/epic_48_agent_specs/PRD.md`) disagree, the code is right.

Every agent has two halves that share one key, `{id, version}`:

- the **spec**, in loopctl: a module under `lib/loopctl/agents/specs/`, collected by
  `Loopctl.Agents.Registry`;
- the **template**, in `loopctl-runner`: an entry in `LoopctlRunner.Templates` plus the prompt
  module it renders, held to a golden and an eval set.

loopctl never sends prose. A dispatch carries typed fields only, and the runner holds every
instruction its session reads. A control plane that could hand a runner prose could run anything
on it.

For the custody rules this mechanism sits inside, read `.claude/skills/chain-of-custody/SKILL.md`
and the Security & Trust Model section of `CLAUDE.md`.

## The registry

`Loopctl.Agents.Registry` is the list of spec modules in its `@modules` attribute. There is no
table, no API and no tenant row behind it. A spec changes only through a code change, because its
outcomes and effects decide which custody edges a runner message can drive. A spec writable by a
key could aim an agent-producible outcome at a claim or at a human-only edge, and let one
principal both produce and certify. That is the failure the custody model exists to prevent.

The registry checks, when it compiles, that `{id, version}` is unique and that `kind` is unique.
So there is one spec per dispatch kind. It raises `ArgumentError` naming the duplicate otherwise.

Its functions: `all/0`, `fetch/2` (`{:error, :unknown_spec}`), `for_kind/1`
(`{:error, :unknown_kind}`), `kinds/0`, `default_kind/0` and `claim_holding_kinds/0`.
`default_kind/0` is `implement@1`'s kind, because a ledger row written before dispatches carried a
`kind` was an implement dispatch.

### The specs

The list is `Registry`'s `@modules`. A pull request that adds a spec adds its row here.

| spec | archetype | dispatch kind | pass | cron caller |
|---|---|---|---|---|
| `triage@1` | `:judge` | `triage` | `Loopctl.Agents.Dispatcher.run/2` | `Loopctl.Workers.TriageDispatchWorker` |
| `implement@1` | `:build` | `implement` | `Loopctl.Agents.Dispatcher.run/2` (wrapped by `Loopctl.Delivery.DispatchDriver`) | `Loopctl.Workers.DispatchDriverWorker` |
| `reply_draft@1` | `:draft` | `reply_draft` | `Loopctl.Agents.Dispatcher.run/2` | `Loopctl.Workers.ReplyDraftDispatchWorker`, every minute |
| `verify@1` | `:judge` | `verify` | `Loopctl.Agents.Dispatcher.run/2`, placing through `Loopctl.Agents.VerifierPlacement` | `Loopctl.Workers.VerifyDispatchWorker`, every minute |
| `spec_tuner@1` | `:draft` | `spec_tune` | `Loopctl.Agents.Tuning.run/1` | `Loopctl.Workers.SpecTunerDispatchWorker`, weekly |

`spec_tuner@1` is the one spec whose id is not its kind. It is also the one dispatch with no
story.

### The tests that bind it

| test | what it holds |
|---|---|
| `test/loopctl/agents/registry_test.exs` | the registry's kinds equal `RunnerContract.Kinds.all/0` and the `runner_dispatches_kind` database CHECK; `triage@1`'s outcomes equal `TriageVerdict`'s routes and the contract's enum; `implement@1`'s `stage` routes equal `StageMachine.runner_transitions/0` and its effects equal `StageMachine.reportable_effects/0`; every named transition is in `StageMachine.transitions/0`; no spec names a human-only edge; refs name exactly the contract's ref fields; every result message is one the runner channel accepts; the budget keys equal `DispatchPayload.budget_keys/1`; only an allowlisted set of `lib/` files names the registry or a spec, in both directions; no migration creates storage for specs |
| `test/loopctl/agents/spec_test.exs` | each compile-time rule below, by building a bad spec and asserting the `CompileError` |
| `test/loopctl/agents/candidates_test.exs` | the predicate corpus, the closed set in `Candidates.validate/1`, and tenant isolation of the candidate read |
| `test/loopctl/agents/tuning_no_self_edit_test.exs` | an AST scan of `lib/`: every `prompt: {id, version}` literal is in a spec module, and nothing turns a tuning draft into a dispatch or a file |
| `test/loopctl/agents/verify_custody_test.exs` | `bind_verifier_dispatch/4`'s refusals, and that on the pull-request route only the bound verifier reports, reviews and verifies |
| `test/loopctl/delivery_gates/measurement/eval_replay_test.exs` | every committed eval result replays to its expected screens, and replay agrees with the live path |

Adding a kind therefore touches the contract's kind vocabulary and a migration that widens the
`runner_dispatches_kind` CHECK, in the same change as the spec. Adding a module that reads the
registry means adding it to the registry test's `@readers` list.

## Archetypes

The archetype decides what an agent may do to custody state. The spec only chooses within it.

| archetype | may name these transitions | may name these effects | claims the story | answers with |
|---|---|---|---|---|
| `:build` | runner-reportable only: `StageMachine.runner_transitions/0` | `StageMachine.reportable_effects/0` | yes: `Loopctl.Delivery.Placement.place/4` claims and mints a session dispatch, binding `implementer_dispatch_id` and `assigned_agent_id` | `stage` and `session_ended` (`implement@1`); a `:build` spec may never name `agent_result` |
| `:judge` | control-only: in `StageMachine.transitions/0` and absent from `runner_transitions/0` | `:triage_dispatch_id`, `:story_draft`, `:verify_verdict`, `:verified_head_sha` | no: the dispatch echoes the story's current `claim_epoch` | its own verdict message (`triage_verdict`), or `agent_result` if it names `:verify_verdict` |
| `:draft` | control-only, as `:judge`; every route may be `[]` | `:reply_draft`, `:tuning_draft` | no | `agent_result` |

`Loopctl.Agents.Spec.allowed_transitions/1` and `allowed_effects/1` are these columns as code.

Three rules hold for every archetype:

- **No spec may name a transition over a human-only edge.** `StageMachine.human_only?/1` is true
  for `:human_resolution` alone. That edge is a person acting on an escalation, and nothing an
  agent produces may aim at it.
- **A transition is a whole `{from, to, edge}` triple, never an edge alone.** The same edge is
  runner-reportable from one stage and control-only from another. `:forward` from `ci` is a
  runner's merge report; `:forward` from `detected` is the triage step control takes on a
  verdict.
- **A runner may report only what its own session did and control can check, plus its own
  escalation.** That is why `runner_transitions/0` is built from two allowlists:
  `runner_source_stages/0` (the in-flight stages plus `merged`) and `runner_reportable_edges/0`
  (`:forward`, `:ci_red`, `:review_findings`, `:base_moved`, `:merge_refused`,
  `:session_escalated`). A verdict another principal reaches (`:merge_gate`,
  `:verification_failed`, `:budget_exceeded`, `:verify_rejected`) is never on the wire.

The effects a runner may never carry are `StageMachine.control_written_effects/0`: `runner_id`,
`merge_gate_allowed_sha`, `triage_dispatch_id` and `verified_head_sha`. A runner carrying the
merge gate's allow for its own head would pre-authorise the gate that judges it. A runner carrying
`verified_head_sha` would certify its own work.

### What each archetype's semantics keep in code

Some behaviour is the archetype's, not a spec field's, and no spec can change it:

- claiming and the session-dispatch mint (`Placement.place/4`, which refuses any kind whose spec
  is not a `:build` with `:not_placeable_kind`);
- operator-key resolution, from the database, never from an input;
- the `implementer_dispatch_id` and `triage_dispatch_id` bindings;
- what `session_ended` does to a story (`Loopctl.Delivery.RunnerStages.end_session/4`);
- every L4 custody gate.

`Spec.holds_claim?/1` is the one reading of "is this an implement session". It is true only for a
`:build` spec. A `nil` kind reads as `Registry.default_kind/0`. A kind no spec describes holds no
claim: failing closed is the point, because reading an unknown kind as claim-holding is what would
let it claim. The ledger and `Placement` both ask this function.

### Empty routes

A route is a non-empty list of transitions, except in two cases where `[]` means "this outcome or
screen moves nothing":

- every route of a `:draft`, whose output is a stored artifact a person releases;
- a `:judge` that names the `:verify_verdict` effect. A verifier's `pass` moves no stage; it writes
  custody and the head it judged. A stale verdict is dropped and moves nothing.

### `verify@1` and the pull-request route

On the pull-request route (`Intake.pr_route?/3`) the implementer never calls `report`,
`review-complete` or `verify`. Without a verifier the merge gate's custody fact is never `:ok`, and
the gate refuses every story. `verify@1` supplies the custody acts, and it does so without giving
any runner a key.

1. `VerifierPlacement.place/4` re-reads the story. It must be at `ci` with a `head_sha`, a
   `pr_number`, a usable `branch` and an unverified head; otherwise `{:error, :not_verifiable}`, or
   `{:error, :invalid_branch}` when the branch is present but not a usable ref.
2. It requires the source to be in mode `pr`, the tenant not custody-halted, and the tenant
   human-anchored.
3. It drops every runner whose agent is the implementer's (the story's `assigned_agent_id` and the
   implementer dispatch's `agent_id`) and every runner with no agent.
4. If at least one runner was selectable, every one of them is the implementer's agent, and the
   tenant has no live runner with any other agent, it escalates the story over `{:ci, :escalated, :no_independent_verifier_runner}`
   for a person to add a machine. If another agent's machine is merely busy, it answers
   `{:error, :no_runner}` and the next pass looks again; so does a pass with no selectable runner
   at all.
5. It mints verifier dispatch B under the operator key as a new root (`parent_dispatch_id: nil`),
   role `:orchestrator`, for the chosen runner's agent. B's raw key is discarded. The runner is sent
   no credential; the dispatch's `dispatch_id` is B's id, which is how a verdict is matched to B.
6. `Progress.bind_verifier_dispatch/4` binds B. It fails closed on a story with no implementer
   dispatch, a dispatch minted for another story, a revoked dispatch, an empty lineage, a shared
   root, or the implementer's agent (a `nil` agent counts as the same agent). It retires any
   earlier report and verification and clears the stage's `verified_head_sha`.
7. It pushes the `verify` dispatch with the story object and `verify: {pr_number, head_sha}`.

A refusal after the mint revokes B.

On a pr-route story, `report`, `review-complete` and `verify` refuse `409 pr_route_verifier_only`
to every caller whose lineage leaf is not the bound `verifier_dispatch_id`. REJECT is exempt,
because sending work back is remediation. No custody violation is recorded: a second root reaching
for the act is a routing mistake, not byzantium.

`Loopctl.Agents.VerifyVerdict` applies the verdict in `Loopctl.Workers.VerifyVerdictWorker`, a job
enqueued after the ledger write commits. It drops the verdict, writes a `verify_verdict_dropped`
audit row and revokes B when:

- `:verifier_not_bound`: the story's `verifier_dispatch_id` is not the verdict's dispatch, B is not
  live, or B's agent is not the agent of the runner that answered;
- `:verdict_stale`: the story is no longer at `ci`, or its head is not the head the verdict judged.

On `pass` it starts the implementer if needed, then reports, reviews and verifies the story as B
(B's `agent_id` and `lineage_path`, read off the dispatch row control minted). Each step is skipped
when already done, so a retried job resumes. A report or review step found done under another
agent is `{:error, :custody_act_by_other}`, never a skip. A verify step found done is skipped
without that check: on a pr-route story only the bound verifier can verify
(`pr_route_verifier_only`), so a verified story there is this verdict's own earlier attempt. Then it writes `verified_head_sha` under the row
lock, guarded on the head still being the judged one. On `reject` it takes
`{:ci, :implementing, :verify_rejected}` with the findings as the reason. Either way B is revoked.
A refusal in `@retryable` (`:busy`, `:capacity_busy`, `:capability_mint_failed`,
`:audit_chain_append_failed`) retries; a custody-halted tenant snoozes the job 300 s; a tenant
that is not human-anchored is cancelled with `:custody_tier_required`; anything else is cancelled and the story is a candidate
again on the next pass. `VerifyVerdict.enqueue_unapplied/1`, run by the verify worker every
minute, enqueues any recorded verdict whose job insert was lost.

## Spec fields

A spec is written as `use Loopctl.Agents.Spec, id: ..., version: ..., ...`. The `use` evaluates
`Spec.new!/2` into a module attribute, so every check below runs when the spec module compiles.
A bad spec is a `CompileError` naming the field and the value, and the archetype where the rule
depends on it. Nothing about a spec
is decided at run time.

Every field is required. An unknown, missing or duplicated field is a `CompileError`.

| field | type | closed set |
|---|---|---|
| `id` | string | matches `^[a-z][a-z0-9_]*$` |
| `version` | positive integer | |
| `archetype` | atom | `:judge`, `:build`, `:draft` |
| `kind` | string | `RunnerContract.Kinds.all/0` |
| `candidates` | map | see [Candidates](#candidates) |
| `sweeps` | `%{sweep => route}` | `:stranded_triaged_unbound` |
| `payload` | atom | `:fenced_intake_report`, `:story_payload`, `:verify_payload`, `:spec_tune_traces` |
| `refs` | keyword | exactly the keys of `RunnerContract.RunnerDispatch.ref_fields/0` (`branch`, `base_branch`), each with a source from `:source_base_branch`, `:story_branch_for_runner_prefixes`, `:stage_branch` |
| `runner` | non-empty list | `:connected`, `:not_draining`, `:repo_declared`, `:kind_declared`, `:free_slot`, `:subscription_not_exhausted`, `:tenant_admission_headroom` |
| `advance_on` | list, may be empty | `:runner_exhausted`, `:no_conforming_branch`; non-empty only on a `:build` |
| `budgets` | `{wall_clock_key, max_turns_key}` | `{:triage_wall_clock_seconds, :triage_max_turns}`, `{:dispatch_wall_clock_seconds, :dispatch_max_turns}`, `{:spec_tune_wall_clock_seconds, :spec_tune_max_turns}` |
| `result` | non-empty list | `"triage_verdict"`, `"stage"`, `"session_ended"`, `"agent_result"` |
| `result_schema` | `OpenApiSpex.Schema` of type `:object`, or `nil` | set if and only if `result` names `"agent_result"` |
| `screens` | `%{screen => route}` | `:payload_too_large`, `:gate_a`, `:gate_b`, `:draft_injection`, `:draft_dispatchable`, `:story_not_dispatchable`, `:injection_detector_draft`, `:verdict_stale`, `:no_independent_verifier_runner` |
| `outcomes` | non-empty `%{outcome => route}` | outcome names match `^[a-z][a-z0-9_]*$` |
| `effects` | list | `StageMachine.effects/0` plus `:story_draft`, `:reply_draft`, `:verify_verdict`, `:tuning_draft`, narrowed by the archetype |
| `rerun` | atom | `:next_pass`, `:requeue_until_retry_ceiling` |
| `concurrency` | atom | `:one_unreleased_dispatch_per_story`, `:one_claim_per_story`, `:one_pending_tuning_per_project_spec` |
| `prompt` | `{template_id, version}` | template id matches `^[a-z][a-z0-9_]*$`, version a positive integer |

What each value means:

- **`sweeps`**: `:stranded_triaged_unbound` finishes a story left at `triaged` with no verdict, no
  binding and no live dispatch, which the too-large route's second transaction failing leaves.
- **`payload`**: `:fenced_intake_report` is `TriagePayload.build/1`, the reporter's words fenced in
  the dispatch's `triage` object. `:story_payload` is the `RunnerStory` that `Placement.place/4`
  builds from loopctl's rows after the claim; it refuses one a caller supplies. `:verify_payload`
  is the story object plus `verify` (`RunnerVerify`). `:spec_tune_traces` is
  `Tuning.input/3`'s `spec_tune` object.
- **`refs`**: `:source_base_branch` is the intake source's `base_branch`, checked with
  `GitRef.valid_name?/1`. `:story_branch_for_runner_prefixes` is derived per story from the target
  runner's `branch_prefixes` inside `place/4`. `:stage_branch` is the pull request's head branch
  from the stage row, which a verifier reads and never writes.
- **`runner`**: the eligibility facts decided before the ledger row is written
  (`Runners.Selection`, `Runners.accepts?/5`, `Runners.Capacity.admit/2`). Only
  `:tenant_admission_headroom` is read from the spec (`Dispatcher`, the `:build` pass's admission
  pre-check); the other values describe checks `Selection` applies to every spec, whatever the
  list says.
- **`advance_on`**: refusals about the machine, decided before anything is minted, on which a
  `:build` pass tries the story's next selected runner. `:runner_exhausted` is passed over without
  becoming the answer. `:no_conforming_branch` is passed over and kept as the answer, so a pass on
  which every machine is misconfigured still reports the state that needs a person. Any other
  refusal concerns the story or has already spent something, so advancing on it would loop.
- **`budgets`**: the config pairs `DispatchDriver.normalise_budget/2` has a ceiling for. The triage
  pair (`TRIAGE_WALL_CLOCK_SECONDS`, `TRIAGE_MAX_TURNS`) budgets the reading sessions (triage,
  verify, reply_draft); the dispatch pair budgets implement sessions; the spec_tune pair
  (`SPEC_TUNE_WALL_CLOCK_SECONDS`, `SPEC_TUNE_MAX_TURNS`) budgets `spec_tuner@1`, whose run holds
  two replays of every eval case of its target. None has a default, by design
  (`deploy/FLY_SECRETS.md`).
- **`result_schema`**: published to runners as `x-connection.agent_result_schemas["<id>@<version>"]`
  in the contract, so a runner validates against loopctl's schema rather than a copy.
- **`screens`**: `:payload_too_large` is `TriagePayload.build/1` refusing a ticket too large to
  send. `:gate_a` and `:gate_b` are `TriageVerdict`'s gates over the lens verdicts and the predicted
  touches. `:draft_injection` and `:draft_dispatchable` screen a drafted story.
  `:story_not_dispatchable` is `StoryPayload.build/3` parking a story the contract cannot describe.
  `:injection_detector_draft` is `ReplyDrafts.screen/1`. `:verdict_stale` and
  `:no_independent_verifier_runner` are the verifier's.
- **`effects`**: `:story_draft` is the drafted story `TriageVerdict` writes. `:reply_draft` is the
  `reply_drafts` row. `:verify_verdict` is the verdict job. `:tuning_draft` is the
  `spec_tuning_drafts` row.
`rerun` and `concurrency` below are descriptive: validated at compile time and read by no code
path. The behaviour each names is enforced where its bullet says.

- **`rerun`**: `:next_pass` retries nothing; the story is a candidate again once its ledger row
  releases. `:requeue_until_retry_ceiling` re-queues a released claim until its counted releases
  reach `DISPATCH_MAX_ATTEMPTS` (`Loopctl.Delivery.RetryCeiling`).
- **`concurrency`**: `:one_unreleased_dispatch_per_story` is the candidate read's
  `:no_live_dispatch_of_self`. `:one_claim_per_story` is the claim itself.
  `:one_pending_tuning_per_project_spec` is the partial unique index
  `spec_tuning_drafts_pending_uidx`.
- **`prompt`**: the runner-held template. Its identity is a compiled literal of one spec module.
  loopctl reads it to name the template a tuning draft improves and an outcome row credits
  (`Tuning`, `Outcomes`). It is not sent on a dispatch, so the runner cannot be told which version
  to run (US-49.6).

### Candidates

`Loopctl.Agents.Candidates` builds the candidate read from a spec's predicate list, so a new spec
picks its stories by naming predicates, never by writing a query. `candidates` is one of two
shapes:

- `%{predicates: [predicate], order: order}`, a story read;
- `%{subject: :spec_outcomes, order: order}`, `spec_tuner@1`'s, whose candidates are (project,
  target spec) pairs read by `Tuning.candidates/2`. `Candidates.query/2` raises rather than read
  stories for it, and `Candidates.story_subject?/1` tells the two apart.

| predicate | a story is a candidate only when |
|---|---|
| `{:stage, stage}` | its stage row is at `stage` |
| `:intake_record_required` | it was filed from an intake record (inner join) |
| `:intake_record_optional` | always; joins its record when it has one (left join) |
| `:single_active_source` | its project is bound to exactly one unrevoked intake source |
| `:issue_not_closed` | its issue's latest delivered state is not `closed` (NULL passes) |
| `:requires_ticket_if_source_says` | its source does not set `triage_requires_ticket`, or its record carries a `ticket_id` |
| `:no_live_dispatch_of_self` | no unreleased ledger row of the spec's own kind names it |
| `{:agent_status_in, statuses}` | its `agent_status` is one of `statuses` |
| `:dependencies_met` | no unmet story or epic dependency |
| `:triage_set_aside` | its stage is `failed` or `escalated` and its latest transition is `triaged -> failed` on `:triage_reject` or `triaged -> escalated` on `:triage_escalate` |
| `:ticket_required` | its record carries a `ticket_id` |
| `:no_reply_draft` | no `reply_drafts` row names it, drafted or refused |
| `:pr_route_source` | its single source is in mode `pr` |
| `:head_unverified` | its stage row records a `head_sha` and no `verified_head_sha` equal to it |
| `:implementer_dispatched` | it names an implementer dispatch and an assigned agent |
| `:no_live_verifier_dispatch` | the verifier dispatch it names, if any, is revoked or expired |

The one order is `:round_robin_project_tenant`: oldest first within a project, every project's
oldest before any project's second, every tenant's first before any tenant's second.

`Candidates.validate/1` refuses a list that breaks a combination rule: exactly one stage predicate
(`{:stage, _}` or `:triage_set_aside`), at most one intake-record predicate and one status list,
`:issue_not_closed`, `:requires_ticket_if_source_says` and `:ticket_required` only with a record
joined, and `:requires_ticket_if_source_says` and `:pr_route_source` only with
`:single_active_source`.

Every exclusion is in the read rather than discovered per story for one reason. A story the pass
selects but cannot act on keeps its `updated_at` frozen, so it sits at the head of an oldest-first
ranking for ever and fills every batch while the worker reports a clean run.

The read runs on `AdminRepo`. The explicit `tenant_id` predicates on every join are its only
isolation.

### What a spec refuses when it compiles

Each of these is a `CompileError` from `Spec.new!/2`, and each exists for the reason given.

| the spec | refused because |
|---|---|
| names an unknown, missing or duplicated field | a field nothing reads is a field a reviewer trusts and nothing enforces |
| has a value outside a field's closed set | every value must be one the dispatch and result code has a clause for |
| names a transition not in `StageMachine.transitions/0` | a route must be one the stage machine can take |
| names a transition over `:human_resolution` | no agent output may aim at a person's edge; this check runs first, whatever the archetype |
| is a `:build` naming a control-only transition | a runner may report only what its session did and control can check |
| is a `:judge` or `:draft` naming a runner-reportable transition | the transition out of a judged stage is control's conclusion, never a runner's report |
| names an effect outside its archetype's list | a `:build` carrying a control-written effect would grant itself a verdict |
| names `advance_on` on a `:judge` or `:draft` | only a placing pass advances to another runner |
| has an empty route on a `:build`, or on a `:judge` that does not name `:verify_verdict` | its outcome is what moves the story, so a route that moves nothing is a mistake |
| names `"agent_result"` and is neither a `:draft` nor a `:judge` naming `:verify_verdict` | a schema check alone cannot judge a result that drives custody edges |
| names `"agent_result"` without an object `result_schema` | an `agent_result` must have a schema to be validated against |
| carries a `result_schema` without naming `"agent_result"` | only an `agent_result` spec reads one |
| has an id, prompt id or version in the wrong format | the id is a wire key in both repositories |

`Candidates.validate/1` errors surface through the same `CompileError`.

## The dispatch pass

`Loopctl.Agents.Dispatcher.run/2` runs one pass of a spec. The archetype picks the pass.

- **`:judge`**: the spec's sweeps first, then the candidates, then for each candidate the payload
  input, the intake source, the refs, the payload built from them, a runner from
  `Selection.runners/3`, and `Runners.dispatch/3`. The refs are resolved before the payload is
  built, on purpose: the payload carries them. It
  claims nothing.
- **`:build`**: for each candidate it calls `Placement.place/4`, which contracts the story, mints
  the session dispatch, claims, builds the story object and pushes. The pass supplies the
  operator key (the tenant's oldest live unlineaged `:user` key, from the database), the dispatch
  fields it owns, and the runner advance.
- **`:draft`**: the `:judge` pass with no sweep and no stage move. A ticket too large to send is
  stored as a refused `reply_drafts` row (outcome `:refused`) rather than escalated.
- **verifier** (a `:judge` whose payload is `:verify_payload`): places each candidate through
  `VerifierPlacement.place/4`.

`spec_tuner@1` does not run through `Dispatcher.run/2`. Its pass is `Tuning.run/1`, because its
subject is not a story.

### Switches

Every pass is behind `:dispatch_driver_enabled` (`DISPATCH_DRIVER_ENABLED`). A `:draft` pass is
behind that and `:draft_dispatch_enabled` (`DRAFT_DISPATCH_ENABLED`, default off) as well, because
a drafter is new work on an operator's machine that no ticket needed before. Off, a pass reads
nothing and reports a clean run. The verify worker's `enqueue_unapplied/1` sweep is not behind the
switch: it dispatches nothing, it only finishes applying an answer a runner already gave.

### What a pass answers

| outcome | archetype | meaning |
|---|---|---|
| `:dispatched` | `:judge`, `:draft` | the dispatch was pushed |
| `:placed` | `:build` | `place/4` claimed and pushed |
| `:no_runner` | all | no eligible runner; a later pass looks again |
| `:deferred` / `:unplaceable` | `:judge`, `:draft` / `:build` | a refusal that clears by itself: the fleet is busy or a race moved something |
| `:blocked` | all | a state only a person clears, logged at ERROR |
| `:escalated` | `:judge` | a screen escalated the story (too large, or no independent verifier runner) |
| `:refused` | `:draft` | a ticket too large to send, stored as a refused draft |
| `:errored` | all | one candidate raised; the rest of the pass continues |
| `{:stranded, outcome}` | `:judge` | a sweep's outcome |

The transient refusals are `@transient` in `Dispatcher`: `:capacity_busy`, `:busy`,
`:admission_limit_reached`, `:runner_at_capacity`, `:rate_limited`, `:stale_claim_epoch`,
`:runner_not_connected`, `:runner_ambiguous`, `:dispatch_already_replied`. Calling any of them
`:blocked` would tell an operator to change something about a queue that is working as intended.

A `:build` pass reports `:no_operator_key`, `:tenant_halted`, `:custody_tier_required`,
`{:no_intake_source, _}`, `{:ambiguous_intake_source, _, _}` and `{:no_conforming_branch, _}` as
`:blocked`.

A pass returns `{:error, {:unset, key}}` or `{:error, {:over_contract_maximum, key}}` before
anything runs when a budget key is unusable. The workers cancel the job on it
(`{:cancel, {:misconfigured, key}}`) rather than fail it, because no retry changes an environment
variable.

`Dispatcher.run/2` raises `ArgumentError` for a spec its archetype's pass has no clause for: a
payload builder, a ref source or a sweep it cannot run, or a `:judge` or `:draft` without a
`:payload_too_large` screen, or a verifier without both of its screens. A spec is code, so that is
a programming error, never a run-time state.

### Which runners a spec reaches

A runner is sent a dispatch of kind `K` only when it declares `K` on join and holds the spec the
registry has for `K` (`Runners.declared_specs/1`). A runner that sends no `specs` is read as
holding version 1 of the spec for each kind it declares, and so is one that sends an empty list
(`Runners.declared_specs/1` reads only a non-empty list). A runner that sends a non-empty list is
held to it.
A spec the runner names that loopctl does not hold makes nothing eligible.

## The runner contract

`priv/runner_contract/v1.json` is the wire contract. It is exported from
`Loopctl.ApiSpec.RunnerContract` by `mix loopctl.runner_contract`, and a test fails when the
checked-in file drifts from the declarations. `loopctl-runner` vendors it. The version is the
file's `x-contract-version`; read it there.

What it carries for agent specs:

- `x-connection.dispatchable_kinds`: every kind loopctl may send. `implied_kinds` is what a runner
  that declares no kinds is read as declaring.
- `x-connection.agent_result_schemas`: each `agent_result` spec's `result_schema`, keyed
  `<id>@<version>`.
- `RunnerDispatch`: `dispatch_id`, `kind`, `repo`, `base_branch`, `branch`, `claim_epoch`,
  `wall_clock_seconds` and `max_turns` are required. `story_id` is required on every kind except
  `spec_tune`, which refuses it and sends `claim_epoch` 0. The kind-specific objects are `triage`,
  `story`, `verify` and `spec_tune`.
- `RunnerJoin.specs`: the `{id, version}` templates the machine holds.

### `agent_result`

`RunnerAgentResultMessage` is the one generic result message:

```json
{"dispatch_id": "<uuid>", "claim_epoch": 0, "spec": {"id": "reply_draft", "version": 1}, "result": {}}
```

`result` is capped at `x-connection.limits.agent_result.max_bytes` under the contract's byte rule.
`RunnerContract.cast_agent_result_message/1` admits the envelope. `Loopctl.Agents.AgentResult`
decides the rest, in order:

1. the spec is one the registry holds at that id and version;
2. the spec reports through `agent_result` (`Spec.reports_agent_result?/1`);
3. `result` satisfies that spec's `result_schema`;
4. the result is recorded once on the dispatch's ledger row
   (`DispatchLedger.record_agent_result/5`), with the spec's effect in the same transaction (for
   `verify@1`, the effect is the enqueue of the verdict job; the verdict applies after commit).

Steps 1 to 3 refuse `invalid_payload` and write nothing. Step 4 refuses `unknown_dispatch` (not
this runner's or this tenant's dispatch), `wrong_dispatch_kind` (a dispatch of another kind than
the spec's), `claim_epoch_mismatch` (an epoch the message does not echo), `dispatch_not_accepted`
and `already_recorded`. A byte-identical resend replays and records nothing a second time. The
channel also answers `rate_limited` and `internal_error`.

The caller is the socket, never the payload. `tenant_id` and `runner_id` are the channel's own
assigns, resolved from the runner credential when the socket connected. Nothing in the message
names a tenant, a runner or a story.

The audit row records the spec's registry id and version and the result's size. It never records
the result's words, because a session that may have read attacker-controlled text wrote them.

`session_ended` for any dispatch whose spec is not a `:build` is `wrong_dispatch_kind`: those
sessions end through their result.

## Runner templates

`LoopctlRunner.Templates` (in `loopctl-runner`) is the runner's half of the registry. An entry is:

| key | meaning |
|---|---|
| `id`, `version` | the spec's `{id, version}` |
| `kind` | the dispatch kind it runs |
| `archetype` | loopctl's archetype, mirrored |
| `run` | `:story` (a worktree of its own branch, `LoopctlRunner.Run`) or `:triage` (a session over a detached tree, `LoopctlRunner.TriageRun`) |
| `result_event` | `"session_ended"`, `"triage_verdict"` or `"agent_result"` |

What a template receives and returns:

- **Receives**: `Templates.render/2` is called with the dispatch's typed object and the repository.
  Per template: implement takes `%{story, where}`, triage `%{triage, repo, opts}`, reply_draft
  `%{triage, repo}`, verify `%{verify, repo, opts}`, spec_tuner `%{spec_tune, repo, context}`.
  Fenced fields (`triage`, a trace's `untrusted`) are data, never instructions.
- **Returns**: the prompt, as a string. The session's answer then goes back over the template's
  `result_event`. A `:build` reports stages and ends with `session_ended`. `triage@1` states its
  verdict through the `loop-verdict` command. An `agent_result` template's result is read from the
  session's final message (`Templates.agent_result?/1`) and must satisfy the spec's published
  `result_schema`. For `spec_tuner@1` the session states only `{new_cases, proposed_template}`;
  the runner adds `scores` from its own eval runs.

Rules the runner enforces:

- A dispatch of kind `K` runs the version-1 template whose kind is `K` (`Templates.for_dispatch/1`).
  The runner refuses to compile two version-1 templates claiming one kind.
- A dispatch for a template the runner does not hold is refused `other` by
  `LoopctlRunner.Control`, never `kind_not_supported`, which is a capability statement.
- Only a `:build` dispatch is held to the machine's `branch_prefixes` (`Templates.prefix_exempt?/1`).
  A `:judge` or `:draft` writes no branch.
- The runner never edits a template at run time. `spec_tuner@1` scores a proposed diff by
  applying it to a copy of each rendered prompt (`LoopctlRunner.TextPatch`), which refuses a hunk
  with no context line to anchor it.

Each template's prompt is held byte for byte to a golden in `test/fixtures/templates/<id>@<version>.txt`
by `test/loopctl_runner/templates_test.exs`.

## The eval harness

An agent change is measured offline, on both sides of the wire, before it reaches a live ticket.

### Runner side: `mix loopctl_runner.eval <spec>[@<version>]`

`LoopctlRunner.Eval` runs each case of `eval/<id>@<version>/` through the runner's own path: the
accept decision (`DispatchPolicy.decide/3`), the template's run, a real session through
`claude-headless.sh`, and the result read off disk as the live path reads it. It opens no socket,
and every session runs with an MCP config naming no server, so an eval cannot reach loopctl.

A case is one JSON file (`LoopctlRunner.Eval.Case`):

```json
{"spec": "triage", "version": 1, "description": "...",
 "input": {"...": "the RunnerDispatch exactly as loopctl would send it"},
 "fixture": {"repo": "fixtures/<name>.json", "commit": "<40-hex sha>"},
 "expectations": {"schema_valid": true, "outcomes_allowed": ["story"],
                  "escalation_codes": [], "lens_agreement": true,
                  "forbidden": ["<regex>"], "screens": [], "rubric": null}}
```

The fixture resolves inside `eval/fixtures` or the run's scratch directory; a case that could reach
outside them refuses the whole run. `escalation_codes` and `lens_agreement` are a `:judge`'s and refused on another archetype.
`rubric` is text for a person and is never scored. `eval/offline/<id>@<version>/<case>.json` is
what the fake CLI answers when the harness runs offline (`--cli`).

The harness writes a result file (format 1) per case with the message the runner would have
pushed and the case's `expected.screens`.

The runner holds a case set for each spec the improvement loop can target; `spec_tuner@1` has none,
because the loop never tunes itself. loopctl commits replayable result files only for the `:judge`
and `:draft` specs whose answers it screens (`test/fixtures/eval_results/`).

### loopctl side: `Loopctl.DeliveryGates.Measurement.EvalReplay`

`EvalReplay.replay/1` answers the half the runner cannot: which of loopctl's screens refuse a
recorded message. It casts the message exactly as `LoopctlWeb.RunnerChannel` does, then runs the
function the live ingest calls before it writes: `TriageVerdict.screen_message/2` for
`triage_verdict`, `AgentResult.admit/2` for `agent_result`. It reads no database.

Committed result files live in `test/fixtures/eval_results/<id>@<version>/`.
`test/loopctl/delivery_gates/measurement/eval_replay_test.exs` replays every one to its
`expected.screens`, and sends each through the live path against real rows to show the two agree.

Its refusals:

| error | why |
|---|---|
| `{:unknown_format, f}`, `:not_a_result` | the file is not a format-1 result |
| `:unknown_spec` | the registry holds no such `{id, version}` |
| `{:event_not_answered_by_spec, e}` | the spec does not answer with that event |
| `{:no_result_screens, "implement@1"}` | `stage` and `session_ended` run no spec screen, so answering `[]` would claim a screen ran and passed |
| `{:message_refused, reason}` | the contract or the spec's schema refused the message: the live path's `invalid_payload` |
| `{:spec_mismatch, ref}` | the message names a spec other than the file's |

Dispatch-time screens (`:payload_too_large`, `:story_not_dispatchable`) are not replayed: a
dispatch they refused was never sent. Neither are write-time outcomes that depend on rows, such as
a reply whose ticket disappeared (`:ticket_missing`).

## The outcome ledger

`Loopctl.Agents.Outcomes` writes one `agent_run_outcomes` row (`Loopctl.Agents.RunOutcome`) per
runner dispatch, keyed by the spec `{spec_id, spec_version}` it ran under. An agent's track record
is then a query, and the improvement loop learns from what people and gates did with the output
rather than from the agent's own report.

Every write rides a write that already exists, in its transaction:

| written by | in the transaction of | what |
|---|---|---|
| `Loopctl.Runners.DispatchLedger` | the session-end write | the row, `end_reason` = the runner's reason, `turns` |
| `Loopctl.Delivery.TriageVerdict` | the `triage_verdicts` insert | `end_reason` `triage_verdict` or `triage_incomplete`, signal `verdict` |
| `Loopctl.Runners.DispatchLedger` | the `agent_result` write and its effect | `end_reason` `agent_result`, signal `draft_screen` or `tuning_status` |
| `Loopctl.Delivery.Stages` | every transition and effect | `merge_gate` (`allow`/`refuse`), `ci_result` (`red`/`green`), `merged`, `merge_refused`, `human_override`, `human_route`, `requeued_after_budget_kill` |
| `Loopctl.Progress.record_review/4` | the review record's Multi | `review_findings` (counts only) |

A signal is `%{"value" => v, "at" => iso8601, "source" => "<event>"}`. The row is unique on
`(tenant_id, dispatch_id)`. Its end is written once and each signal once, so a redelivered event
leaves the row as it was. A stage, gate or review signal names a story, not a dispatch, and is
credited to the story's latest accepted `:build` dispatch, except `human_override` and
`human_route`, which are credited to the story's triage dispatch: the person overrode the verdict.

Every value is loopctl's own: an enum, a stage, a boolean, a count or an id. Nothing a session
wrote reaches a signal. `cost_millicents` stays NULL because no runner message reports it.

`Outcomes.summary/3` aggregates one spec's rows per version over a window (default
`Outcomes.default_window_days/0`, at most `max_window_days/0`): `runs`, `ended`, `successes`,
`human_overrides`, `budget_exhausted`, their rates, and median `elapsed_s` and `turns`. Success is
per archetype:

| archetype | a run succeeded when |
|---|---|
| `:build` | its work merged |
| `:judge` | it recorded a verdict (`triage_verdict` or `agent_result`) that no human overrode |
| `:draft` | its draft was stored `drafted`, or its tuning proposal was judged `proposed` |

## The improvement loop

`spec_tuner@1` proposes a better prompt template for another spec, from that spec's failed runs,
with the eval cases that would have caught them. It claims nothing, has no story, names no stage
edge, and changes nothing it proposes. Its pass is `Loopctl.Agents.Tuning.run/1`, weekly from
`SpecTunerDispatchWorker`.

### What it learns from

`Tuning.candidates/2` picks each (tenant, project, target spec) with at least
`SpecTunerV1.min_outcome_rows/0` outcome rows since its latest answered draft and no pending draft.
The targets are every registry spec except the tuner's own kind, so the loop never tunes itself.

`Tuning.input/3` builds the `spec_tune` object: the target, the target's template `{id, version}`
(the template being improved, not the tuner's own), the eval set `<id>@<version>`, the window, and
the failed runs as traces. A run is a trace when its outcome row carries a failure code
(`Tuning.failures/1`) and its story still has text to fence:

| code | when |
|---|---|
| `human_override` | a person overrode the run |
| `budget_exhausted` | the session ended on a budget |
| `merge_gate_refused` | the merge gate refused the work |
| `merge_refused` | the merge was refused |
| `ci_red` | CI went red |
| `review_findings_high` | the review recorded at least `SpecTunerV1.review_findings_high/0` findings |
| `draft_refused` | the draft was refused |

Every trace field is loopctl's value, except `untrusted`: the story's text, rendered by
`Loopctl.Delivery.Untrusted.render/2`, the fence triage uses. A trace that carries a human decision
includes `human_decision: {route, outcomes}`, the stage the person sent the story to and the
target's outcomes that end there.

### How it is dispatched

The pass inserts a `pending` `spec_tuning_drafts` row first, holding the pair through
`spec_tuning_drafts_pending_uidx`, then pushes. A refused push deletes the pending row. A pending
row older than a day whose dispatch holds no slot is marked `abandoned` by the next pass
(`Tuning.abandon_stale/1`), which frees the pair.

A pass answers per candidate: `:dispatched`, `:no_runner`, `:nothing_to_learn` (no failed run in
the window), `:already_pending`, `:deferred`, `:blocked` (`:unknown_target_spec`,
`:invalid_base_branch`, a project without one intake source) or `:errored`. Only `:dispatched`
spends one of the pass's slots, so a pair that sends nothing cannot starve its tenant's other
pairs.

### What the runner does

`LoopctlRunner.SpecTune` checks that `template` is the target's own template, then loads the
target's eval set and its current template text. The session
states `{new_cases, proposed_template}`. The runner checks every rule loopctl would reject on that
it can see, and sends no result for a proposal that breaks one. Then the eval harness is the
critic, never the session: it runs every existing case and every new case twice, under the current
template and with the diff applied, and builds `scores` from those runs alone. An eval set with no
cases refuses the run, because there is nothing to score against.

The result, validated against `spec_tuner@1`'s `result_schema`, is `new_cases` (the eval case
format minus `input`; each names its `source_trace_id`), `proposed_template`
`{id, from_version, to_version, diff}` and `scores` `{current, proposed, per_case}`. A case carries
no input of its own because a runner-supplied input would let the session write the case it is
then scored on.

### How loopctl judges it

`Tuning.write_result/2` answers the pending row in the ledger's transaction. The status is
`Tuning.decide/2`'s, recomputed from `per_case`; the runner's totals only have to agree.
`{:proposed, []}` requires every check to pass. Otherwise it is `{:rejected, reasons}`:

| reason | the result |
|---|---|
| `template_mismatch` | does not propose a newer version of the template the draft sent |
| `unknown_trace` | has a case naming a trace the draft did not send |
| `expected_not_human_decision` | has a case on an overridden trace that does not expect exactly that person's outcomes |
| `duplicate_case` | names a case, or a per-case line, twice |
| `per_case_incomplete` | has a new case with no per-case line marked new |
| `scores_inconsistent` | reports totals that are not the counts of their per-case column |
| `no_existing_cases` | scored no existing case, so no regression can be ruled out |
| `regression` | has an existing case that passed under the current template and fails under the proposed one |
| `not_better` | does not pass strictly more cases |

A new `proposed` draft supersedes the pair's earlier `proposed` ones.

### Statuses

`Loopctl.Agents.TuningDraft.statuses/0`:

| status | meaning |
|---|---|
| `pending` | the dispatch is out |
| `proposed` | loopctl accepted the proposal |
| `rejected` | loopctl refused it; `rejection_reasons` says why |
| `landed` | a person merged the change and recorded the pull request |
| `superseded` | a later proposal for the same pair replaced it |
| `abandoned` | no answer within a day; the pair is freed, and a late result still answers it |
| `nothing_to_learn` | the window held no failed run; the row closes the window with no dispatch |

`nothing_to_learn` exists because a pair whose window held no failure otherwise stayed due, ranked
first in its tenant, and took that tenant's first slot on every pass.

### How a proposal lands

loopctl never edits a template and never changes a spec version. The template identity is a
compiled literal in one spec module, and `tuning_no_self_edit_test.exs` fails on any other writer.

1. A person reads the draft with the `tuning_drafts` MCP tool (`GET /api/v1/tuning_drafts`).
2. The person turns the diff and the new cases into pull requests: the template, its golden and
   its eval cases in `loopctl-runner`, and the spec in loopctl.
3. Once they merge, the person records it with `tuning_draft_mark_landed`
   (`POST /api/v1/tuning_drafts/:id/landed`, `Tuning.mark_landed/4`), naming the pull request.

Step 2 cannot complete today for a draft whose `to_version` is above 1. The runner resolves only
version 1 of a kind's template (`Templates.for_dispatch/1`), the registry holds one spec per kind,
and the dispatch carries no spec `{id, version}`, so the runner cannot be told which version to
run. US-49.6 adds the live version to the registry and the dispatch.

`mark_landed/4` writes the draft row and an audit entry and nothing else. It refuses
`409 not_proposed` for a draft in any other status, `422` for a `pr_url` that is not
`https://github.com/<owner>/<repo>/pull/<n>`, and `404` for a draft the tenant does not hold. It is
`role: :user` and behind `RequireHumanAnchor`, because it is the operator's word that a person
merged a prompt change; an agent or orchestrator key that could write it could certify a change no
person made.

## Reply drafts

`reply_draft@1` drafts a reply to a support ticket triage set aside. It claims nothing, binds
nothing, and its template is read-only. Its result is `{body}`. `ReplyDrafts.screen/1` runs the
drafted-story screen's detector over the body. The effect writes a `reply_drafts` row in the
ledger's transaction: `drafted`, or `refused` with the screen's codes and no body. A refused body
is stored nowhere. loopctl never sends a draft; a person reads it with `reply_draft_list` and sends
it or not.

## The escalation inbox and digest

`Loopctl.Delivery.EscalationInbox` lists every story parked at `escalated`, findable by why.

`reason_class` is derived from the edge the story entered `escalated` over, never from
`escalation_reason`, which is often session-authored text. Classifying by text would let a session
choose its own class. `EscalationInbox.reason_class/1` is the one mapping, and its test fails when
an edge into `escalated` is added to the stage machine without a class.

| edge | class |
|---|---|
| `budget_reported` | `budget_exhausted` |
| `attempts_exhausted`, `session_escalated`, `runner_gone`, `merge_unanswered` | `session_failed` |
| `triage_escalate` | `triage_escalated` |
| `merge_gate`, `verification_failed`, `review_missing`, `no_independent_verifier_runner`, `ungated_merge` | `gate_refused` |
| `operator_released` | `operator_released` |
| `change_outside_lifecycle`, `reverted_after_verify`, an unknown edge, a missing event | `other` |

Each row names the dispatch that parked the story (its newest ledger row before the escalation) and
that dispatch's spec through `Registry.for_kind/1`. A `budget_exhausted` row also carries the run:
elapsed seconds against the wall clock it was placed under, `turns_used` against `max_turns`, the
branch, the session-end reason, and `work_left_behind` (`true` or `false` as the runner reported,
`:unknown` when it did not say). Every fact comes from the ledger, never from session text.

The inbox reads. Working a row again is `resolve_escalation` (`POST /stories/:id/stage/resolve`),
a `role: :user` key behind `RequireHumanAnchor`. The stage machine also refuses a key a dispatch
minted, so a session cannot resolve the escalation it raised.

`Loopctl.Workers.EscalationDigestWorker` runs daily. For each tenant it posts one coordination
channel post per project holding escalated rows of any reason class, escalated more than an hour
earlier: the count per class, the story ids with their class, and `work_left_behind` on
`budget_exhausted` rows, the one class where a session's leftover work is the question. Every class,
because a triage escalation or a refused merge gate waits on a person exactly as a timed-out
session does. The class is derived from the edge, never from the reason; it never posts
`escalation_reason`, which is untrusted
text and would reach every peer session's channel preview. The key is
`escalation-digest:<project>:<UTC date>`, so a second run on the same day is `:already_posted`.
It posts as the per-tenant system agent `system:escalation-digest`, a reserved prefix no key can
register into. It is not behind `:dispatch_driver_enabled`, because it starts nothing and spends
nothing. The fleet-wide read returns tenant ids only, and each tenant's digest is built by the
tenant-scoped read, so a digest cannot carry another tenant's story.

## Endpoints and MCP tools

| MCP tool | endpoint | gate | why |
|---|---|---|---|
| `agent_outcomes` | `GET /api/v1/agent_specs/:spec_id/outcomes` | `role: :agent` | counts and enums loopctl recorded; no session or ticket text |
| `escalation_list` | `GET /api/v1/escalations` | `role: :agent` | a read cannot advance a custody chain; `escalation_reason` is returned with `escalation_reason_untrusted: true` and as `escalation_reason_fenced` |
| `reply_draft_list` | `GET /api/v1/projects/:project_id/reply_drafts` | `role: :user` | the bodies are ticket-derived text about a third party, sent in the operator's name |
| `tuning_drafts` | `GET /api/v1/tuning_drafts` | `role: :user` | a trace carries a customer's ticket text |
| `tuning_draft_mark_landed` | `POST /api/v1/tuning_drafts/:id/landed` | `role: :user` + `RequireHumanAnchor` | the operator's record that a person merged a prompt change |
| `resolve_escalation` | `POST /api/v1/stories/:id/stage/resolve` | `role: :user` + `RequireHumanAnchor`; the stage machine refuses a lineaged key | the human half of the escalation pair |

A key below the gate's role gets `403 insufficient_role`. A tenant that is not human-anchored gets
`403 custody_tier_required` on `landed` and `resolve`. `agent_outcomes` refuses `400` for a malformed `spec_id`
or a `window_days` outside its range. The list endpoints refuse `400` for a bad filter or limit, or
a foreign or tampered cursor. `mcp-server/README.md` is the source of truth for each tool's
parameters.
