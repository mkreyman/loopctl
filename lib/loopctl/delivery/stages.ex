defmodule Loopctl.Delivery.Stages do
  @moduledoc """
  The Postgres-owned per-story delivery stage machine (issue #803, design §3, §6, §11).

  One `Loopctl.Delivery.StoryStage` row per story holds its stage, the claim epoch it was
  written under, and the identity of every outward side effect. The transition table lives
  in `Loopctl.Delivery.StageMachine`; this module is the only writer.

  ## Where the state lives, and who runs the work

  Postgres, and nowhere else. No process owns a story: a runner, a DurableServer on a
  runner, or ANY loopctl node advances a row by reading it and compare-and-setting it in
  one transaction. A process that restarts, or a caller that reconnects to a different
  node of the cluster, reads the row again and carries on from what committed — anything
  it held in memory is a cache of this row and is never consulted in place of it. There is
  no registry to find a story's owner in, because there is no owner.

  ## Partitions

  A runner cut off from the control plane cannot advance anything — every write is a
  transaction here — and while it is gone its claim lease runs out. The reclaimer releases
  the claim, bumps `stories.claim_epoch`, and moves an in-flight row back to `queued` in
  the same transaction (`follow_release/5`, which every claim release calls). When the runner comes back, every write
  it attempts presents the OLD epoch and is refused `:stale_claim_epoch`: the zombie is
  fenced by the epoch, not by noticing it is a zombie. Two loopctl nodes are not a
  partition of the state at all: both write the one row, and the compare-and-set lets
  exactly one of two concurrent transitions commit.

  ## Retries

  Every call is safe to repeat.

  - `advance/4` is a compare-and-set on the expected stage. A retried transition whose
    first attempt committed finds the row already past `from` and is refused
    `:stale_stage` — it does not happen twice. The caller reads `get/2` to learn where the
    row is; the row, not the caller's memory, is the truth.
  - `record_effect/5` records an identity once. The same value again is `{:ok, row}`, so a
    replayed stage finds the worktree, PR or release its first run recorded and reuses it;
    a DIFFERENT value for an identity already set is `:effect_conflict`, so a replay can
    never record a second one. Record the identity BEFORE performing the effect.
  - `open/3` inserts `ON CONFLICT DO NOTHING` and returns the one row either way.

  ## Slow connections

  Every transaction here sets `lock_timeout` (2s) and `statement_timeout` (5s) locally, so a transaction waiting behind a lock holder — the reclaimer, a
  claim, a concurrent transition, the tenant's audit-chain head — gives up instead of
  waiting without bound while holding a pooled connection. That, and a pool checkout that
  times out, is `{:error, :busy}`: nothing committed, and the call may be retried.

  ## Locks and their order

  Every writer takes the STORY row first and the stage row second: `FOR SHARE` on the story
  here (so a claim release cannot commit between reading `claim_epoch` and the write it
  fences), `FOR UPDATE` in `Loopctl.Progress.reclaim_expired_claim/3`. The audit-chain head
  is always last. One order everywhere, so no two of them can deadlock.

  ## The audit chain

  Only the custody-critical transitions (`StageMachine.chained?/2`: into `claimed`,
  `merged`, `escalated`, and out of `escalated`) are appended to the hash chain, inside
  the transition's own transaction via `AuditChain.append_in_tenant_transaction/2`. Every
  transition and every newly recorded effect is in `story_stage_events`.

  ## Repo

  `Loopctl.Repo` inside `Repo.with_tenant/2`, with an explicit `tenant_id` predicate on
  every query as well. Never `AdminRepo` — its pool is three connections — except
  `follow_release/5`, which is a step of a claim release's existing `AdminRepo`
  transaction and takes no connection of its own. Like every `with_tenant/2` caller, none
  of the other functions may be called inside a `Repo` transaction.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.Auth.Role
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.LocalGuc
  alias Loopctl.Repo
  alias Loopctl.WorkBreakdown.Story

  @lock_timeout "2000ms"
  @statement_timeout "5000ms"

  # The story statuses a claim holds. Entering `claimed` needs one.
  @claimed_statuses [:assigned, :implementing]

  @sha ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/

  @max_pr_number 9_223_372_036_854_775_807

  @type advance_error ::
          :invalid_transition
          | :human_required
          | :reason_required
          | :not_found
          | :not_claimed
          | :stale_claim_epoch
          | :stale_stage
          | :busy

  @type effect_error ::
          :invalid_effect
          | :not_found
          | :stale_claim_epoch
          | :wrong_stage
          | :effect_conflict
          | :busy

  @doc """
  Creates a story's stage row at `detected`, bound to the story's current `claim_epoch`,
  or returns the row that already exists. Refuses a story that is not in the tenant.

  ## Options

  - `:actor_label` — recorded on the `opened` event
  """
  @spec open(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, StoryStage.t()} | {:error, :not_found | :busy}
  def open(tenant_id, story_id, opts \\ []) do
    in_tenant(tenant_id, fn ->
      story = share_lock_story(tenant_id, story_id)
      now = DateTime.utc_now()
      id = Ecto.UUID.generate()

      Repo.insert_all(
        StoryStage,
        [
          %{
            id: id,
            tenant_id: tenant_id,
            story_id: story_id,
            stage: :detected,
            claim_epoch: story.claim_epoch,
            attempts: %{},
            lock_version: 0,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:tenant_id, :story_id]
      )

      row = fetch_row!(tenant_id, story_id)

      # Only the insert that won writes the event; a replay finds the row and adds nothing.
      if row.id == id do
        insert_event(Repo, row, "opened", nil, nil, Keyword.get(opts, :actor_label), %{})
      end

      {row, nil}
    end)
  end

  @doc "A tenant's stage row for `story_id`, or nil."
  @spec get(Ecto.UUID.t(), Ecto.UUID.t()) :: StoryStage.t() | nil
  def get(tenant_id, story_id) do
    {:ok, row} =
      Repo.with_tenant(tenant_id, fn -> row_query(tenant_id, story_id) |> Repo.one() end)

    row
  end

  @doc "A story's stage events, oldest first."
  @spec list_events(Ecto.UUID.t(), Ecto.UUID.t()) :: [StageEvent.t()]
  def list_events(tenant_id, story_id) do
    {:ok, events} =
      Repo.with_tenant(tenant_id, fn ->
        Repo.all(
          from e in StageEvent,
            where: e.tenant_id == ^tenant_id and e.story_id == ^story_id,
            order_by: [asc: e.inserted_at, asc: e.lock_version]
        )
      end)

    events
  end

  @doc """
  Moves a story's stage row over one transition of `StageMachine.transitions/0` — a
  compare-and-set on the expected stage, fenced by the story's claim epoch.

  `transition` is `{from, to}` for a `:forward` transition or `{from, to, edge}`.

  Refused before touching the database:

  - `:invalid_transition` — not in the table, or a release edge (`:runner_lost`,
    `:claim_released`), which only the releasing transaction takes (`follow_release/5`)
  - `:human_required` — `:human_resolution` from anything but a human principal: a role of
    at least `:user` holding a key no dispatch minted (`actor_lineage` empty). The same
    positive operator test the lineage ceiling uses; a dispatch-minted `:user` key is an
    agent's, not Mark's.
  - `:reason_required` — entering `escalated` without a `:reason`

  Refused in the transaction, in this order:

  - `:not_found` — no such story, or no stage row, in the tenant
  - `:stale_claim_epoch` — `:claim_epoch` is not the story's current one (the caller's
    claim has ended), or the ROW is behind the story's epoch (the claim that drove it was
    released and nobody re-queued it)
  - `:not_claimed` — entering `claimed` on a story no claim holds
  - `:stale_stage` — the row is not at `from`: another writer, or this caller's own earlier
    attempt, already moved it

  Entering `claimed` rebinds the row to the story's current epoch — the claim just made.
  Every other transition requires the row to already be at it.

  ## Options

  - `:claim_epoch` (required) — the epoch the caller acts under
  - `:reason` — the escalation reason (required into `escalated`), or a note
  - `:actor_label`, `:actor_role`, `:actor_lineage` — attribution; role and lineage are
    SERVER-resolved by the caller from the authenticating key, never taken from a request
  """
  @spec advance(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          {StageMachine.stage(), StageMachine.stage()} | StageMachine.transition(),
          keyword()
        ) :: {:ok, StoryStage.t()} | {:error, advance_error()}
  def advance(tenant_id, story_id, {from, to}, opts),
    do: advance(tenant_id, story_id, {from, to, :forward}, opts)

  def advance(tenant_id, story_id, {from, to, edge}, opts) do
    epoch = Keyword.fetch!(opts, :claim_epoch)
    reason = Keyword.get(opts, :reason)

    with :ok <- allowed_for_caller(from, to, edge),
         :ok <- human_gate(edge, opts),
         :ok <- reason_given(to, reason) do
      in_tenant(tenant_id, fn ->
        transition(tenant_id, story_id, {from, to, edge}, epoch, opts)
      end)
    end
  end

  defp transition(tenant_id, story_id, {from, to, edge} = transition, epoch, opts) do
    reason = Keyword.get(opts, :reason)
    story = share_lock_story(tenant_id, story_id)

    # The fence against a zombie: a caller whose claim has ended presents an old epoch.
    if story.claim_epoch != epoch, do: Repo.rollback(:stale_claim_epoch)

    if to == :claimed and story.agent_status not in @claimed_statuses,
      do: Repo.rollback(:not_claimed)

    row = compare_and_set(tenant_id, story, transition, reason)
    insert_event(Repo, row, "transitioned", from, edge, opts[:actor_label], note(reason))
    {row, maybe_chain(row, transition, reason, opts)}
  end

  # The compare-and-set. The WHERE carries the expected stage and, except into `claimed`,
  # the story's epoch, so the UPDATE matches only a row still at `from` under the current
  # claim. Two concurrent transitions from the same stage both reach it; the second blocks
  # on the first's row lock, and once that commits Postgres re-checks the WHERE against the
  # committed row (READ COMMITTED), matches nothing, and this caller is refused.
  defp compare_and_set(tenant_id, story, {from, to, edge}, reason) do
    query =
      from(s in StoryStage,
        where: s.tenant_id == ^tenant_id and s.story_id == ^story.id,
        where: s.stage == ^from,
        select: s
      )

    query =
      if to == :claimed,
        do: query,
        else: where(query, [s], s.claim_epoch == ^story.claim_epoch)

    rebind = if to == :claimed, do: [claim_epoch: story.claim_epoch], else: []
    escalation = if to == :escalated, do: [escalation_reason: reason], else: []
    extra = rebind ++ escalation

    case query |> transition_update(from, to, edge, extra) |> Repo.update_all([]) do
      {1, [row]} -> row
      {0, _} -> Repo.rollback(diagnose(tenant_id, story, from))
    end
  end

  # Why the compare-and-set matched nothing.
  defp diagnose(tenant_id, story, from) do
    case Repo.one(row_query(tenant_id, story.id)) do
      nil -> :not_found
      %StoryStage{stage: stage} when stage != from -> :stale_stage
      %StoryStage{} -> :stale_claim_epoch
    end
  end

  @doc """
  Records the identity of a side effect on the story's stage row, idempotently.

  `effect` is one of `StageMachine.effects/0`: `:runner_id` (a runner UUID),
  `:worktree_path` (1..4096 characters), `:branch` and `:release_id` (1..255),
  `:pr_number` (positive integer), `:head_sha` and `:merge_sha` (40 or 64 lowercase hex).

  - `{:ok, row}` — recorded, or ALREADY recorded with this same value (a replay)
  - `:invalid_effect` — unknown effect or malformed value
  - `:not_found` — no such story or stage row in the tenant
  - `:stale_claim_epoch` — the caller's epoch, or the row's, is not the story's current one
  - `:wrong_stage` — the row is not in a stage that produces this effect
    (`StageMachine.effect_stages/1`)
  - `:effect_conflict` — the identity is already set to a DIFFERENT value

  ## Options

  - `:claim_epoch` (required), `:actor_label`
  """
  @spec record_effect(Ecto.UUID.t(), Ecto.UUID.t(), atom(), term(), keyword()) ::
          {:ok, StoryStage.t()} | {:error, effect_error()}
  def record_effect(tenant_id, story_id, effect, value, opts) do
    epoch = Keyword.fetch!(opts, :claim_epoch)

    with {:ok, value} <- validate_effect(effect, value) do
      in_tenant(tenant_id, fn ->
        effect_write(tenant_id, story_id, {effect, value}, epoch, opts)
      end)
    end
  end

  defp effect_write(tenant_id, story_id, {effect, value}, epoch, opts) do
    story = share_lock_story(tenant_id, story_id)
    if story.claim_epoch != epoch, do: Repo.rollback(:stale_claim_epoch)

    row =
      row_query(tenant_id, story_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    {apply_effect(row, story, effect, value, opts), nil}
  end

  defp apply_effect(nil, _story, _effect, _value, _opts), do: Repo.rollback(:not_found)

  defp apply_effect(row, story, effect, value, opts) do
    current = Map.fetch!(row, effect)

    cond do
      row.claim_epoch != story.claim_epoch -> Repo.rollback(:stale_claim_epoch)
      # A replay of the write that already landed, from any stage: nothing to do.
      current == value -> row
      row.stage not in StageMachine.effect_stages(effect) -> Repo.rollback(:wrong_stage)
      not is_nil(current) -> Repo.rollback(:effect_conflict)
      true -> set_effect(row, effect, value, opts)
    end
  end

  defp set_effect(row, effect, value, opts) do
    {1, [row]} =
      from(s in StoryStage,
        where: s.id == ^row.id and s.tenant_id == ^row.tenant_id,
        where: is_nil(field(s, ^effect)),
        select: s,
        update: [
          set: ^[{effect, value}, {:updated_at, DateTime.utc_now()}],
          inc: [lock_version: 1]
        ]
      )
      |> Repo.update_all([])

    data = %{"effect" => Atom.to_string(effect), "value" => event_value(value)}
    insert_event(Repo, row, "effect_recorded", nil, nil, opts[:actor_label], data)
    row
  end

  defp event_value(value) when is_integer(value), do: value
  defp event_value(value), do: to_string(value)

  @doc """
  Makes a story's stage row follow a claim RELEASE, inside the releasing transaction.
  Every path that bumps `stories.claim_epoch` by releasing a claim calls it:

  - `:runner_lost` — `Loopctl.Progress.reclaim_expired_claim/3` (the lease ran out)
  - `:claim_released` — `Loopctl.Progress.unclaim_story/3`,
    `Loopctl.Progress.force_unclaim_story/3`, the reject auto-reset in `Loopctl.Progress`,
    and `Loopctl.BulkOperations`' bulk-reject auto-reset. A separate edge so `runner_lost`
    in `attempts` counts only runners that actually disappeared.

  What happens to the row:

  - in flight (`StageMachine.in_flight_stages/0`) — back to `queued` over `edge`, bound to
    `new_epoch`, the edge counted in `attempts`, and the identities the released holder
    held cleared (`StageMachine.clears/3`). Recorded as `transitioned`.
  - any other stage except `done` and `failed` — the stage stays and the row is rebound to
    `new_epoch`, recorded as `rebound`. The effect a merged or deployed story already had
    cannot be taken back by a release, and a queued, triage-stage or escalated row is not
    held by the released claim; rebinding keeps every one of them advanceable. Left behind
    the story's epoch, it would be refused on every advance with nothing able to move it.
  - `done`, `failed`, or no row — untouched, `{:ok, nil}`.

  The holder of the released claim is fenced either way: it still presents the OLD epoch,
  and `advance/4` and `record_effect/5` refuse that before they look at the row.

  Runs on `AdminRepo` inside the caller's transaction, which already holds the story's row
  lock (the order every writer here takes: story, then stage row), so the release and the
  row commit together or not at all. It takes no connection of its own. Raises outside an
  `AdminRepo` transaction; the explicit `tenant_id` predicate is the only isolation here.
  Also correct on a story already at `pending` (`force_unclaim_story/3`'s idempotent
  branch passes the current epoch), which is how an operator recovers a row stranded by a
  release that predates this function.

  ## Options

  - `:actor_label` — recorded on the event
  """
  @spec follow_release(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          non_neg_integer(),
          :runner_lost | :claim_released,
          keyword()
        ) :: {:ok, StoryStage.t() | nil}
  def follow_release(tenant_id, story_id, new_epoch, edge, opts \\ [])
      when edge in [:runner_lost, :claim_released] do
    unless AdminRepo.in_transaction?(),
      do: raise(ArgumentError, "follow_release/5 runs inside the releasing transaction")

    row = live_row(tenant_id, story_id)

    cond do
      is_nil(row) -> {:ok, nil}
      row.stage in StageMachine.in_flight_stages() -> requeue(row, new_epoch, edge, opts)
      true -> rebind(row, new_epoch, opts)
    end
  end

  @doc """
  Makes a story's stage row follow a CLAIM, inside the claiming transaction
  (`Loopctl.Progress.claim_story/3` and `Loopctl.BulkOperations`' bulk claim).

  A claim bumps `stories.claim_epoch` exactly as a release does, so a row left at the old
  epoch would be refused on every advance with nothing able to move it — a story claimed
  by hand while its row is still at `detected` or `triaged` got stuck there. The row keeps
  its STAGE and takes the new epoch (a `rebound` event); `done` and `failed`, or no row,
  are untouched.

  It never moves a row INTO `claimed`: that transition is the loop's own
  `advance(queued -> claimed)`, which is where the claimed row's chain entry and its
  `runner_id` come from. Rebinding first is what lets that advance present the new epoch
  and match.

  Same repo, transaction and lock rules as `follow_release/5`.

  ## Options

  - `:actor_label` — recorded on the event
  """
  @spec follow_claim(Ecto.UUID.t(), Ecto.UUID.t(), non_neg_integer(), keyword()) ::
          {:ok, StoryStage.t() | nil}
  def follow_claim(tenant_id, story_id, new_epoch, opts \\ []) do
    unless AdminRepo.in_transaction?(),
      do: raise(ArgumentError, "follow_claim/4 runs inside the claiming transaction")

    case live_row(tenant_id, story_id) do
      nil -> {:ok, nil}
      row -> rebind(row, new_epoch, opts)
    end
  end

  # Every row a claim or a release may touch: `done` and `failed` are finished with.
  defp live_row(tenant_id, story_id) do
    from(s in StoryStage,
      where: s.tenant_id == ^tenant_id and s.story_id == ^story_id,
      where: s.stage not in [:done, :failed],
      lock: "FOR UPDATE"
    )
    |> AdminRepo.one()
  end

  defp requeue(%StoryStage{stage: from} = row, new_epoch, edge, opts) do
    true = StageMachine.allowed?(from, :queued, edge)

    {1, [updated]} =
      from(s in StoryStage, where: s.id == ^row.id and s.tenant_id == ^row.tenant_id, select: s)
      |> transition_update(from, :queued, edge, claim_epoch: new_epoch)
      |> AdminRepo.update_all([])

    insert_event(AdminRepo, updated, "transitioned", from, edge, opts[:actor_label], %{
      "released_claim_epoch" => row.claim_epoch
    })

    {:ok, updated}
  end

  # A row already at the new epoch (an idempotent force-unclaim) is left exactly as it is.
  defp rebind(%StoryStage{claim_epoch: epoch}, epoch, _opts), do: {:ok, nil}

  defp rebind(%StoryStage{} = row, new_epoch, opts) do
    {1, [updated]} =
      from(s in StoryStage,
        where: s.id == ^row.id and s.tenant_id == ^row.tenant_id,
        select: s,
        update: [
          set: [claim_epoch: ^new_epoch, updated_at: ^DateTime.utc_now()],
          inc: [lock_version: 1]
        ]
      )
      |> AdminRepo.update_all([])

    insert_event(AdminRepo, updated, "rebound", nil, nil, opts[:actor_label], %{
      "released_claim_epoch" => row.claim_epoch
    })

    {:ok, updated}
  end

  # --- transition mechanics -------------------------------------------------------------

  # The one UPDATE every transition writes, on either repo: the new stage, the identities the
  # edge clears, `attempts` counted in SQL (never read-modify-write), and `lock_version`.
  defp transition_update(query, from, to, edge, extra) do
    clears = Enum.map(StageMachine.clears(from, to, edge), &{&1, nil})
    set = [stage: to, updated_at: DateTime.utc_now()] ++ clears ++ extra

    query = update(query, set: ^set, inc: [lock_version: 1])

    if StageMachine.counted?(edge) do
      name = Atom.to_string(edge)

      update(query, [s],
        set: [
          attempts:
            fragment(
              "jsonb_set(?, ARRAY[?::text], to_jsonb(COALESCE((? ->> ?::text)::bigint, 0) + 1))",
              s.attempts,
              ^name,
              s.attempts,
              ^name
            )
        ]
      )
    else
      query
    end
  end

  defp allowed_for_caller(_from, _to, edge) when edge in [:runner_lost, :claim_released],
    do: {:error, :invalid_transition}

  defp allowed_for_caller(from, to, edge) do
    if StageMachine.allowed?(from, to, edge), do: :ok, else: {:error, :invalid_transition}
  end

  defp human_gate(edge, opts) do
    if StageMachine.human_only?(edge) and not human?(opts),
      do: {:error, :human_required},
      else: :ok
  end

  defp human?(opts) do
    Role.role_at_least?(Keyword.get(opts, :actor_role, :agent), :user) and
      Keyword.get(opts, :actor_lineage, []) == []
  end

  defp reason_given(to, reason) do
    if StageMachine.reason_required?(to) and not present?(reason),
      do: {:error, :reason_required},
      else: :ok
  end

  defp present?(reason), do: is_binary(reason) and String.trim(reason) != ""

  defp note(nil), do: %{}
  defp note(reason), do: %{"reason" => reason}

  defp maybe_chain(row, {from, to, edge}, reason, opts) do
    if StageMachine.chained?(from, to) do
      {:ok, entry} =
        AuditChain.append_in_tenant_transaction(row.tenant_id, %{
          action: chain_action(from, to),
          actor_lineage: Keyword.get(opts, :actor_lineage, []),
          entity_type: "story",
          entity_id: row.story_id,
          payload: %{
            "story_stage_id" => row.id,
            "from" => Atom.to_string(from),
            "to" => Atom.to_string(to),
            "edge" => Atom.to_string(edge),
            "claim_epoch" => row.claim_epoch,
            "lock_version" => row.lock_version,
            "reason" => reason,
            "runner_id" => row.runner_id,
            "pr_number" => row.pr_number,
            "head_sha" => row.head_sha,
            "merge_sha" => row.merge_sha
          }
        })

      entry
    end
  end

  defp chain_action(:escalated, _to), do: "story_stage_escalation_resolved"
  defp chain_action(_from, to), do: "story_stage_" <> Atom.to_string(to)

  # --- effects ------------------------------------------------------------------------------

  defp validate_effect(:runner_id, value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_effect}
    end
  end

  defp validate_effect(:pr_number, value)
       when is_integer(value) and value > 0 and value <= @max_pr_number,
       do: {:ok, value}

  defp validate_effect(sha, value) when sha in [:head_sha, :merge_sha] and is_binary(value) do
    if Regex.match?(@sha, value), do: {:ok, value}, else: {:error, :invalid_effect}
  end

  defp validate_effect(:worktree_path, value), do: bounded_text(value, 4096)
  defp validate_effect(:branch, value), do: bounded_text(value, 255)
  defp validate_effect(:release_id, value), do: bounded_text(value, 255)
  defp validate_effect(_effect, _value), do: {:error, :invalid_effect}

  # Postgres text refuses a NUL; the bounds match the `story_stages_text_bounds` CHECK.
  defp bounded_text(value, max) when is_binary(value) do
    if String.valid?(value) and not String.contains?(value, <<0>>) and
         String.length(value) in 1..max,
       do: {:ok, value},
       else: {:error, :invalid_effect}
  end

  defp bounded_text(_value, _max), do: {:error, :invalid_effect}

  # --- plumbing ----------------------------------------------------------------------------

  # Every stage-row transaction: an RLS transaction this module owns, with local lock and
  # statement timeouts. The body returns `{row, chain_entry | nil}` or rolls back with a
  # reason; a committed chain entry is announced only after the commit.
  defp in_tenant(tenant_id, fun) do
    result =
      Repo.with_tenant(tenant_id, fn ->
        LocalGuc.scoped(Repo, ["lock_timeout", "statement_timeout"], fn ->
          Repo.query!(
            "SELECT set_config('lock_timeout', $1, true), set_config('statement_timeout', $2, true)",
            [@lock_timeout, @statement_timeout]
          )

          fun.()
        end)
      end)

    case result do
      {:ok, {row, nil}} ->
        {:ok, row}

      {:ok, {row, entry}} ->
        AuditChain.announce_entry(entry)
        {:ok, row}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      if busy?(error) do
        Logger.warning(
          "story stage write gave up waiting: tenant_id=#{tenant_id} " <>
            "error=#{inspect(busy_code(error))}"
        )

        :telemetry.execute([:loopctl, :delivery, :stage_busy], %{count: 1}, %{
          tenant_id: tenant_id,
          reason: busy_code(error)
        })

        {:error, :busy}
      else
        reraise(error, __STACKTRACE__)
      end
  end

  # 55P03 lock_not_available (lock_timeout), 57014 query_canceled (statement_timeout), or a
  # connection that could not be checked out in time.
  defp busy?(%Postgrex.Error{postgres: %{pg_code: code}}), do: code in ["55P03", "57014"]
  defp busy?(%DBConnection.ConnectionError{}), do: true
  defp busy?(_error), do: false

  defp busy_code(%Postgrex.Error{postgres: %{pg_code: code}}), do: code
  defp busy_code(%DBConnection.ConnectionError{reason: reason}), do: reason

  # FOR SHARE: a release or a claim (FOR UPDATE on the story) cannot commit between this
  # read of `claim_epoch` and the write it fences. Taken BEFORE the stage row (see moduledoc).
  defp share_lock_story(tenant_id, story_id) do
    from(s in Story,
      where: s.id == ^story_id and s.tenant_id == ^tenant_id,
      lock: "FOR SHARE",
      select: %{id: s.id, claim_epoch: s.claim_epoch, agent_status: s.agent_status}
    )
    |> Repo.one()
    |> case do
      nil -> Repo.rollback(:not_found)
      story -> story
    end
  end

  defp row_query(tenant_id, story_id) do
    from s in StoryStage, where: s.tenant_id == ^tenant_id and s.story_id == ^story_id
  end

  defp fetch_row!(tenant_id, story_id), do: Repo.one!(row_query(tenant_id, story_id))

  defp insert_event(repo, %StoryStage{} = row, event, from, edge, actor_label, data) do
    repo.insert_all(StageEvent, [
      %{
        id: Ecto.UUID.generate(),
        tenant_id: row.tenant_id,
        story_stage_id: row.id,
        story_id: row.story_id,
        event: event,
        from_stage: from && Atom.to_string(from),
        to_stage: Atom.to_string(row.stage),
        edge: edge && Atom.to_string(edge),
        claim_epoch: row.claim_epoch,
        lock_version: row.lock_version,
        actor_label: actor_label,
        data: data,
        inserted_at: DateTime.utc_now()
      }
    ])
  end
end
