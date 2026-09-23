defmodule Loopctl.Delivery.Placement do
  @moduledoc """
  Places a queued story on a runner (issue #803): the CLAIM and the PUSH, in one call.

  `Loopctl.Runners.dispatch/3` sends a dispatch and claims nothing — its moduledoc says so:
  "Placement and claiming are the caller's (#803)." This is that caller. Without it the loop
  could not dispatch at all: a dispatch pushed to a real runner started a session whose first
  `claimed -> worktree` report was refused `:stale_stage`, because nothing had moved the story
  into `claimed`, and advancing it by hand was then refused `:actor_lineage_required` — the
  guard on a CHAINED transition, which the dispatch path could not satisfy because it held no
  lineage of its own.

  ## The lineage this path uses is MINTED, never asserted

  `Loopctl.Delivery.Stages.advance/4` refuses a chained transition whose caller did not state
  an `:actor_lineage`, and an attested `[]` would have satisfied it. That would have been the
  wrong answer here, and not because it is a lie: the runner's enrollment key genuinely has no
  lineage (`Loopctl.Delivery.RunnerStages` states `[]` for exactly that reason, correctly).
  It is wrong because the story's whole custody provenance would then be "some machine", and
  `stories.implementer_dispatch_id` — the value every L4 gate compares against — would stay
  NULL on work a runner actually did.

  So a placement MINTS a dispatch for the runner session (`Loopctl.Dispatches.create_dispatch/3`),
  as a CHILD of the caller's own dispatch, and uses ITS lineage:

  - the claim records it as `implementer_dispatch_id`, so report, review-complete and verify
    have a real implementer lineage to be separate from;
  - the `story_stage_claimed` chain entry is attributed to it;
  - `stories.assigned_agent_id` is the runner's agent (`runners.agent_id`), so the equality
    check every L4 gate runs ALONGSIDE its lineage comparison names the machine.

  **The lineage ceiling is enforced here, not inherited — which means this module RESOLVES the
  caller's lineage rather than accepting one.** `place/4` takes the `Loopctl.Auth.ApiKey` the
  request authenticated with and derives both the lineage (`Dispatches.lineage_for_api_key/2`)
  and the role from it, exactly as `LoopctlWeb.DispatchController.create/2` does. A lineage
  passed in as an option would be a CLAIM about who the caller is, and enforcing a mint against
  a claimed lineage enforces only that the parent is SOME named leaf — not that it is the
  CALLER's, which is the whole content of `parent_outside_caller_lineage`.

  The session dispatch is parented on the LAST element of that resolved lineage, so it can only
  land inside the caller's own subtree. A caller with NO lineage would be minting a ROOT, which
  only the tenant's operator key may do, so it is refused `:root_dispatch_forbidden` unless the
  key's role is at least `:user` — the same positive operator test, for the same reason: an
  empty lineage is also what a legacy env-var key and an unresolvable dispatch look like.

  ## The halt and the human anchor are applied HERE, because no plug can be

  Minting a custody dispatch and driving a chained custody transition are both behind
  `LoopctlWeb.Plugs.RequireHumanAnchor` on the HTTP surface, and `Dispatches.create_dispatch/3`
  does not check the tier itself — the plug is the whole gate there. This path has no `conn`:
  a worker or an MCP tool calls it directly. So it calls `Loopctl.Tenants.require_human_anchor/1`
  and refuses an `agent_rooted` tenant with `:custody_tier_required`, and
  `Loopctl.Tenants.TierCapabilities.gated_contexts/0` names this module so the advertised
  capability map stays bound to the enforced gate — `gated_controllers/0`'s scan reads
  `lib/loopctl_web` only and cannot see a context-layer gate at all. Letting an agent-rooted
  tenant through would be an L0 regression, and it would be one that the existing drift guard
  was structurally incapable of noticing.

  **The same argument applies to the L6 HALT, and the tier gate alone did not cover it.**
  `CheckCustodyHalt` is a PIPELINE plug, so it blocks `POST /stories/:id/claim` and
  `POST /api/v1/dispatches` — the two things a placement does — and neither
  `Progress.claim_story/3` nor `Dispatches.create_dispatch/3` checks a halt itself.
  `Runners.dispatch/3` does, but at step 2 of the PUSH, which here runs after the mint and
  after both commits: a halted tenant would have got a live ephemeral key, two IMMUTABLE chain
  entries appended under its own chain lock, and a claim-then-release. A halt is what L6 does
  when the system believes the tenant is being lied to, so `not_halted/1` runs before any of
  it. Note also that the lease is NOT a backstop for a halted tenant —
  `Loopctl.Workers.ReclaimExpiredClaimsWorker` skips them — so a claim left standing there
  would never be reclaimed.

  And it is bound the same way, by a SECOND guard for the same reason: this module is the first
  custody-progressing entry point with no route at all, and `custody_surface_test.exs` proves
  its half by walking `LoopctlWeb.Router.__routes__/0`, which cannot see a context function an
  Oban worker calls. `Loopctl.Custody.ContextSurface.halt_enforcing_contexts/0` names this
  module and `test/loopctl/custody/context_surface_test.exs` scans `lib/loopctl/**` for the
  call, in both directions.

  ## The credential the session dispatch mints does NOT reach the session

  `Loopctl.Dispatches.create_dispatch/3` mints an ephemeral key with every dispatch, and the
  `RunnerDispatch` payload (contract 1.5.0) has no field that could carry one — so a runner's
  session keeps authenticating as the runner's ENROLLMENT key, whose lineage is `[]`. The
  dispatch ROW is what this path needs and what the custody gates read; the key is a byproduct
  with no holder.

  **One consequence is real and is not fixed here.** A story this path places has
  `implementer_dispatch_id` set, and `Loopctl.Progress`' report gate answers
  `:caller_lineage_required` to an unlineaged caller on dispatch-minted work — so a session
  reporting over `POST /stories/:id/report` with the runner's own key would be refused. The
  delivery loop does not take that path (a runner reports STAGES over the channel, and
  `Loopctl.Delivery.RunnerStages` states its `[]` explicitly, which `advance/4` accepts), so
  nothing is broken today. Delivering the key is a contract change of its own — a credential
  on the dispatch payload is a security decision, not a field addition — and it is what would
  make a runner session a first-class custody principal.

  ## Which way it fails, and why that way

  The claim and the push CANNOT be one transaction. `Runners.dispatch/3` ends in a PubSub
  broadcast and writes the ledger on the RLS `Loopctl.Repo` in a transaction of its own, so it
  must not be called from inside one. One of the two therefore commits first, and this path
  CLAIMS FIRST.

  That is the recoverable direction, and the other one is not:

  - **Claimed, never pushed.** The story is `assigned` at stage `claimed` with no session. A
    refusal from `Runners.dispatch/3` is answered inline by `undo_claim/5`: release the claim
    (`Loopctl.Progress.force_unclaim_story/3`, which bumps the epoch and requeues the stage row
    over `:claim_released`), unrecord the session dispatch, revoke it.

    **The lease is a PARTIAL backstop, and this used to say it was a total one.** If the
    release fails, `Loopctl.Workers.ReclaimExpiredClaimsWorker` does release the claim over
    `:runner_lost` — but `release_claim_changes/1` clears no dispatch id and nothing revokes a
    dispatch, so the two steps the lease does not perform are precisely the two this path
    added. The unrecord no longer depends on the release having succeeded (it predicates on the
    dispatch id alone), so in practice the gap is the revoke; `log_undo/5` names any step that
    did not do what it was for, because nothing downstream will.

    **And a failed release ESCALATES the story, because the lease is hours and nobody is
    reading the log.** Observed 2026-09-15: the release ran, failed, wrote its `Logger.error`
    and the story sat at `claimed` for four hours. Nothing automatic recovers that state —
    `place/4` answers `:invalid_transition` because the story is `assigned` rather than
    `contracted`, the only stage edges that take `claimed` back to a PLACEABLE `queued` are the
    release's own `:claim_released` — the write that just failed — and the reclaimer's
    `:runner_lost`, and the reclaimer is hours away and skips a halted tenant entirely — so
    `undo_claim/5` parks it over `:session_escalated` and an operator resolves it in one call.
    See `escalate_unreleased_claim/6` for why only the RELEASE earns that, and where the
    recursion stops.
  - **Pushed, never claimed.** A session starts work on a story whose stage row refuses every
    report it makes, for as long as the session runs. Nothing recovers it, because nothing is
    wrong from the row's point of view. That is the failure that was observed in production,
    and it is the one this ordering makes unreachable.

  ## Retries

  Safe to repeat, keyed on the caller's `dispatch_id` — the same key the ledger and the
  capacity slot are already idempotent on:

  - a `dispatch_id` the ledger already holds takes NO second claim, mints no second session
    dispatch and does not bump the epoch again. Its RECORDED `claim_epoch` is what is pushed,
    so a re-send reaches the runner under the claim it was built for, and a claim that has
    since ended is refused `:stale_claim_epoch` by `record_sent/3` rather than silently
    re-placed.
  - a repeat that gets as far as the push finds its ledger row and is broadcast again without
    a second slot (`Loopctl.Runners.DispatchLedger.record_sent/3`).

  A crash BETWEEN the claim and the ledger write leaves a claimed story with no ledger row, so
  a retry of the same `dispatch_id` takes the fresh path and claims again — the second claim
  is refused `:invalid_transition` (the story is `assigned`, not `contracted`) rather than
  double-claiming, and the operator's remedy is the release above. Narrower than the ledger's
  own window and bounded by the same lease.

  ## Partitions, and where this runs

  Nowhere in particular. No process owns a placement: every durable step is a Postgres
  transaction, and the only thing held between them is the caller's stack. A node that dies
  mid-placement leaves the story in one of the two states above, both of which the lease
  bounds. The broadcast crosses the cluster to whichever node holds the runner's socket
  (`Loopctl.Runners`' moduledoc), and a runner unreachable at that moment is a refusal here,
  before the session exists.

  ## Slow connections

  Every wait is bounded by the step that makes it: `Stages.advance/4` sets a 2s `lock_timeout`
  and a 5s `statement_timeout` and answers `{:error, :busy}`, and `record_sent/3` answers
  `{:error, :capacity_busy}`. Both are retryable with the same `dispatch_id`.
  """

  require Logger

  alias Loopctl.Auth.ApiKey
  alias Loopctl.Auth.Role
  alias Loopctl.Delivery.DispatchPayload
  alias Loopctl.Delivery.ImplementerInput
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryPayload
  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Progress
  alias Loopctl.Runners
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Tenants
  alias Loopctl.WorkBreakdown.Stories
  alias Loopctl.WorkBreakdown.Story

  # How long the session dispatch's credential lives. `Dispatches.create_dispatch/3` caps this
  # at four hours of its own accord, while a dispatch's `wall_clock_seconds` may be a day, so
  # the two do NOT line up and this is the shorter of them on purpose: the dispatch row's
  # lineage is what the custody gates read and it outlives the key, while the key itself has
  # no holder at all (see the moduledoc).
  @session_expires_in_seconds 14_400

  # The attribution on a park this module's COMPENSATION wrote. Both this and
  # `StoryPayload`'s park put a story at `escalated` over the same edge, and an operator
  # reading the escalated queue has to be able to tell "loopctl could not describe this story
  # inside the contract" from "loopctl could not give this story's claim back", because the
  # two have different remedies.
  #
  # THE DISTINCTION IS THE SUFFIX, NOT THIS CONSTANT, and that is the correction #865 round 1
  # made. A default only applies when `opts` carries no `:actor_label`, and BOTH callers of
  # `place/4` always pass one — `"api:dispatch_placement"`
  # (`LoopctlWeb.DispatchPlacementController`) and `"worker:dispatch_driver"`
  # (`Loopctl.Delivery.DispatchDriver`). `attach_story/6` forwards that same key into
  # `StoryPayload.build/3`, so in production the two parks carried the IDENTICAL label and the
  # distinction this comment promised did not exist anywhere an operator could read it. The
  # base is now composed with `@compensation_suffix` (`compensation_actor/1`), so the caller is
  # still named and the compensation is distinguishable from the story-object park it may
  # follow. The constant remains as the base for a caller that passes no label at all.
  @escalation_actor "control:placement"

  # Appended to whatever label the placement caller gave, because that label is the only thing
  # in scope that identifies the principal and it is the SAME one `StoryPayload`'s park writes.
  # `story_stage_events.actor_label` is unbounded `text` and `audit_log.actor_label` is
  # `varchar(255)`, so a suffix on a caller label costs nothing at either end.
  @compensation_suffix "/unreleased-claim"

  @type error ::
          :root_dispatch_forbidden
          | :insufficient_role
          | :custody_tier_required
          | :tenant_halted
          | :not_authorized
          | :runner_not_provisioned
          | :runner_declines_work
          | :invalid_transition
          | :wrong_stage
          | :busy
          | atom()
          | {:invalid, [String.t()]}
          | {:invalid_transition, map()}
          | :story_not_accepted
          | :story_not_found
          | {:no_intake_source, Ecto.UUID.t()}
          | {:ambiguous_intake_source, Ecto.UUID.t(), pos_integer()}
          | {:unset, atom()}
          | {:over_contract_maximum, atom()}
          | {:story_not_dispatchable, [String.t()]}
          | {:story_no_longer_dispatchable, [String.t()]}
          | {:escalation_failed, term(), [String.t()]}
          | {:no_conforming_branch, [String.t()]}
          | {:branch_not_allowed, String.t(), [String.t()]}
          | {:invalid_branch_name, atom(), term()}
          | {:branch_not_unique, atom(), String.t(), String.t()}
          | {:branch_conflict, String.t(), String.t()}

  @doc """
  Claims `dispatch["story_id"]` for `runner_id` and pushes the dispatch to it.

  `dispatch` is a `RunnerDispatch` payload with STRING keys, exactly as
  `Loopctl.Runners.dispatch/3` takes one, except that it carries no `"claim_epoch"`: the epoch
  is not known until the claim commits, so any value under that key is REPLACED with the one
  the claim produced. The `story` object is NOT the caller's either: a payload carrying one is
  refused `:story_not_accepted`, and loopctl builds it from its own rows after the claim (see
  `attach_story/6`). Everything else —
  `dispatch_id`, `kind`, the repo, the branches, the wall clock — is the caller's and is
  validated by the contract inside `Runners.dispatch/3`.

  Three refusals come from the builder rather than from the caller's payload:
  `{:story_not_dispatchable, violations}` means the story exceeds a contract cap and HAS BEEN
  ESCALATED to a human (the claim is released, the stage row stays `escalated`);
  `{:escalation_failed, reason, violations}` means it is neither dispatchable nor parked,
  which is the outcome nothing downstream will pick up; and
  `{:story_no_longer_dispatchable, violations}` is the RESUME's version — nothing was
  written, the claim stands and the session under it is untouched, because a retry does not
  own the claim it would be parking.

  The story must already be `contracted` (`Loopctl.Progress.contract_story/3`) and its stage
  row must be at `queued`. Both are checked BEFORE anything is minted, so the ordinary
  "not ready yet" answer costs no `dispatches` row, no ephemeral key and no audit-chain entry
  — see `claimable/2` for why that matters more than it looks.

  Returns `{:ok, %{dispatch_id:, claim_epoch:, implementer_dispatch_id:}}` — the last of which
  is the session dispatch this placement minted, or the one the original placement minted when
  this call was a retry that resumed from the ledger.

  ## Options

  - `:api_key` (required) — the `Loopctl.Auth.ApiKey` the request authenticated with. Its
    LINEAGE and its ROLE are resolved here, from the key, and are never taken as options: a
    caller-supplied lineage is exactly what `parent_outside_caller_lineage` exists to refuse,
    so accepting one would enforce that the mint parents on SOME named leaf rather than on the
    CALLER's. A key belonging to another tenant is `:not_authorized`.
  - `:actor_label` — recorded on the claim, the transition and the release.

  ## Refusals

  - `:tenant_halted` — the tenant's custody operations are halted (L6). Checked BEFORE the
    mint, because `CheckCustodyHalt` is a pipeline plug and this path has no `conn`, and
    because `Runners.dispatch/3`'s own halt check runs after both commits.
  - `:custody_tier_required` — an `agent_rooted` tenant. This path mints a custody dispatch
    and drives a chained custody transition, both of which the HTTP surface gates behind
    `LoopctlWeb.Plugs.RequireHumanAnchor`; a context reachable from a worker or an MCP tool
    has to apply the same gate itself (`Loopctl.Tenants.require_human_anchor/1`).
  - `:root_dispatch_forbidden` — an unlineaged caller below `:user` (see the moduledoc)
  - `:insufficient_role` — a LINEAGED caller below `:orchestrator`. Minting a dispatch is
    `RequireRole, role: :orchestrator` on the HTTP surface and `create_dispatch/3` has no role
    gate of its own, so this path applies it.
  - `:not_authorized` — a key from another tenant, or no such runner in this tenant, or its
    row, key or tenant is no longer valid
  - `:runner_not_provisioned` — a runner row with no `agent_id`, which the
    `add_agent_id_to_runners` migration makes unreachable and this refuses rather than
    claiming a story for nobody
  - `:runner_declines_work` — the machine's live socket declares `draining`, or a
    `max_sessions` of `0`. Refused BEFORE the claim: the runner would refuse the push itself,
    but only after the story had been claimed for it. **On the CLAIM path only.** A RESUME —
    a `dispatch_id` the ledger already holds — is pushed at a draining machine as before,
    because it claims nothing and the claim it re-pushes under is live: refusing it would
    strand that claim at `claimed` until its lease expired, which is what the gate exists to
    prevent
  - `{:no_conforming_branch, prefixes}` — the machine declared branch prefixes
    (`RunnerJoin.branch_prefixes`, contract 1.14.0) and none of them can produce a valid
    branch name carrying the story number and id fragment. Refused BEFORE the claim, like
    `:runner_declines_work`, because the runner would refuse the push itself and the claim
    would already be spent. The remedy is on the machine — an operator fixes its
    `branch_prefixes` and reconnects it — which is why it refuses the placement and not the
    join.
  - `{:branch_not_allowed, branch, prefixes}` — the CALLER supplied a `branch` the target
    machine's declaration does not accept. loopctl never rewrites a caller's branch, so the
    only honest answers are to refuse it here or to let the runner refuse it after the claim.
  - `:not_found`, `:invalid_transition`, `:wrong_stage` — from the pre-mint readiness check.
    A story that passes the check and is claimed by someone else in between instead gets
    `Loopctl.Progress.claim_story/3`'s own richer `{:invalid_transition, map()}`, and the
    session dispatch minted for it is REVOKED before returning.
  - everything `Loopctl.Dispatches.create_dispatch/3`, `Loopctl.Delivery.Stages.advance/4`
    and `Loopctl.Runners.dispatch/3` refuse, unchanged. Every refusal after the claim commits
    releases the claim before returning, and a release that FAILS parks the story at
    `escalated` instead (`escalate_unreleased_claim/6`) — the refusal the caller is handed is
    the same either way, because it is the push refusal that is owed, not the compensation's.
    Read the story's stage to tell the two apart.

  ## A dispatch_id is spent by the claim it was placed under

  "Safe to repeat" means a repeat under the SAME claim. Once that claim ends — the lease
  expires, an operator force-unclaims, a refused push releases it — the ledger row still
  carries the old epoch, so every later `place/4` with that `dispatch_id` resumes, pushes the
  recorded epoch and is refused `:stale_claim_epoch` for ever. That is the fence working: the
  row names a claim that no longer exists. **Re-placing the story needs a NEW `dispatch_id`.**
  """
  @spec place(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok,
           %{
             dispatch_id: Ecto.UUID.t(),
             claim_epoch: non_neg_integer(),
             implementer_dispatch_id: Ecto.UUID.t() | nil
           }}
          | {:error, error()}
  def place(tenant_id, runner_id, %{} = dispatch, opts)
      when is_binary(tenant_id) and is_binary(runner_id) do
    with :ok <- no_caller_story(dispatch),
         {:ok, dispatch_id} <- fetch_uuid(dispatch, "dispatch_id"),
         {:ok, story_id} <- fetch_uuid(dispatch, "story_id"),
         {:ok, caller} <- resolve_caller(tenant_id, Keyword.fetch!(opts, :api_key)),
         :ok <- not_halted(tenant_id),
         :ok <- Tenants.require_human_anchor(tenant_id),
         :ok <- may_mint_session_dispatch(caller.lineage, caller.role) do
      case DispatchLedger.get_record(tenant_id, dispatch_id) do
        nil -> claim_and_push(tenant_id, runner_id, dispatch, story_id, caller, opts)
        record -> resume(tenant_id, runner_id, dispatch, record)
      end
    end
  end

  # THE STORY OBJECT IS LOOPCTL'S TO BUILD, so a caller may not supply one. `attach_story/6`
  # builds it from Postgres; a caller-supplied one would be prose handed to a runner one level
  # along, which the contract's no-prompt rule exists to prevent — "a dispatch runs as the
  # machine's user and a control plane able to hand a runner prose to execute is able to run
  # anything on it".
  #
  # REFUSED rather than dropped, and refused HERE rather than only at the HTTP edge. The
  # endpoint's own guard (`LoopctlWeb.DispatchPlacementController`) still answers with the
  # better message, and this is what binds the callers that never touch it — a worker, an MCP
  # tool, the unattended driver. A silently dropped object would have the caller believe the
  # runner saw a story it never received.
  defp no_caller_story(dispatch) do
    if Map.has_key?(dispatch, "story"), do: {:error, :story_not_accepted}, else: :ok
  end

  # THE CALLER'S OWN LINEAGE AND ROLE, DERIVED FROM THE KEY IT AUTHENTICATED WITH — the same
  # resolution `LoopctlWeb.DispatchController.create/2` performs, and for the same reason: a
  # lineage handed in as an option is a CLAIM about who the caller is, and the ceiling it feeds
  # is precisely what `parent_outside_caller_lineage` exists to refuse. Taking it as an opt
  # enforced that the mint parents on SOME named leaf, which is not the property the moduledoc
  # says is enforced here.
  #
  # The repeated `tenant_id` in the head is the tenant check: a key belonging to another tenant
  # matches no clause and is `:not_authorized`. So is anything that is not an `ApiKey` at all —
  # a caller passing a bare id or a map gets a refusal rather than a lineage of `[]`, which
  # would have read as "an operator" to the clause below.
  defp resolve_caller(tenant_id, %ApiKey{tenant_id: tenant_id, id: id, role: role}) do
    {:ok, %{lineage: Dispatches.lineage_for_api_key(tenant_id, id), role: role}}
  end

  defp resolve_caller(_tenant_id, _api_key), do: {:error, :not_authorized}

  # A MACHINE THAT SAID IT TAKES NO WORK IS REFUSED BEFORE THE CLAIM (#846.4 review finding 3
  # and finding 8). The contract tells runner authors that a machine wanting no work declares
  # `draining` (or `max_sessions: 0`, which is the same statement), and until now that was
  # honoured only by the unattended SELECTORS — `Loopctl.Delivery.DispatchDriver` and
  # `TriageDispatcher` skip such a runner via `Runners.accepts?/5`. A placement naming the
  # runner outright reached neither, and `Runners.do_dispatch/3` checks halt, authorization,
  # single-live-socket and kind and never `draining`. So the contract's own advice was
  # unactionable on this path, which is the path that CLAIMS THE STORY BEFORE IT PUSHES: the
  # runner would refuse with `draining` after the claim committed, and the story would sit at
  # `claimed` with no session until its lease expired.
  #
  # Checked from `claim_and_push/6`, before the mint and the claim, for the same reason
  # `claimable/2` is: nothing is spent on an outcome that was never going to succeed, and
  # there is no compensation to get right. It reads the ONE live meta a push would reach; zero
  # sockets or an ambiguous pair are left to `Runners.dispatch/3`, which already answers
  # `:runner_not_connected` and `:runner_ambiguous` and is the single place that judgement is
  # made.
  #
  # ## WHICH PATH THIS COVERS, AND WHY THE OTHER TWO ARE EXEMPT (#846.4 review round 2,
  # finding 1)
  #
  # The whole argument above is about the path that CLAIMS BEFORE IT PUSHES, so it is mounted
  # inside `claim_and_push/6` and NOT in `place/4`'s own `with`. Two paths are deliberately
  # left ungated, for the same reason and not for two:
  #
  #   * `resume/4` — a retry of a `dispatch_id` the ledger already holds. It claims nothing;
  #     the claim it is re-pushing under COMMITTED on an earlier call and is live. Gated here,
  #     a retry against a machine that has since declared `draining` was refused
  #     `:runner_declines_work`, whose message says nothing was claimed and to place on
  #     another runner — BOTH false: the claim stands, and a spent `dispatch_id` cannot be
  #     re-placed anywhere. The story then sat at `claimed` with no session until its lease
  #     expired, which is the exact outcome this gate exists to prevent. And `draining` is
  #     mutable MID-CONNECTION (`RunnerStatus`), so the ordinary graceful drain — finish what
  #     you hold, take nothing new — put every in-flight dispatch of that machine one lost
  #     frame away from it. A resume is "what you hold", so it is work the machine already
  #     accepted and not new work.
  #   * `Runners.dispatch/3` — an operator push by name. It claims nothing either, so the
  #     runner's own refusal reaches a person, which is the trade `accepts?/5` documents.
  #
  # TAKES THE ALREADY-RESOLVED META rather than reading one (846.2 review finding 5). Its
  # caller reads the sole live meta ONCE and asks both questions of that one value, so the
  # draining judgement and the branch declaration cannot come from two different sockets: a
  # runner that rejoins between two reads would otherwise have the placement judge its
  # capacity from one declaration and derive its branch from another, which is exactly the
  # split `Runners.declared_branch_prefixes/1` leans on "the caller resolves the SOLE live
  # meta" to rule out.
  defp runner_accepting_work(nil), do: :ok

  defp runner_accepting_work(meta) do
    if Runners.accepting_work?(meta), do: :ok, else: {:error, :runner_declines_work}
  end

  # WHAT THIS MACHINE SAID IT ACCEPTS, off the meta of the ONE socket a push would reach
  # (contract 1.14.0, story 846.2). Nothing is stored, so this is the whole read — see
  # `Runners.declared_branch_prefixes/1` for why a branch prefix takes that form where
  # capacity could not.
  #
  # `[]` for zero sockets and for an ambiguous pair, which is the same answer
  # `runner_accepting_work/1` gives and for the same reason: with no single meta there is no
  # declaration to read, and `Runners.dispatch/3` is the one place that judges those two
  # states (`:runner_not_connected`, `:runner_ambiguous`). Deriving the un-prefixed default
  # there is not a guess that costs anything — the push is refused before it reaches a
  # machine.
  defp declared_branch_prefixes(nil), do: []
  defp declared_branch_prefixes(meta), do: Runners.declared_branch_prefixes(meta)

  defp sole_live_meta(tenant_id, runner_id) do
    case Runners.live_metas(tenant_id, runner_id) do
      [meta] -> meta
      _zero_or_ambiguous -> nil
    end
  end

  # THE L6 HALT, applied here for the same reason the tier gate is: `CheckCustodyHalt` is a
  # PIPELINE plug, and this path has no `conn`. Both endpoints that do what a placement does —
  # `POST /stories/:id/claim` and `POST /api/v1/dispatches` — are blocked by it during a halt,
  # and neither `Progress.claim_story/3` nor `Dispatches.create_dispatch/3` checks a halt
  # itself.
  #
  # `Runners.dispatch/3` checks one, but at step 2 of the PUSH — which in `place/4` runs after
  # the mint and after both commits. Without this a placement on a halted tenant would mint a
  # dispatch and a live ephemeral key, append `dispatch_created` and `story_stage_claimed` to
  # the IMMUTABLE chain under the tenant's chain lock, claim the story and then release it.
  # A halt is what L6 does when the system believes the tenant is being lied to, so custody
  # progress and two permanent chain entries are exactly what must not happen — and the
  # compensation is not a consolation either, because
  # `Loopctl.Workers.ReclaimExpiredClaimsWorker` skips halted tenants, so a claim left standing
  # by a failed release would never be reclaimed.
  #
  # Read FRESH, like the tier: `Runners.custody_halted?/1` re-reads the tenant rather than
  # trusting a struct loaded earlier, which is the whole point on a value that flips precisely
  # when something has gone wrong.
  defp not_halted(tenant_id) do
    if Runners.custody_halted?(tenant_id), do: {:error, :tenant_halted}, else: :ok
  end

  # A retry of a dispatch the ledger already holds. NOTHING IS CLAIMED, MINTED, BUMPED OR
  # WRITTEN: the placement already happened, and what is left is to put the frame on the wire
  # again under the epoch the ORIGINAL claim produced. Pushing under a freshly read epoch
  # instead would hand the runner a number its ledger row does not carry, and `record_sent/3`
  # would refuse it as a `:dispatch_id_conflict`.
  #
  # THE STORY OBJECT IS REBUILT HERE TOO, and leaving it out was the same defect this change
  # exists to fix, left open on the retry path. The caller's map can never carry a `story` —
  # `no_caller_story/1` refuses one — so a resume that pushed the caller's map verbatim pushed
  # an implement dispatch with no story, which the runner refuses outright while this function
  # answers `{:ok, ...}` as though work had been placed. And the retry is the ORDINARY path: a
  # lost HTTP response, a failed broadcast or a dropped frame all leave the ledger row at
  # `sent`, which is exactly what routes a re-send here.
  #
  # BUILT WITH THE PURE BUILDER, NOT `StoryPayload.build/3`, and that is the whole difference
  # between this path and the claim path. `build/3` ESCALATES an undispatchable story — a
  # stage transition and a chain entry — which is right where the caller owns the claim it is
  # parking, and wrong here for three reasons this path cannot escape:
  #
  #   * the ledger's fences (`:dispatch_already_replied`, `:stale_claim_epoch`) live inside
  #     `record_sent/3`, which a resume does not reach until the PUSH — so a duplicate retry of
  #     an ALREADY-ANSWERED dispatch, or one whose claim has since been released and the story
  #     re-placed, would have written an escalation over a story that is live under somebody
  #     else's claim, and answered 422 or 500 where the pre-change code answered a fence;
  #   * the escalation would be attributed to a dispatch this call did not mint and does not
  #     own, or refused for want of a lineage it has no business resolving;
  #   * a resume that escalated but did not release would leave the story `escalated` AND
  #     claimed, with a live key and a ticking lease, while the refusal told the operator the
  #     claim had gone back.
  #
  # So a story that no longer fits the contract is REFUSED here and nothing is written. The
  # claim stands, the session under it is untouched, and the next placement through the claim
  # path is what parks the story — with the fences applied first, where they belong.
  defp resume(tenant_id, runner_id, dispatch, record) do
    with {:ok, payload} <- resume_payload(tenant_id, runner_id, dispatch, record) do
      push_resumed(tenant_id, runner_id, payload, record)
    end
  end

  # THE BRANCH IS THE ONE THE FIRST PUSH NAMED, read back off the ledger row, and a retry can
  # therefore never land on a second name (846.2 review round 2, finding 4).
  #
  # This function re-DERIVED it until that round, on the argument that a resume only runs
  # against a row still at `sent` — `record_sent/3` fences a row that has been answered — so
  # "the first frame was never ACCEPTED, no session started, and no branch exists on that
  # machine to disagree with". That overstates what `sent` means. It means no reply was
  # RECORDED, and a LOST REPLY is precisely the case a resume exists for: the machine may have
  # accepted the dispatch and be running a session on the first branch right now. Re-deriving
  # after a rejoin that changed `branch_prefixes` would then push a SECOND name under the same
  # `dispatch_id`, against a session already working on the first — and before contract 1.14.0
  # that could not happen at all, because the name was a pure function of the story.
  #
  # So `runner_dispatches.branch` records it on the first insert and `on_conflict: :nothing`
  # keeps it, and `pin_recorded_branch/2` is what puts it back into the payload. A row written
  # before that column existed carries NULL and falls through to the derivation, which is the
  # pre-round-2 behaviour for exactly the rows that cannot do better.
  #
  # What the derivation still decides, for those rows and for them only: it is a pure function
  # of the story and the declaration (`DispatchPayload.branch_for/2` takes the FIRST usable
  # prefix, never a random or a "best" one), so an unchanged declaration re-derives the same
  # string byte for byte.
  #
  # ## THE DECLARATION STEERS THE NAME AND CANNOT REFUSE THE RESUME (846.2 review finding 1)
  #
  # `:prefix_policy` is `:advise` here for the ONE reason `runner_accepting_work/1` is not
  # mounted on this path at all: the claim this call is re-pushing under COMMITTED on an
  # earlier call and is LIVE. A refusal for a machine-state reason leaves the story at
  # `claimed` with no session until its lease expires, which is the exact outcome that gate
  # exists to prevent, and the `dispatch_id` is spent, so a new placement cannot be made while
  # the claim stands.
  #
  # It is not hypothetical, and the scenario is the DOCUMENTED remediation path. A runner
  # declares `["loop/"]`; an operator places naming `branch: "loop/mine"` — the field the
  # pre-1.14.0 schema REQUIRED, so every client built before this change sends one; the HTTP
  # response is lost; the operator fixes the machine's configuration and it rejoins declaring
  # `["agent/"]`, which is what the contract tells them to do. Under `:refuse` the retry
  # carrying the same `dispatch_id` is answered `branch_not_allowed`, whose message says
  # nothing was claimed — false here, the same both-halves-false message
  # `runner_declines_work` carried on this path until #866 round 2 moved it. So this is the
  # same fix in the same place: the gate belongs on the CLAIMING path, and this one is exempt.
  #
  # What `:advise` still gets right is the NAME. The declaration is used wherever it can
  # produce a conforming branch, so the ordinary rejoin above resumes on `agent/...`, and only
  # a declaration that can produce no valid name at all falls back to the un-prefixed default.
  # The machine may then refuse that frame, which is the outcome this path is built for
  # everywhere else too — `push_resumed/4` writes no compensating release — so the refusal
  # reaches a person while the claim and any session under it stay exactly as they were.
  #
  # THE NAME CHECK IS NOT EXEMPT, and it is a different question rather than the same one
  # twice. A prefix is a fact about ANOTHER MACHINE that changed under the caller: its remedy
  # is a config file on that box, and until someone acts there the claim is stranded. A branch
  # NAME is a fact about the string in THIS REQUEST: its remedy is this request, retryable
  # immediately under the same `dispatch_id`, because a refusal here writes nothing at all.
  # And a name git will not take cannot start a session on any machine, so pushing it is not
  # the kinder outcome — it costs the same claim one round trip later.
  defp resume_payload(tenant_id, runner_id, dispatch, record) do
    prefixes = declared_branch_prefixes(sole_live_meta(tenant_id, runner_id))

    with {:ok, story} <- Stories.get_story(tenant_id, record.story_id),
         # BEFORE the pin, so a MALFORMED name is answered as malformed rather than as a
         # conflict. `-o` is both a different name and not a ref name at all, and the useful
         # message is the second: the remedy for a conflict is "send the recorded one", which
         # is not what a caller who sent `-o` needs to hear. `fill/3` re-runs this over the
         # finished payload; running it twice costs a string comparison.
         :ok <- DispatchPayload.validate_refs(dispatch, story),
         {:ok, dispatch} <- pin_recorded_branch(dispatch, record),
         {:ok, dispatch} <-
           DispatchPayload.fill(tenant_id, dispatch,
             branch_prefixes: prefixes,
             prefix_policy: :advise
           ),
         {:ok, dispatch} <- rebuild_story(dispatch, story) do
      {:ok, Map.put(dispatch, "claim_epoch", record.claim_epoch)}
    end
  end

  # THE LEDGER'S BRANCH WINS, AND A CALLER NAMING A DIFFERENT ONE IS REFUSED RATHER THAN
  # OVERWRITTEN. Silently substituting would be the rewrite `DispatchPayload` forbids on every
  # other path — the session would run on a name nobody in this request chose — and accepting
  # the caller's would put the second name on the wire that finding 4 is about. So the two
  # disagreeing is a 422 whose remedy is in the request: drop `branch`, or send the one this
  # dispatch already has.
  #
  # A non-binary is NOT treated as a conflict. It is a malformed value rather than a different
  # name, and `DispatchPayload.validate_refs/2` refuses it with the same `invalid_branch_name`
  # a first placement would — one answer for one mistake, on both paths.
  defp pin_recorded_branch(dispatch, %{branch: recorded}) when is_binary(recorded) do
    case Map.fetch(dispatch, "branch") do
      :error -> {:ok, Map.put(dispatch, "branch", recorded)}
      {:ok, ^recorded} -> {:ok, dispatch}
      {:ok, other} when is_binary(other) -> {:error, {:branch_conflict, other, recorded}}
      {:ok, _not_a_string} -> {:ok, dispatch}
    end
  end

  # A ledger row written before `runner_dispatches.branch` existed. Nothing to pin.
  defp pin_recorded_branch(dispatch, _record), do: {:ok, dispatch}

  # `ImplementerInput.story_object/2` is the pure half of `StoryPayload.build/3` — the same
  # allowlist and the same caps, with no database write of any kind. Non-implement kinds carry
  # no story object at all, exactly as on the claim path.
  defp rebuild_story(dispatch, story) do
    if Map.get(dispatch, "kind") == "implement" do
      case ImplementerInput.story_object(story) do
        {:ok, object} ->
          {:ok, Map.put(dispatch, "story", object)}

        {:error, {:story_not_dispatchable, violations}} ->
          {:error, {:story_no_longer_dispatchable, violations}}
      end
    else
      {:ok, dispatch}
    end
  end

  defp push_resumed(tenant_id, runner_id, payload, record) do
    case Runners.dispatch(tenant_id, runner_id, payload) do
      :ok ->
        {:ok,
         %{
           dispatch_id: record.dispatch_id,
           claim_epoch: record.claim_epoch,
           implementer_dispatch_id: implementer_dispatch_id(tenant_id, record.story_id)
         }}

      {:error, _reason} = error ->
        # NO compensating release. This call claimed nothing, and the claim that is standing
        # belongs to a placement that already committed — releasing it here would end a
        # session that may well be running.
        error
    end
  end

  # FILLED AFTER THE RUNNER IS RESOLVED AND BEFORE ANYTHING IS MINTED, which is the only
  # position that is right on both counts.
  #
  # After, because filling READS THE STORY: done any earlier, a caller aiming at another
  # tenant's runner was answered `story_not_found` before it had been told it was not
  # authorised — the wrong answer, and an existence oracle for ids it may not see.
  #
  # Before, because `RunnerDispatch` requires `repo`, `branch`, `base_branch` and both
  # budgets, `cast_dispatch/1` applies no defaults, and that cast is the FIRST step of
  # `Runners.dispatch/3` — which runs after a session dispatch has been minted, the story
  # claimed, and two IMMUTABLE chain entries appended. A caller that omitted one of the five
  # paid all of that and then got a 422. Every one of them is something loopctl can look up.
  #
  # ONE READ OF THE POOL serves both questions this asks about the machine — is it taking work,
  # and what branch prefixes did it declare. See `runner_accepting_work/1` for why the pair
  # must come from the SAME meta.
  defp claim_and_push(tenant_id, runner_id, dispatch, story_id, caller, opts) do
    meta = sole_live_meta(tenant_id, runner_id)

    with :ok <- runner_accepting_work(meta),
         {:ok, agent_id} <- runner_agent_id(tenant_id, runner_id),
         {:ok, dispatch} <-
           DispatchPayload.fill(tenant_id, dispatch,
             branch_prefixes: declared_branch_prefixes(meta)
           ),
         :ok <- claimable(tenant_id, story_id),
         {:ok, session} <- mint_session_dispatch(tenant_id, agent_id, story_id, caller, opts) do
      claim_then_push(tenant_id, runner_id, dispatch, story_id, agent_id, session, opts)
    end
  end

  # WHETHER THE CLAIM IS EVEN WORTH MINTING FOR, read before anything is minted. Not an
  # optimisation, and not the fence either — the claim's own transaction is both.
  #
  # Minting is not free and it is not undoable. Every mint writes a `dispatches` row, an
  # `api_keys` row, and an IMMUTABLE, STH-covered `dispatch_created` entry appended under the
  # tenant's chain advisory lock — the row every writer in the tenant contends on. Nothing
  # deletes a chain entry, by design. So a caller looping over a story that is not ready (still
  # `pending`, already claimed, its stage row not at `queued`) would have written a permanent
  # chain entry and taken the chain lock once per attempt, for an outcome that was never going
  # to succeed. Reading two rows first turns that into two SELECTs.
  #
  # It cannot be complete, and is not meant to be: a story claimed between this read and the
  # claim's own lock takes `claim_story/3`'s refusal instead, and `claim_then_push/7` revokes
  # the dispatch minted for it. This bounds the COMMON case; that bounds the race.
  @doc """
  Whether a story is in a state a placement can take: `contracted`, with its stage row at
  `queued`.

  Public so the question can be ASKED — by a test proving that a story an operator re-queued
  is actually placeable, and by anything that wants to know before it spends a mint. It is the
  same read `place/4` makes, so an answer here and the placement's own decision cannot drift
  apart; see the note below on why it is a pre-check and not the fence.
  """
  @spec claimable(Ecto.UUID.t(), Ecto.UUID.t()) ::
          :ok | {:error, :invalid_transition | :wrong_stage | :not_found}
  def claimable(tenant_id, story_id) do
    with {:ok, story} <- Stories.get_story(tenant_id, story_id) do
      cond do
        story.agent_status != :contracted -> {:error, :invalid_transition}
        stage_of(tenant_id, story_id) != :queued -> {:error, :wrong_stage}
        true -> :ok
      end
    end
  end

  defp stage_of(tenant_id, story_id) do
    case Stages.get(tenant_id, story_id) do
      nil -> nil
      row -> row.stage
    end
  end

  # The race `claimable/2` cannot close. A claim that fails here leaves a minted dispatch that
  # will never be an implementer, so it is REVOKED rather than left to expire: its ephemeral key
  # would otherwise be live for the whole `@session_expires_in_seconds` TTL, holding the agent's
  # one-key-per-role slot and refusing every later placement onto it (see
  # `revoke_session_dispatch/3`). Two things DO eventually revoke it — this claim never reached
  # the story, so `force_unclaim_story/3` has no `implementer_dispatch_id` to find, leaving
  # `Loopctl.Workers.RevokeExpiredDispatchesWorker` at the TTL as the only backstop — and a TTL
  # is far too late for a loop that dispatches continuously. The chain entry it already wrote
  # stays — entries are immutable — which is why the pre-check above is the part that bounds a
  # loop.
  defp claim_then_push(tenant_id, runner_id, dispatch, story_id, agent_id, session, opts) do
    case claim(tenant_id, story_id, agent_id, session, opts) do
      {:ok, story} ->
        enter_claimed_and_push(tenant_id, runner_id, dispatch, story, session, opts)

      {:error, reason} ->
        revoke_session_dispatch(tenant_id, session, reason)
        {:error, reason}
    end
  end

  # The actor on every `dispatch_revoked` chain entry this module causes: the principal that
  # asked for the PLACEMENT. It is already in hand — `mint_session_dispatch/5` parented this
  # session on the caller's own leaf, so the caller's lineage is this one without its last
  # element. No extra read on the 3-connection pool for a compensation that runs on every
  # refusal.
  #
  # BOTH revoking paths have to use it, and only one of them did (#862 review round 2,
  # finding 3). `undo_claim/5` runs `release_claim/5` FIRST, and since #862
  # `force_unclaim_story/3` revokes the story's session dispatch itself — so the revoke that
  # actually happens on that path is the one inside the release, not the explicit one below,
  # and the explicit one then finds nothing to revoke and appends nothing. Computing the
  # lineage only here therefore wrote `actor_lineage: []` on the entry that reached the
  # chain, which reads as "the tenant's operator key did this" — a misattribution of an
  # agent's compensation, which is worse than no entry.
  defp caller_lineage(session), do: Enum.drop(session.lineage_path, -1)

  # Returns `:ok` or the failure, so the undo can report it rather than swallow it. The failure
  # is worth naming on its own, and the message has to name the CONSEQUENCE rather than the
  # timestamp — see below.
  #
  # **AND IT SWALLOWS A RAISE, not only an `{:error, _}`** — the hole `release_claim/5` already
  # closed for the same reason, and closing it here is what makes a failed revoke a VALUE this
  # function's caller can act on rather than an exception that escapes `place/4`. `Dispatches.revoke/3` returns tuples from its own Multi, but the
  # statements under it are ordinary `AdminRepo` calls on a 3-connection pool with no
  # `lock_timeout`, so a DBConnection error — or a constraint — is a RAISE. Unrescued it
  # replaced the push refusal the caller is owed with an unrelated one AND skipped the two
  # steps after it, so `log_undo/5` said nothing and `park_unreleased_claim/6` never ran:
  # a failed release went un-escalated, which is the whole of 846.1 undone by a raise in
  # the step before it.
  defp revoke_session_dispatch(tenant_id, session, reason) do
    case Dispatches.revoke(tenant_id, session.id, actor_lineage: caller_lineage(session)) do
      {:ok, _count} ->
        :ok

      other ->
        # This message used to end "the key stays live until it expires", which was true and
        # useless: it reads as a thing that resolves itself, so an operator who hit it waited
        # out a TTL instead of acting. What it left out is the only part that matters. The
        # ephemeral key is `revoked_at IS NULL`, so it OCCUPIES the runner agent's slot in
        # `api_keys_one_role_per_agent_idx` (`(tenant_id, agent_id, role)` WHERE
        # `revoked_at IS NULL`) for the whole `@session_expires_in_seconds` TTL — and the index
        # cannot test expiry, since a partial-index predicate must be IMMUTABLE and `now()` is
        # STABLE. So EVERY later placement onto that agent is refused 422 `agent already has an
        # active key with this role` until the TTL passes, which is the delivery loop stopping
        # dead rather than one leaked credential.
        #
        # Both remedies are named because they are reached from different places: the operator
        # holding the dispatch id revokes it directly, and the one holding only the story id
        # force-unclaims (`Progress.force_unclaim_story/3` revokes this story's session
        # dispatch on its way past).
        log_revoke_failure(tenant_id, session, reason, other)
    end
  rescue
    error -> log_revoke_failure(tenant_id, session, reason, {:error, error})
  end

  defp log_revoke_failure(tenant_id, session, reason, outcome) do
    Logger.error(
      "placement could not revoke the session dispatch its claim never used. The key stays " <>
        "usable for its full TTL and OCCUPIES the agent's one-key-per-role slot until " <>
        "then, so every later placement onto this agent is refused 422 'agent already has " <>
        "an active key with this role'. Revoke it: POST " <>
        "/api/v1/dispatches/#{session.id}/revoke (MCP revoke_dispatch), or force-unclaim " <>
        "the story — which works BECAUSE this branch leaves the story naming this dispatch " <>
        "(see `undo_claim/5`). EITHER REMEDY LEAVES THE STORY NAMING THIS DISPATCH: neither " <>
        "clears implementer_dispatch_id, deliberately, so until the story is claimed again " <>
        "through a dispatch its next claimant is refused on report if it holds a key no " <>
        "dispatch minted (caller_lineage_required) or one sharing this dispatch's chain " <>
        "(self_report_blocked). A re-claim by place/4 overwrites the column and clears it. " <>
        "tenant_id=#{tenant_id} dispatch_id=#{session.id} " <>
        "agent_id=#{inspect(session.agent_id)} claim_error=#{inspect(reason)} " <>
        "revoke_error=#{inspect(outcome)}",
      tenant_id: tenant_id
    )

    outcome
  end

  # Everything from here on has a COMMITTED claim behind it, so every refusal releases it.
  defp enter_claimed_and_push(tenant_id, runner_id, dispatch, story, session, opts) do
    epoch = story.claim_epoch

    advance =
      Stages.advance(tenant_id, story.id, {:queued, :claimed},
        claim_epoch: epoch,
        effects: [runner_id: runner_id],
        actor_lineage: session.lineage_path,
        actor_role: session.role,
        actor_label: Keyword.get(opts, :actor_label)
      )

    with {:ok, _row} <- advance,
         {:ok, dispatch} <- attach_story(tenant_id, dispatch, story, session, epoch, opts),
         :ok <- Runners.dispatch(tenant_id, runner_id, Map.put(dispatch, "claim_epoch", epoch)) do
      {:ok,
       %{
         dispatch_id: Map.fetch!(dispatch, "dispatch_id"),
         claim_epoch: epoch,
         implementer_dispatch_id: session.id
       }}
    else
      {:error, reason} ->
        # BOTH, and the dispatch revoke is not optional here either. The claim goes back, and
        # the session dispatch it recorded is revoked and UNRECORDED — see
        # `undo_claim/5` for why leaving the id behind is worse than leaving it unrevoked.
        #
        # THE WHOLE STORY, not its id: `undo_claim/5` needs `claim_epoch` to fence the
        # escalation it falls back on, and re-reading the epoch there would be the wrong
        # value as well as an extra read — see `escalate_unreleased_claim/6`.
        undo_claim(tenant_id, story, session, reason, opts)
        {:error, reason}
    end
  end

  # THE STORY OBJECT, BUILT HERE, WHICH IS THE ONLY PLACE IT CAN BE BUILT.
  #
  # An `implement` dispatch carries the story as TYPED FIELDS and never a prompt — the runner
  # composes its own from them — so a dispatch with no `story` names a `story_id` and carries
  # no work at all. The runner implementation refuses it outright ("the dispatch carries no
  # story"), before composing anything, and does so identically on every redispatch: a clean,
  # permanent, invisible no. Both callers of `place/4` sent exactly that until now — the
  # operator endpoint refuses a CALLER-supplied object (rightly: a caller able to hand a
  # runner prose is able to run anything on that machine) and nothing built a server-side one.
  #
  # AFTER THE CLAIM, not before, and that is forced rather than chosen. A story loopctl
  # cannot describe within the contract's caps is ESCALATED rather than truncated, and
  # `:session_escalated` leaves the in-flight stages only — at `queued` there is no edge, so
  # the same refusal before the claim could not park the story and would leave it to be
  # refused identically by every later pass.
  #
  # A refusal here therefore reaches the `else` below, and `undo_claim/5` does the right thing
  # with an escalated row rather than fighting it: `Stages.follow_release/5` REQUEUES only an
  # in-flight row and REBINDS anything else, so an escalated row keeps its stage and takes the
  # new epoch. The claim goes back, the session dispatch is revoked, and the story stays where
  # `StoryPayload.build/3` put it — with a human.
  defp attach_story(tenant_id, dispatch, story, session, epoch, opts) do
    if Map.get(dispatch, "kind") == "implement" do
      case StoryPayload.build(tenant_id, story.id,
             claim_epoch: epoch,
             actor_lineage: session.lineage_path,
             actor_label: Keyword.get(opts, :actor_label, "control:dispatch")
           ) do
        {:ok, object} -> {:ok, Map.put(dispatch, "story", object)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, dispatch}
    end
  end

  # The claim carries the session dispatch on it: `:dispatch_id` becomes the story's
  # `implementer_dispatch_id` and `:lineage` is what the `start_cap` is minted for, both
  # inside the claim's own transaction.
  defp claim(tenant_id, story_id, agent_id, session, opts) do
    Progress.claim_story(tenant_id, story_id,
      agent_id: agent_id,
      dispatch_id: session.id,
      lineage: session.lineage_path,
      actor_label: Keyword.get(opts, :actor_label)
    )
  end

  # Parented on the caller's own leaf, so the session dispatch can only land inside the
  # caller's subtree — the lineage ceiling, applied by this path rather than inherited from a
  # controller it does not go through. `nil` is a ROOT and has already been gated by
  # `may_mint_session_dispatch/2`.
  defp mint_session_dispatch(tenant_id, agent_id, story_id, caller, opts) do
    caller_lineage = caller.lineage

    attrs = %{
      parent_dispatch_id: List.last(caller_lineage),
      role: :agent,
      agent_id: agent_id,
      story_id: story_id,
      expires_in_seconds:
        Keyword.get(opts, :session_expires_in_seconds, @session_expires_in_seconds)
    }

    case Dispatches.create_dispatch(tenant_id, attrs, actor_lineage: caller_lineage) do
      {:ok, %{dispatch: dispatch}} -> {:ok, dispatch}
      {:error, reason} -> {:error, reason}
    end
  end

  # The operator test, positive and role-based — an empty lineage is ALSO what a legacy
  # env-var key and a key whose dispatch no longer resolves look like, so it cannot on its own
  # earn the right to start a tree. Identical to `LoopctlWeb.DispatchController`'s `operator?`.
  # TOTAL over what can actually reach it, and deliberately NOT given a catch-all beyond that.
  #
  # Both arguments come from `resolve_caller/2`: the lineage from
  # `Dispatches.lineage_for_api_key/2`, which returns a list or `[]`, and the role from
  # `ApiKey.role`, an `Ecto.Enum` that is never a string and never nil on a key the auth
  # pipeline resolved. A string role out of request params — the input that would otherwise
  # make `Role.role_at_least?/2` raise — cannot arrive here at all now that the role is derived
  # from the key rather than accepted as an option.
  #
  # A defensive clause for those was written and REMOVED: `bin/mutate.sh` opened it to `:ok`
  # and every test still passed (exit 1), which is the tool saying nothing can reach it. An
  # unreachable clause that reads as a guard is worse than no clause — and if `resolve_caller/2`
  # ever hands this something else, that is a broken invariant inside this module and a crash
  # is the right answer, not a `:root_dispatch_forbidden` that hides it.
  defp may_mint_session_dispatch([], role) do
    if Role.role_at_least?(role, :user), do: :ok, else: {:error, :root_dispatch_forbidden}
  end

  # THE ROLE CEILING, which the empty-lineage clause above only happened to cover. Minting a
  # dispatch is `RequireRole, role: :orchestrator` on `DispatchController.:create`, and
  # `create_dispatch/3` has no caller-role gate of its own — the plug IS the gate there. So a
  # lineaged AGENT-role key, which the HTTP surface 403s, minted a child custody dispatch and a
  # live ephemeral key through this path until this clause tested the role too. `:user` clears
  # `:orchestrator` by hierarchy, so the clause above is strictly stronger and the two agree.
  defp may_mint_session_dispatch([_ | _], role) do
    if Role.role_at_least?(role, :orchestrator), do: :ok, else: {:error, :insufficient_role}
  end

  # The runner's agent, read through the tenant-scoped registry so another tenant's runner id
  # resolves to nothing. `nil` is not "claim for nobody": a story whose `implementer_dispatch_id`
  # is set and whose `assigned_agent_id` is not cannot even reach `reported_done`
  # (`stories_reported_done_requires_agent`).
  defp runner_agent_id(tenant_id, runner_id) do
    case Runners.get_runner(tenant_id, runner_id) do
      {:ok, %{agent_id: nil}} -> {:error, :runner_not_provisioned}
      {:ok, %{agent_id: agent_id}} -> {:ok, agent_id}
      {:error, :not_found} -> {:error, :not_authorized}
    end
  end

  # THE WHOLE UNDO: release the claim, UNRECORD the session dispatch, revoke it.
  #
  # Since #862 the release does the FIRST AND THE THIRD: `Progress.force_unclaim_story/3`
  # revokes the story's own session dispatch (`revoke_released_session_credential/3`) on its
  # way past, so on this path `revoke_session_dispatch/3` below normally finds the dispatch
  # already revoked, revokes nothing and appends nothing. It stays because it is the only
  # revoke on the OTHER caller, `claim_then_push/7`, where the claim never reached the story
  # and there is no `implementer_dispatch_id` for the release to find — and because a release
  # that failed leaves the credential live, which is exactly when a second attempt is wanted.
  #
  # That ordering is why `release_claim/5` is handed the caller's lineage: the entry the chain
  # actually gets on this path is written by the release, not by the explicit revoke.
  #
  # `Progress.release_claim_changes/1` clears `assigned_agent_id` and does NOT clear
  # `implementer_dispatch_id` — correctly, for its own callers: a reclaimed or unclaimed story
  # keeps the provenance of who was working on it. Here nobody was, and a story left naming a
  # dispatch that did nothing refuses its NEXT claimant — `caller_lineage_required` for an
  # unlineaged one, `self_report_blocked` for one whose lineage shares a chain with the stale
  # dispatch. Revoking changes neither of those; see
  # `Progress.clear_unused_implementer_dispatch/3` for why the opposite claim, which this
  # comment used to make, was false.
  #
  # ## What the ORDER is, and why REVOKE NOW COMES BEFORE CLEAR (846.8, AC-1)
  #
  # RELEASE FIRST IS REQUIRED. Everything downstream describes a story nobody is working on,
  # and the release is what makes that true.
  #
  # REVOKE BEFORE CLEAR IS REQUIRED TOO, and the clear is CONDITIONAL on the revoke having
  # succeeded (`clear_if_revoked/4`). This comment used to say the two were independent
  # because "a story naming a revoked dispatch and one naming a live dispatch are refused
  # identically" — true about the L4 gates, and irrelevant to the thing that actually
  # depends on the order. What depends on it is the REMEDY.
  #
  # `Progress.force_unclaim_story/3` is the remediation path for a credential this undo
  # could not revoke, and it finds that credential through the story's
  # `implementer_dispatch_id` (`revoke_released_session_credential/3` ->
  # `Dispatches.revoke_story_session/4`). Clearing that column first and then failing to
  # revoke therefore erases the only handle the remedy has: the operator holds a story id,
  # the story names nothing, and nothing short of a direct dispatch id — which the log line
  # in `revoke_session_dispatch/3` is then the sole record of — gets the agent's
  # one-key-per-role slot back before the TTL. That is not hypothetical; it parked story
  # d9975b31 for four hours on 2026-09-15. The two remediation paths could not cover each
  # other in the one case where covering matters.
  #
  # So: revoke, and clear ONLY if it worked. When it did not, the stale id is KEPT on
  # purpose, and that trade is one-sided. Keeping it costs the story's next claimant a
  # refusal, and only if that claimant is UNLINEAGED (`caller_lineage_required`) or shares a
  # chain with the dead dispatch (`self_report_blocked`) — a re-claim THROUGH A DISPATCH,
  # which is what `place/4` itself does, overwrites the column and is unaffected. Dropping
  # it costs every later placement onto that agent a 422 for the whole TTL with no remedy
  # reachable from the story at all.
  #
  # ### THE REMEDY DOES NOT CLEAR THE ID, and this comment used to read as if it did
  #
  # `Progress.force_unclaim_story/3` revokes the credential and frees the slot. It does NOT
  # clear `implementer_dispatch_id` — `revoke_released_session_credential/3` says so at its
  # own definition — so after the documented remedy the story still names a dispatch that
  # never ran, and the refusals two paragraphs up (`caller_lineage_required`,
  # `self_report_blocked`) still apply to its next claimant. The residue is smaller than the
  # one the remedy clears, and it is not nothing.
  #
  # It is deliberately left, and clearing it inside `force_unclaim_story/3` is NOT the fix.
  # That function is the operator's release for ANY claimed story, not only for this
  # compensation's residue, and from inside it the two are indistinguishable: a story that
  # was genuinely implemented under a dispatch reaches it in the same shape. Clearing there
  # would drop real provenance and turn a dispatch-minted story into a pre-dispatch-shaped
  # one, where the L4 gates fall back to `assigned_agent_id` equality alone — so a key in the
  # implementer's own chain, on a different agent, could report work its own session did. An
  # orchestrator key is all it takes to arrange, and orchestrator is exactly the role
  # force-unclaim is gated to. That is the collapse the product exists to prevent; the stale
  # pointer is the cheaper of the two.
  #
  # What actually clears it is the next claim THROUGH A DISPATCH, which `place/4` makes on
  # its own the next time the loop picks the story up — so the residue is self-healing on the
  # delivery loop's own path, and durable only for a re-claim with a legacy bearer key.
  #
  # Each step reports, and `log_undo/5` says so when any of them did not do what it was for.
  # Nothing here rolls anything back on failure: the caller is owed the refusal that brought it
  # here, not a second one.
  #
  # ## A FAILED RELEASE IS ESCALATED, because a log line is not a remedy
  #
  # `log_undo/5` was the whole of the answer to a failed step, and on 2026-09-15 that cost four
  # hours: the release ran, failed, wrote its `Logger.error`, and the story sat at `claimed`
  # until somebody read the log. This loop's entire premise is running unattended, so the
  # residue of a failed compensation has to reach a human through the mechanism built for
  # reaching one rather than through a box nobody is tailing.
  #
  # ONLY THE RELEASE, and the stage machine is what decides that rather than a judgement call:
  #
  #   * `release` failed — the `force_unclaim_story/3` Multi rolled back, so the story is still
  #     `assigned` at an in-flight stage with no session that will ever run under it, and NO
  #     AUTOMATIC PATH RECOVERS IT INSIDE THE LEASE. A later `place/4` is refused
  #     `:invalid_transition` by `claimable/2` (the story is `assigned`, not `contracted`), and
  #     the only edges the machine offers out of `claimed` back to a PLACEABLE `queued` are
  #     `:claim_released` — written by `Progress.force_unclaim_story/3`, i.e. the release that
  #     just failed, and the operator remedy that repeats it — and `:runner_lost`, which is
  #     `ReclaimExpiredClaimsWorker`'s, hours away and skipping a halted tenant entirely. That
  #     is the incident, and it is the one thing here a human has to decide about.
  #
  #     `claimed` IS NOT A DEAD END in the machine, and this used to say it was ("no edge out
  #     of `claimed` that control can drive"). `attempt_park/7`, a hundred-odd lines below,
  #     drives `{:claimed, :escalated, :session_escalated}` from control and is the whole of
  #     this feature; `:budget_exceeded` leaves `claimed` as well. Neither returns the story to
  #     placeable, which is the property that makes this state an incident.
  #   * `cleared` — `Progress.clear_unused_implementer_dispatch/3` returns `{:ok, :cleared}` or
  #     `{:ok, :unchanged}` and CANNOT return an error; `{:ok, :unchanged}` is explicitly not a
  #     failure (see `log_undo/5`), so escalating on it would fire on the healthy path. Its only
  #     failure mode is a raise, which does not reach this decision at all.
  #   * `revoked` failed — the RELEASE SUCCEEDED, so this story is not what is stranded; a
  #     CREDENTIAL is, occupying the runner agent's one-key-per-role slot, which is an
  #     agent-level fault and not this story's. WHERE the story ends up depends on which step
  #     refused, and this bullet used to name only the first of the two: on the ordinary path
  #     the row was in flight, so `Stages.follow_release/5` REQUEUES it and it is back at
  #     `queued` and placeable, but on the `attach_story/6` path `StoryPayload.build/3` has
  #     ALREADY parked the story it could not describe, and `escalated` is not in
  #     `StageMachine.in_flight_stages/0` — so the release REBINDS that row and the stage stays
  #     `escalated`, a story already in front of a human. That second half is not an argument:
  #     `placement_test.exs`'s "a story too large for the contract is ESCALATED, and the claim
  #     goes back" drives it through a real `place/4`. Escalating either is impossible
  #     rather than merely wrong: `:session_escalated` leaves `@in_flight ++ [:merged,
  #     :deployed]`, and neither `queued` nor `escalated` is in those, so there is no edge to
  #     take. `revoke_session_dispatch/3`'s error log already names both remedies for the
  #     credential.
  #
  # So the machine and the defect agree: the story is escalatable exactly when it is still held,
  # and it is still held exactly when the release failed.
  defp undo_claim(tenant_id, story, session, reason, opts) do
    release = release_claim(tenant_id, story.id, reason, caller_lineage(session), opts)
    revoked = revoke_session_dispatch(tenant_id, session, reason)
    cleared = safe_clear(tenant_id, story.id, session, revoked)
    log_undo(tenant_id, story.id, session, reason, {release, cleared, revoked})
    park_unreleased_claim(tenant_id, story, session, reason, release, opts)
  end

  # TWO TOTAL CLAUSES over what `revoke_session_dispatch/3` returns: `:ok` is the only success
  # and `{:error, _}` the only failure — that function returns the `:ok` it maps
  # `{:ok, count}` to, or the `{:error, term}` half of `Dispatches.revoke/3`'s own spec, which
  # `log_revoke_failure/4` passes through unchanged. A miss is caught by `safe_clear/4` above
  # rather than by a clause here; read that comment for why the two halves are split.
  #
  # The second head matches `{:error, _}` EXPLICITLY and not `_`. It read as a catch-all until
  # 846.8 while the comment claimed it was total, which is this branch's own subject one file
  # over — and the consequence was the opposite of what that comment stated: a new SUCCESS
  # shape (`{:ok, :already_revoked}`, say) would have been absorbed as "revoke failed", so the
  # story would have gone on naming a dispatch that WAS revoked, on the healthy path, silently.
  # That shape now reaches `safe_clear/4`'s rescue instead, where it is reported rather than
  # absorbed: `log_undo/5` prints the `FunctionClauseError` under `clear=`, which names the
  # function AND the unmatched argument.
  #
  # `:kept_for_remediation` is not a failure and is not `{:ok, :cleared}`, so `log_undo/5`
  # falls to its warning clause and the line names all three outcomes. That is correct: the
  # undo genuinely did not fully undo, and the residue is a live credential PLUS a story
  # still naming it, which is the state `force_unclaim_story/3` is then able to clear.
  #
  # `clear_unused_implementer_dispatch/3` cannot return an error, but it is one `update_all`
  # plus an audit insert on the same unguarded 3-connection pool, so it can RAISE — which is
  # the first of the two things `safe_clear/4` above rescues, for the reason
  # `release_claim/5` and `revoke_session_dispatch/3` swallow theirs.
  # ONE RESCUE FOR BOTH WAYS THIS STEP CAN GO WRONG, and it is at the CALL rather than inside
  # a clause, which is what makes it cover the second way: a `FunctionClauseError` from a
  # revoke outcome neither clause below matches is raised HERE, in this body, so it is caught
  # exactly like a raise from the clear itself.
  #
  # Both matter because of POSITION. This runs THIRD of `undo_claim/5`'s five statements:
  # `log_undo/5` and `park_unreleased_claim/6` follow it, neither `undo_claim/5` nor `place/4`
  # rescues, so anything that escapes here replaces the caller's real refusal with an
  # exception AND SKIPS THE 846.1 ESCALATION — a story left `claimed` with no human told,
  # which is the four-hour incident this branch exists to end, reached by a different door.
  # `park_unreleased_claim/6` may crash for the same class of miss because it is LAST;
  # nothing is lost after it. That argument does not transfer to this function, and for one
  # review round the comment below claimed it did.
  #
  # A THIRD CLAUSE WAS THE OBVIOUS FIX AND DIALYZER REFUSES IT: `revoke_session_dispatch/3`'s
  # success typing is `:ok | {:error, _}`, so a catch-all is `pattern_match_cov`, and
  # `@dialyzer` suppressions are not allowed here. `Progress.skip_explanation/1` records the
  # same collision and resolves it the same way — no unreachable clause, let the miss crash —
  # and the only thing this adds is that a crash HERE must not take two statements with it.
  # A rescue is invisible to that analysis, so it buys the safety without the dead clause.
  defp safe_clear(tenant_id, story_id, session, revoked) do
    clear_if_revoked(tenant_id, story_id, session, revoked)
  rescue
    error -> {:error, error}
  end

  defp clear_if_revoked(tenant_id, story_id, session, :ok) do
    Progress.clear_unused_implementer_dispatch(tenant_id, story_id, session.id)
  end

  defp clear_if_revoked(_tenant_id, _story_id, _session, {:error, _revoke_failed}),
    do: {:ok, :kept_for_remediation}

  # THE CONDITION, and it is two total clauses over what `release_claim/5` returns rather than a
  # predicate plus a catch-all: a released claim needs nothing, and every other outcome of that
  # function is a failure by construction. A catch-all here would silently absorb a third shape
  # if one were ever added, which on this branch means silently NOT escalating.
  defp park_unreleased_claim(_tenant_id, _story, _session, _reason, :ok, _opts), do: :ok

  defp park_unreleased_claim(tenant_id, story, session, reason, {:error, release_error}, opts) do
    escalate_unreleased_claim(tenant_id, story, session, reason, release_error, opts)
  end

  @doc """
  Parks a story whose claim this placement made and could not give back.

  Public only so the failed-compensation half can be exercised without staging a database
  failure inside a live `place/4` — the same reason `Loopctl.Delivery.StoryPayload` publishes
  `settle_if_parked/3`, and for the same trade: the alternative is a mockable seam through the
  claim path, which is the one path in this module that must not grow a configuration surface.
  `place/4` reaches it through `undo_claim/5` and nothing else should call it.

  Always returns `:ok`. The caller is owed the refusal that brought it here, not this one.

  ## The epoch is the CLAIM's, and is never re-read

  Fenced on the epoch this placement claimed under, which is still the story's:
  `Progress.force_unclaim_story/3` performs every write in one `AdminRepo.transaction/1`, and
  its only post-commit step is `revoke_released_session_credential/3`, which rescues everything
  and always returns `:ok` — so a REPORTED release failure is always a rolled-back transaction
  and the epoch cannot have moved under it.

  Re-reading it would be worse than redundant. An epoch read fresh would let this park a story
  whose claim HAD gone back and been re-taken by somebody else — a live session's work stopped
  by a compensation that no longer owns anything, which is exactly the hazard `resume/4` refuses
  to take for the same reason. If the epoch has moved despite the argument above,
  `Stages.advance/4` answers `:stale_claim_epoch` and `settle_if_parked/3` re-reads the row: an
  escalated row is the outcome whoever wrote it, and anything else is reported as stranded. The
  fence failing is the safe direction.

  ## The stage is READ, not assumed

  `claimed` is the ordinary case, but `enter_claimed_and_push/6` also reaches its `else` when the
  `queued -> claimed` advance itself was refused — leaving a story that is claimed while its row
  is still at `queued`, which `:session_escalated` cannot leave. The edge is therefore checked
  against `StageMachine.transitions/0` and a stage with no edge is NAMED rather than reported as
  a bare `:invalid_transition`. That check reads the machine's own table, so it cannot drift from
  it; it is deliberately a second copy of the shape in `StoryPayload` rather than a shared
  helper, because the two compose different reasons and event data and share only four lines. A
  third caller is what should extract it.

  ## Where the recursion stops, and why here

  ONE attempt, no retry, and no compensation for this compensation. Escalation is terminal by
  construction: it is the mechanism for putting a decision in front of a human, and there is
  nothing above a human to escalate to — a fallback for a failed escalation could only be
  another escalation, with the same failure modes, on the same row. So a refusal is logged at
  `:error` with the story named as stranded, which is the same shape and the same argument
  `Loopctl.Delivery.StoryPayload` already uses for `{:escalation_failed, _, _}`. What remains
  underneath is what was there before this function existed: the claim lease, and the operator
  remedies the log names.

  A RAISE is swallowed for the same reason the release swallows one — `Stages.get/2` and the
  chain append run on a pool with no `lock_timeout` of their own, and an exception here would
  replace the push refusal the caller is owed with a second, unrelated one.
  """
  @spec escalate_unreleased_claim(
          Ecto.UUID.t(),
          Story.t(),
          Dispatch.t(),
          term(),
          term(),
          keyword()
        ) :: :ok
  def escalate_unreleased_claim(tenant_id, story, session, placement_error, release_error, opts) do
    tenant_id
    |> park(story, session, placement_error, release_error, opts)
    |> log_park(tenant_id, story, session, placement_error, release_error)
  rescue
    error ->
      log_park({:error, error}, tenant_id, story, session, placement_error, release_error)
  end

  defp park(tenant_id, story, session, placement_error, release_error, opts) do
    case stage_of(tenant_id, story.id) do
      nil ->
        {:error, :unknown_story_stage}

      stage ->
        tenant_id
        |> attempt_park(story, stage, session, placement_error, release_error, opts)
        |> StoryPayload.settle_if_parked(tenant_id, story.id)
    end
  end

  defp attempt_park(tenant_id, story, stage, session, placement_error, release_error, opts) do
    transition = {stage, :escalated, :session_escalated}

    if transition in StageMachine.transitions() do
      Stages.advance(tenant_id, story.id, transition,
        claim_epoch: story.claim_epoch,
        # The PLACEMENT CALLER, exactly as `release_claim/5` and `revoke_session_dispatch/3`
        # attribute their own compensations: the session this was minted for never ran, so
        # recording its lineage on an immutable chain entry would say a session asked for a
        # human when no session existed. An empty list here is an ATTESTED absence (an
        # operator-key caller mints a root), which `lineage_declared/4` accepts and
        # `human_gate/2` never sees — `:session_escalated` is not a human-only edge, so the
        # `actor_lineage == []` half of `Stages.human?/1` is not in play on this transition.
        actor_lineage: caller_lineage(session),
        actor_label: compensation_actor(opts),
        reason: unreleased_claim_reason(placement_error, release_error),
        event_data: unreleased_claim_event_data(session, placement_error, release_error)
      )
    else
      {:error, {:no_escalation_edge, stage}}
    end
  end

  # The caller's own label plus what this park was for — see `@escalation_actor` for why a
  # DEFAULT could not carry that, and the closing assertions of `placement_test.exs`'s "a
  # release that genuinely FAILED escalates the story, through place/4" for what holds it.
  #
  # A `case` and not `Keyword.get/3`: an explicit `actor_label: nil` is a present key, so the
  # default would not apply and `nil <> suffix` would raise — swallowed by the rescue in
  # `escalate_unreleased_claim/6`, which would LOSE the park rather than mislabel it.
  defp compensation_actor(opts) do
    case Keyword.get(opts, :actor_label) do
      label when is_binary(label) -> label <> @compensation_suffix
      _ -> @escalation_actor <> @compensation_suffix
    end
  end

  # "is ESCALATED", not "has been escalated BY THIS CALL": `settle_if_parked/3` reaches this
  # branch for a row somebody ELSE parked — a retried placement, or the story object builder
  # having already parked an undispatchable story before the push was ever refused. The row
  # being at `escalated` is the outcome either way, and a line claiming authorship it does not
  # have would be a false statement in the one place an operator goes to reconstruct what
  # happened. The CLAIM half is this call's own and is stated flatly, because in the
  # already-parked case it is the only thing this line adds.
  #
  # AND THE REMEDY NAMES ITS PRECONDITION HERE TOO, at more length than
  # `unreleased_claim_reason/2` can afford: this is a Logger call under no length bound, and
  # the reader of this line is the orchestrator key that just ran `place/4` — the one principal
  # `stage/resolve` refuses. The three gates are named above `unreleased_claim_reason/2`.
  defp log_park({:ok, _row}, tenant_id, story, session, placement_error, release_error) do
    Logger.warning(
      "placement could not release the claim it made; the story is ESCALATED and waiting for " <>
        "a human, with that claim still standing. " <>
        "Resolve it to queued (POST /api/v1/stories/#{story.id}/stage/resolve, MCP " <>
        "resolve_escalation), which releases the claim and re-contracts the story. THAT CALL " <>
        "NEEDS A HUMAN KEY: role user or above, minted by no dispatch — the orchestrator key " <>
        "that placed this story is refused 403 insufficient_role, and a dispatch-minted user " <>
        "key clears the plugs and is then refused human_required. " <>
        "tenant_id=#{tenant_id} story_id=#{story.id} claim_epoch=#{story.claim_epoch} " <>
        "session_dispatch_id=#{session.id} placement_error=#{short(placement_error)} " <>
        "release_error=#{short(release_error)}",
      tenant_id: tenant_id,
      story_id: story.id
    )

    :ok
  end

  # LOUDER THAN THE BRANCH ABOVE, on the same argument `StoryPayload.refuse/4` makes: an
  # escalated story is the harmless outcome because a human has it. This one is the story that
  # is neither placeable nor parked, held by a session that will never run, with nothing
  # downstream that will pick it up before the lease — which a halted tenant never reaches at
  # all, since `ReclaimExpiredClaimsWorker` skips it.
  #
  # AND THE REMEDY NAMES ITS OWN PRECONDITION, because the halted tenant this message reasons
  # about in that same sentence is refused the remedy it used to name. `force-unclaim` is in
  # `LoopctlWeb.CustodySurface`'s `@story_custody_ops`, so `LoopctlWeb.Plugs.CheckCustodyHalt`
  # — mounted in the `:authenticated` pipeline (`LoopctlWeb.Router`) — answers
  # `503 tenant_halted` before the controller runs, and an operator in exactly the state
  # described here followed the only remedy named and got a 503. The break-glass is the
  # precondition and is named with it.
  #
  # `stage/resolve` is NOT the answer on this branch even though it is halt-exempt (its path
  # has four segments, so `custody_path?/1` falls through to `false`): this is the branch where
  # the escalation did not happen, so there is no escalation to resolve.
  defp log_park({:error, reason}, tenant_id, story, session, placement_error, release_error) do
    Logger.error(
      "placement could not release the claim it made AND COULD NOT ESCALATE the story. It is " <>
        "held at its current stage by a session that will never run, and no automatic path " <>
        "frees it before the claim lease — a halted tenant never reaches that either. Free it: " <>
        "POST /api/v1/stories/#{story.id}/force-unclaim (MCP force_unclaim_story), then " <>
        "contract it before placing it again. IF THIS TENANT IS HALTED, force-unclaim is " <>
        "suspended with every other custody operation and answers 503 tenant_halted: clear " <>
        "the halt first, through the superadmin break-glass ceremony (POST " <>
        "/api/v1/admin/tenants/#{tenant_id}/clear-halt/challenge, then .../clear-halt). " <>
        "tenant_id=#{tenant_id} story_id=#{story.id} " <>
        "claim_epoch=#{story.claim_epoch} session_dispatch_id=#{session.id} " <>
        "placement_error=#{short(placement_error)} release_error=#{short(release_error)} " <>
        "escalation_error=#{short(reason)}",
      tenant_id: tenant_id,
      story_id: story.id
    )

    :ok
  end

  # LOOPCTL'S OWN WORDS. This text reaches the story's `escalation_reason` column and, on this
  # chained transition, the tenant's append-only hash chain, so none of it may be
  # session-authored — `Loopctl.Delivery.Untrusted` exists for the text that is.
  #
  # THE PRIMARY REMEDY NAMES ITS PRECONDITION, because the principal most likely to read this
  # row cannot perform it: `stage/resolve` is gated by `RequireRole, role: :user`, then
  # `RequireHumanAnchor` (`LoopctlWeb.StoryEscalationController`), then `Stages.human?/1`,
  # which also wants `actor_lineage == []`. The orchestrator key that ran `place/4` gets
  # `403 insufficient_role`; a dispatch-minted `:user` key clears both plugs and is then
  # refused `:human_required`. Only an unlineaged `user`+ key on a human-anchored tenant
  # resolves it.
  #
  # THE SECOND REMEDY SAYS WHAT FORCE-UNCLAIM DOES NOT DO, because this is read off an
  # ESCALATED row. `Stages.follow_release/5` requeues only a stage in
  # `StageMachine.in_flight_stages/0` and `escalated` is not one, so the release rebinds the
  # row and the stage stays `escalated`, while `claimable/2` requires `queued`. An operator who
  # force-unclaimed and re-contracted got `{:error, :wrong_stage}` with nothing here saying why.
  #
  # THE GATE IS `reason_within_bound?/1`, 4_000 codepoints of the RAW text, and the fit is
  # ASSERTED rather than argued: `placement_test.exs`'s "an error term whose size is its
  # ELEMENT COUNT cannot lose the escalation" parks with the fattest pair reachable here and
  # asserts the row reached `escalated`, which IS the length check — over the bound
  # `Stages.advance/4` refuses `:invalid_reason` BEFORE the transition, so there is no park to
  # read a length off. An edit that eats the headroom reds that test instead of losing a park
  # in production (mutation-proved: 450 characters added to the prose below turns it red). The
  # remedy is written FIRST and the diagnostics LAST so that an overrun a future edit did slip
  # past would cost an operator the diagnostics and not the instruction. No headroom FIGURE is
  # quoted here: three rounds stated it three different ways, all wrong in the same direction,
  # and two careful measurements still disagreed — the assertion is what holds the bound.
  #
  # BOTH `short/1` OPTIONS EARN THEIR PLACE, AND NEITHER IS UNFALSIFIABLE. `:limit` is spent
  # across the WHOLE traversal rather than per container, so nesting cannot multiply the output
  # (20 sibling 5-element lists render at the width of 5), and it is the only bound on a term
  # whose size is its ELEMENT COUNT — opening it to `:infinity` reds the test above.
  # `:printable_limit` is the only bound on one long binary, the shape a changeset's `:errors`
  # has; opening IT reds two tests.
  #
  # A WHOLE-TEXT CLAMP STAYS OUT: it would absorb exactly that edit, silently. WHAT WOULD
  # OVERTURN THAT — a term whose size is neither an element count nor a binary's length, which
  # neither option bounds (a 30_000-digit integer is one). This path has no such source:
  # `placement_error` is what `Runners.dispatch/3` and `fetch_uuid/2` refuse with, and
  # `release_error` is a changeset, an atom or an exception struct. A new one puts the clamp
  # INSIDE `short/1`, where it also covers `unreleased_claim_event_data/2`'s 8_000-byte bound.
  defp unreleased_claim_reason(placement_error, release_error) do
    "loopctl claimed this story for a runner, the dispatch was refused, and the compensating " <>
      "release of that claim ALSO failed. The story is held by a session that will never " <>
      "run, and no automatic path frees it before the claim lease. REMEDY: resolve this " <>
      "escalation to queued (POST /api/v1/stories/:id/stage/resolve, MCP " <>
      "resolve_escalation) — that releases the claim, revokes its session credential and " <>
      "re-contracts the story, so one call makes it placeable again. That call needs a HUMAN " <>
      "key: role user or above, minted by no dispatch — the orchestrator key that placed " <>
      "this story is refused 403 insufficient_role. Force-unclaim (POST " <>
      "/api/v1/stories/:id/force-unclaim, MCP force_unclaim_story) frees the claim but does " <>
      "NOT clear this escalation: the stage row stays at escalated, so the story is still " <>
      "unplaceable and you have to resolve it anyway. " <>
      "placement_error=#{short(placement_error)} release_error=#{short(release_error)}"
  end

  # Small by construction rather than by fitting: four short scalars, well under
  # `Stages.max_event_data_bytes/0`, so there is no halving dance to get wrong. The bounded
  # inspects are what keep it that way — an unbounded changeset would be the one term that
  # could push it over and turn the escalation into `:invalid_event_data`, which is the
  # "neither dispatchable nor parked" outcome the truncation everywhere else exists to prevent.
  defp unreleased_claim_event_data(session, placement_error, release_error) do
    %{
      "placement_compensation" => "release_failed",
      "placement_error" => short(placement_error),
      "release_error" => short(release_error),
      "session_dispatch_id" => session.id
    }
  end

  # Bounded on BOTH axes: `:limit` caps how many elements of a container are shown, and
  # `:printable_limit` caps the bytes of any one binary inside it. Capping only the first still
  # lets a single long message through, and a changeset's `:errors` is exactly that shape.
  defp short(term), do: inspect(term, limit: 5, printable_limit: 200)

  # Silent when the undo did everything it is for. `{:ok, :unchanged}` from the clear is NOT a
  # failure — it means the story no longer names this dispatch, which is what a re-claim
  # THROUGH A DISPATCH leaves behind — but it is worth one line, because it is also what a
  # deleted story leaves behind and nothing else on this path would say so.
  defp log_undo(_tenant_id, _story_id, _session, _reason, {:ok, {:ok, :cleared}, :ok}), do: :ok

  defp log_undo(tenant_id, story_id, session, reason, {release, cleared, revoked}) do
    Logger.warning(
      "placement undo did not fully undo: tenant_id=#{tenant_id} story_id=#{story_id} " <>
        "session_dispatch_id=#{session.id} placement_error=#{inspect(reason)} " <>
        "release=#{inspect(release)} clear=#{inspect(cleared)} revoke=#{inspect(revoked)}",
      tenant_id: tenant_id,
      story_id: story_id
    )

    :ok
  end

  # Compensation, not a second decision. A refusal after the claim committed means no session
  # will ever run under it, so the claim goes back and the stage row follows it to `queued`
  # over `:claim_released` in the same transaction (`Stages.follow_release/5`).
  #
  # A failure HERE is logged and swallowed: the caller is owed the refusal that caused this,
  # not this one, and the claim's lease plus `ReclaimExpiredClaimsWorker` is the backstop that
  # already exists for a placement whose node died at this exact point.
  #
  # **AND IT HAS TO SWALLOW A RAISE, NOT ONLY AN `{:error, _}`.** A `case` alone did not, and
  # the paths that raise are the ordinary ones rather than exotica:
  # `force_unclaim_story/3`'s own result `case` matches three shapes, so a failure in its
  # `:stage` or `:audit` step is a `CaseClauseError`; `Stages.follow_release/5` hard-matches
  # `{1, [updated]}`, so a reclaimer that got there first is a `MatchError`; and that
  # `AdminRepo` transaction sets no `lock_timeout`, so a contended story row raises a
  # `DBConnection` error. None of those is `{:error, _}`, so each one replaced the push refusal
  # the caller is owed with an exception, LOST the original reason, and left the claim standing
  # anyway — strictly worse than the outcome this function exists to improve on.
  # Returns `:ok` or the failure. It used to return `:ok` unconditionally, which read as "the
  # lease is the backstop, nothing is stranded" — no longer true now that the undo has steps
  # the lease does not perform, and the caller cannot tell a released claim from a swallowed
  # failure if every outcome looks the same.
  #
  # `actor_lineage` is FORWARDED, not defaulted. `force_unclaim_story/3` revokes the story's
  # session dispatch on its way past, so this call is what puts a `dispatch_revoked` entry on
  # the hash chain for the undo path — and `Progress` reads the lineage as
  # `Keyword.get(opts, :actor_lineage, [])`, so omitting it recorded the placement caller's
  # compensation as the tenant operator's act.
  #
  # `release_cause:` (US-44.4, #877) is never the operator default: that escalates the story
  # for a human, and before it existed the story sat at `queued` + `:pending`, which no
  # placement ever takes. Which of the two undo causes is `release_cause/1`'s call.
  defp release_claim(tenant_id, story_id, reason, actor_lineage, opts) do
    case Progress.force_unclaim_story(tenant_id, story_id,
           actor_label: Keyword.get(opts, :actor_label),
           actor_lineage: actor_lineage,
           release_cause: release_cause(reason)
         ) do
      {:ok, _story} -> :ok
      other -> log_release_failure(tenant_id, story_id, reason, other)
    end
  rescue
    error -> log_release_failure(tenant_id, story_id, reason, error)
  end

  # WHETHER THE REFUSAL SPENT AN ATTEMPT, decided by what refused (#877 review round 1,
  # finding 3). The RUNNER being unavailable for this dispatch — gone, not the sole socket,
  # at capacity, the tenant at its admission limit, a lock not granted, the tenant halted — is
  # a state the next pass may not find, so the undo spends nothing (`:placement_refused`) and
  # the story is re-contracted for it. EVERYTHING ELSE recurs on every pass for this story —
  # a payload the contract rejects, a story that could not be attached, a ledger conflict —
  # and uncounted it was placed, refused and released every pass for ever, a chain entry each
  # time. So it counts (`:attempt`) and the retry ceiling puts it in front of a human.
  #
  # An allowlist of the transient ones, not of the deterministic ones: a refusal nobody has
  # classified yet is bounded by the ceiling rather than looping.
  @runner_unavailable [
    :runner_not_connected,
    :runner_ambiguous,
    :runner_at_capacity,
    :admission_limit_reached,
    :capacity_busy,
    :busy,
    :tenant_halted
  ]

  defp release_cause(reason) when reason in @runner_unavailable, do: :placement_refused
  defp release_cause(_recurs_every_pass), do: :attempt

  defp log_release_failure(tenant_id, story_id, reason, outcome) do
    Logger.error(
      "placement could not release the claim it made; the lease releases the CLAIM but " <>
        "clears no dispatch id: tenant_id=#{tenant_id} story_id=#{story_id} " <>
        "placement_error=#{inspect(reason)} release_error=#{inspect(outcome)}",
      tenant_id: tenant_id,
      story_id: story_id
    )

    {:error, outcome}
  end

  defp implementer_dispatch_id(tenant_id, story_id) do
    case Stories.get_story(tenant_id, story_id) do
      {:ok, story} -> story.implementer_dispatch_id
      _other -> nil
    end
  end

  # Read before anything is minted or claimed: a payload with no usable `dispatch_id` cannot be
  # made idempotent, and one with no `story_id` names nothing to claim. Both are refused by the
  # contract too, inside `Runners.dispatch/3` — but that is after the claim, which is exactly
  # the ordering this module exists to avoid.
  defp fetch_uuid(dispatch, key) do
    case Ecto.UUID.cast(Map.get(dispatch, key)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid, ["#{key}: must be a UUID"]}}
    end
  end
end
