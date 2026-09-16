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
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryPayload
  alias Loopctl.Dispatches
  alias Loopctl.Progress
  alias Loopctl.Runners
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Tenants
  alias Loopctl.WorkBreakdown.Stories

  # How long the session dispatch's credential lives. `Dispatches.create_dispatch/3` caps this
  # at four hours of its own accord, while a dispatch's `wall_clock_seconds` may be a day, so
  # the two do NOT line up and this is the shorter of them on purpose: the dispatch row's
  # lineage is what the custody gates read and it outlives the key, while the key itself has
  # no holder at all (see the moduledoc).
  @session_expires_in_seconds 14_400

  @type error ::
          :root_dispatch_forbidden
          | :insufficient_role
          | :custody_tier_required
          | :tenant_halted
          | :not_authorized
          | :runner_not_provisioned
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
  - `:not_found`, `:invalid_transition`, `:wrong_stage` — from the pre-mint readiness check.
    A story that passes the check and is claimed by someone else in between instead gets
    `Loopctl.Progress.claim_story/3`'s own richer `{:invalid_transition, map()}`, and the
    session dispatch minted for it is REVOKED before returning.
  - everything `Loopctl.Dispatches.create_dispatch/3`, `Loopctl.Delivery.Stages.advance/4`
    and `Loopctl.Runners.dispatch/3` refuse, unchanged. Every refusal after the claim commits
    releases the claim before returning.

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
    with {:ok, payload} <- resume_payload(tenant_id, dispatch, record) do
      push_resumed(tenant_id, runner_id, payload, record)
    end
  end

  defp resume_payload(tenant_id, dispatch, record) do
    with {:ok, story} <- Stories.get_story(tenant_id, record.story_id),
         {:ok, dispatch} <- DispatchPayload.fill(tenant_id, dispatch),
         {:ok, dispatch} <- rebuild_story(dispatch, story) do
      {:ok, Map.put(dispatch, "claim_epoch", record.claim_epoch)}
    end
  end

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
  defp claim_and_push(tenant_id, runner_id, dispatch, story_id, caller, opts) do
    with {:ok, agent_id} <- runner_agent_id(tenant_id, runner_id),
         {:ok, dispatch} <- DispatchPayload.fill(tenant_id, dispatch),
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

  # Returns `:ok` or the failure, so the undo can report it rather than swallow it. The failure
  # is worth naming on its own, and the message has to name the CONSEQUENCE rather than the
  # timestamp — see below.
  defp revoke_session_dispatch(tenant_id, session, reason) do
    case Dispatches.revoke(tenant_id, session.id) do
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
        Logger.error(
          "placement could not revoke the session dispatch its claim never used. The key stays " <>
            "usable for its full TTL and OCCUPIES the agent's one-key-per-role slot until " <>
            "then, so every later placement onto this agent is refused 422 'agent already has " <>
            "an active key with this role'. Revoke it: POST " <>
            "/api/v1/dispatches/#{session.id}/revoke (MCP revoke_dispatch), or force-unclaim " <>
            "the story. tenant_id=#{tenant_id} dispatch_id=#{session.id} " <>
            "agent_id=#{inspect(session.agent_id)} claim_error=#{inspect(reason)} " <>
            "revoke_error=#{inspect(other)}",
          tenant_id: tenant_id
        )

        other
    end
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
        undo_claim(tenant_id, story.id, session, reason, opts)
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

  # THE WHOLE UNDO: release the claim, UNRECORD the session dispatch, revoke it. Three steps
  # because the claim's release does only the first.
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
  # ## What the ORDER is and is not
  #
  # RELEASE FIRST IS REQUIRED. Everything downstream describes a story nobody is working on,
  # and the release is what makes that true.
  #
  # CLEAR BEFORE REVOKE IS NOT REQUIRED, and this no longer claims it is. It was justified by
  # the false mechanism above; with that gone the two are independent — a story naming a
  # revoked dispatch and one naming a live dispatch are refused identically. They stay in this
  # order because it reads as the undo of the claim that recorded it, not because a window
  # between them is dangerous.
  #
  # Each step reports, and `log_undo/5` says so when any of them did not do what it was for.
  # Nothing here rolls anything back on failure: the caller is owed the refusal that brought it
  # here, not a second one.
  defp undo_claim(tenant_id, story_id, session, reason, opts) do
    release = release_claim(tenant_id, story_id, reason, opts)
    cleared = Progress.clear_unused_implementer_dispatch(tenant_id, story_id, session.id)
    revoked = revoke_session_dispatch(tenant_id, session, reason)
    log_undo(tenant_id, story_id, session, reason, {release, cleared, revoked})
  end

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
  defp release_claim(tenant_id, story_id, reason, opts) do
    case Progress.force_unclaim_story(tenant_id, story_id,
           actor_label: Keyword.get(opts, :actor_label)
         ) do
      {:ok, _story} -> :ok
      other -> log_release_failure(tenant_id, story_id, reason, other)
    end
  rescue
    error -> log_release_failure(tenant_id, story_id, reason, error)
  end

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
