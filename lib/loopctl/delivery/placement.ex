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

  **The lineage ceiling is enforced here, not inherited.** The caller states the lineage it
  resolved SERVER-SIDE from its own authenticating key (`:caller_lineage`, no default — an
  absent one is a caller that never resolved one, exactly as `Stages.advance/4` treats it) and
  the role of that key (`:caller_role`). The session dispatch is parented on the LAST element
  of that lineage, so it can only ever land inside the caller's own subtree. A caller with NO
  lineage would be minting a ROOT, which only the tenant's operator key may do, so it is
  refused `:root_dispatch_forbidden` unless the role is at least `:user` — the same positive
  operator test `LoopctlWeb.DispatchController` applies, for the same reason: an empty lineage
  is also what a legacy env-var key and an unresolvable dispatch look like.

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
    refusal from `Runners.dispatch/3` is answered inline by releasing the claim
    (`Loopctl.Progress.force_unclaim_story/3`), which bumps the epoch and requeues the stage
    row over `:claim_released`. If THAT fails too, the claim's lease expires and
    `Loopctl.Workers.ReclaimExpiredClaimsWorker` does the same thing over `:runner_lost`. Both
    ends are already built; nothing is stranded.
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

  alias Loopctl.Auth.Role
  alias Loopctl.Delivery.Stages
  alias Loopctl.Dispatches
  alias Loopctl.Progress
  alias Loopctl.Runners
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.WorkBreakdown.Stories

  # How long the session dispatch's credential lives. `Dispatches.create_dispatch/3` caps this
  # at four hours of its own accord, while a dispatch's `wall_clock_seconds` may be a day, so
  # the two do NOT line up and this is the shorter of them on purpose: the dispatch row's
  # lineage is what the custody gates read and it outlives the key, while the key itself has
  # no holder yet (see `session_dispatch_key_unused/0`).
  @session_expires_in_seconds 14_400

  @type error ::
          :root_dispatch_forbidden
          | :not_authorized
          | :busy
          | atom()
          | {:invalid, [String.t()]}
          | {:invalid_transition, map()}

  @doc """
  Claims `dispatch["story_id"]` for `runner_id` and pushes the dispatch to it.

  `dispatch` is a `RunnerDispatch` payload with STRING keys, exactly as
  `Loopctl.Runners.dispatch/3` takes one, except that it carries no `"claim_epoch"`: the epoch
  is not known until the claim commits, so any value under that key is REPLACED with the one
  the claim produced. Everything else — `dispatch_id`, `story_id`, `kind`, the repo, the
  branches, the wall clock, the story object — is the caller's and is validated by the
  contract inside `Runners.dispatch/3`.

  The story must already be `contracted` (`Loopctl.Progress.contract_story/3`) and its stage
  row must be at `queued`; anything else is refused before the push, and the claim is released
  again.

  Returns `{:ok, %{dispatch_id:, claim_epoch:, implementer_dispatch_id:}}` — the last of which
  is the session dispatch this placement minted, or the one the original placement minted when
  this call was a retry that resumed from the ledger.

  ## Options

  - `:caller_lineage` (required) — the lineage of the key asking for this placement, resolved
    SERVER-SIDE by the caller. There is no default: an absent one is a caller that never
    resolved a lineage, which is not the same as a caller that has none.
  - `:caller_role` (required) — that key's role, likewise server-resolved. Only a `:user` or
    above may place with an EMPTY lineage, because the session dispatch would then be a root.
  - `:actor_label` — recorded on the claim, the transition and the release.

  ## Refusals

  - `:root_dispatch_forbidden` — an unlineaged caller below `:user` (see the moduledoc)
  - `:not_authorized` — no such runner in this tenant, or its row, key or tenant is no
    longer valid
  - `:runner_not_provisioned` — a runner row with no `agent_id`, which the
    `add_agent_id_to_runners` migration makes unreachable and this refuses rather than
    claiming a story for nobody
  - everything `Loopctl.Dispatches.create_dispatch/3`, `Loopctl.Progress.claim_story/3`,
    `Loopctl.Delivery.Stages.advance/4` and `Loopctl.Runners.dispatch/3` refuse, unchanged.
    Every refusal after the claim commits releases the claim before returning.
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
    caller_lineage = Keyword.fetch!(opts, :caller_lineage)
    caller_role = Keyword.fetch!(opts, :caller_role)

    with {:ok, dispatch_id} <- fetch_uuid(dispatch, "dispatch_id"),
         {:ok, story_id} <- fetch_uuid(dispatch, "story_id"),
         :ok <- may_mint_session_dispatch(caller_lineage, caller_role) do
      case DispatchLedger.get_record(tenant_id, dispatch_id) do
        nil -> claim_and_push(tenant_id, runner_id, dispatch, story_id, opts)
        record -> resume(tenant_id, runner_id, dispatch, record)
      end
    end
  end

  # A retry of a dispatch the ledger already holds. Nothing is claimed, minted or bumped: the
  # placement already happened, and what is left is to put the frame on the wire again under
  # the epoch the ORIGINAL claim produced. Pushing under a freshly read epoch instead would
  # hand the runner a number its ledger row does not carry, and `record_sent/3` would refuse
  # it as a `:dispatch_id_conflict`.
  defp resume(tenant_id, runner_id, dispatch, record) do
    payload = Map.put(dispatch, "claim_epoch", record.claim_epoch)

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

  defp claim_and_push(tenant_id, runner_id, dispatch, story_id, opts) do
    with {:ok, agent_id} <- runner_agent_id(tenant_id, runner_id),
         {:ok, session} <- mint_session_dispatch(tenant_id, agent_id, story_id, opts),
         {:ok, story} <- claim(tenant_id, story_id, agent_id, session, opts) do
      enter_claimed_and_push(tenant_id, runner_id, dispatch, story, session, opts)
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
         :ok <- Runners.dispatch(tenant_id, runner_id, Map.put(dispatch, "claim_epoch", epoch)) do
      {:ok,
       %{
         dispatch_id: Map.fetch!(dispatch, "dispatch_id"),
         claim_epoch: epoch,
         implementer_dispatch_id: session.id
       }}
    else
      {:error, reason} ->
        release_claim(tenant_id, story.id, reason, opts)
        {:error, reason}
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
  defp mint_session_dispatch(tenant_id, agent_id, story_id, opts) do
    caller_lineage = Keyword.fetch!(opts, :caller_lineage)

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
  defp may_mint_session_dispatch([], role) do
    if Role.role_at_least?(role, :user), do: :ok, else: {:error, :root_dispatch_forbidden}
  end

  defp may_mint_session_dispatch(lineage, _role) when is_list(lineage), do: :ok

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

  # Compensation, not a second decision. A refusal after the claim committed means no session
  # will ever run under it, so the claim goes back and the stage row follows it to `queued`
  # over `:claim_released` in the same transaction (`Stages.follow_release/5`).
  #
  # A failure HERE is logged and swallowed: the caller is owed the refusal that caused this,
  # not this one, and the claim's lease plus `ReclaimExpiredClaimsWorker` is the backstop that
  # already exists for a placement whose node died at this exact point.
  defp release_claim(tenant_id, story_id, reason, opts) do
    case Progress.force_unclaim_story(tenant_id, story_id,
           actor_label: Keyword.get(opts, :actor_label)
         ) do
      {:ok, _story} ->
        :ok

      other ->
        Logger.error(
          "placement could not release the claim it made; the lease is the backstop: " <>
            "tenant_id=#{tenant_id} story_id=#{story_id} " <>
            "placement_error=#{inspect(reason)} release_error=#{inspect(other)}",
          tenant_id: tenant_id,
          story_id: story_id
        )

        :ok
    end
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
