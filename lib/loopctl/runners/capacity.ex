defmodule Loopctl.Runners.Capacity do
  @moduledoc """
  Capacity reservation and admission control for the runner pool (issue #803, design §7
  and §9 "Admission control").

  ## Where the state lives

  In Postgres, and only there. `runners.max_sessions` is what a machine was enrolled to
  carry, `runners.in_flight` the slots reserved on it now, and every reservation is one
  `runner_dispatches` row whose `released_at` is NULL. The invariant is

      runners.in_flight = count(runner_dispatches WHERE runner_id AND released_at IS NULL)

  and every write below keeps it inside one transaction. No process owns a counter, so a
  node that dies mid-dispatch leaves nothing behind but a rolled-back transaction.
  Presence carries `max_sessions` and `in_flight` too, as the RUNNER reports them: a hint
  for an operator, never read here, because a CRDT with no compare-and-set cannot hand out
  the last slot to exactly one caller.

  ## Reserve

  `reserve/3` is one conditional UPDATE (`in_flight < max_sessions`, runner not revoked)
  and stamps the dispatch row's `reserved_at` and next `slot_generation`. Two dispatchers
  on two loopctl nodes racing for the last slot both issue it; Postgres row-locks the
  runner, the second re-evaluates the predicate against the first's committed value, and
  exactly one gets a row back.

  ## Admission

  All of a tenant's runners share one Anthropic account, and the account's rate limit is
  what bites on parallel work, so the tenant's TOTAL in-flight sessions are capped as well
  (`limit/0`). `admit/2` sums the active runners' `in_flight` under the transaction-scoped
  advisory lock keyed on the tenant that the caller takes FIRST (`lock_admission!/2`), so two
  admissions in one tenant serialize and the second sees the first's reservation. Chosen over a per-tenant counter row with its own
  compare-and-set because that would be a SECOND counter of the same facts, able to drift
  from the per-runner ones and needing a heal of its own; the sum is over a handful of
  rows. The lock is taken only by admissions, never by a release, which can only lower the
  sum, so a release never waits on it.

  ## Release, exactly once PER SLOT

  A dispatch row can hold several slots over its life: one released because the push never
  reached a socket is taken again when the same `dispatch_id` is re-sent. So a release
  names the `slot_generation` it means, and `release/4` sets `released_at`
  `WHERE released_at IS NULL AND slot_generation = $g`, decrementing only when that write
  matched a row. A release replayed for an earlier generation — a reply re-sent after a
  lost acknowledgement, a supersede found again by a later trace, the heal sweep finding
  what an inline release already did, a caller retrying after the dispatch was re-sent —
  matches nothing and changes nothing. The decrement never goes below zero.

  A slot is released when its dispatch reaches a terminal state the ledger models
  (`refused`, `superseded`), when the channel DROPS it instead of pushing, and on an
  explicit `Loopctl.Runners.release_slot/3` from the caller that learns the session ended.
  The ledger has no completed state, so `heal/3` covers the rest.

  ## Heal

  `heal/3` releases every unreleased reservation of a runner that can no longer be running:

  - its dispatch is `refused` or `superseded`;
  - its story is gone, or its `claim_epoch` moved past the dispatch's (the claim ended);
  - its runner is revoked — including by an api-key revoke, whose trigger revokes the runner
    row without passing through `Loopctl.Runners.revoke_runner/3`;
  - it was never PUSHED under this reservation (`pushed_at` NULL or older than
    `reserved_at`) and `unpushed_grace_seconds/0` has passed. A dispatch is broadcast to a
    channel that pushes it within milliseconds or not at all, so an unpushed reservation is
    an undelivered one — a runner that dropped its socket between the pool read and the
    broadcast. Bounding it by the wall clock instead held a slot for the length of a session
    that never started;
  - its wall clock has run out: the runner stops a session at `wall_clock_seconds`, so past
    the later of its acceptance (or push) plus that plus `release_grace_seconds/0`, the
    session is over whether or not anything said so.

  Then it recomputes `in_flight` from the unreleased rows. That second step is what returns
  a slot taken with `Loopctl.Runners.reserve_slot/2` and never tied to a dispatch.
  `Loopctl.Workers.HealRunnerCapacityWorker` runs it every minute.

  A revoked runner's slots stop counting against the tenant AT ONCE — `admit/2` sums active
  runners only, and `reserve/3` refuses a revoked one — while the rows themselves are
  released by the next heal.

  ## Lock order — one order for the whole fleet

  Every transaction in loopctl that touches more than one of these takes them in THIS order,
  and never in another:

      capacity advisory lock (this module, `admission_lock_namespace/0`)
        -> story row (the claim fence)
        -> runner_dispatches / story_stages row
        -> chain advisory lock (issue #821, its own namespace)
        -> audit-chain head

  and the `runners` row last of all, which only this module writes. **Take the capacity lock
  FIRST in any transaction that also touches a story or the chain, never after** — a
  transaction holding a story and then asking for it closes a cycle with every dispatch,
  which takes it before anything else (`Loopctl.Runners.DispatchLedger.record_sent/3`).

  Two paths used to break this. `record_reply/3` and `record_trace/3` locked the dispatch row
  before fencing the story, which with a concurrent claim release (holding the story
  `FOR UPDATE`) deadlocked in ~1 s — well inside `lock_timeout_ms/0`, so the timeout never
  saw it. And `admit_and_reserve/3` took the advisory lock AFTER the story fence, which
  cycles the same way against a caller that follows the order above. `heal/3` takes dispatch
  rows then the runner row and never a story or advisory lock; its recount holds the runner
  row and only READS dispatch rows.

  Every transaction here that can queue behind another sets `lock_timeout`
  (`lock_timeout_ms/0`). A dispatcher behind a stuck admission gets `:capacity_busy` rather
  than an unbounded wait inside an open transaction; nothing is reserved and it may retry.
  A deadlock is classified the same way (`retryable?/1`) rather than raised: with one order
  it should not happen, and if a future path reintroduces one, a dispatcher retrying beats a
  crashed channel holding a runner's socket.

  ## Partitions

  A runner that disconnects holding a slot keeps it while its session may still be running:
  the wall-clock bound, the claim lease (whose reclaim bumps the epoch) and revocation are
  what end it — never Presence, which drops a silent node's entries after 30 s whether or
  not the machine is still working. A runner that loses loopctl mid-session and is released
  by the wall clock then accepts late is the one case the counter can undercount; the
  runner's own local `max_sessions` (it refuses `at_capacity`) is the backstop there.

  ## Repo

  Every function here runs INSIDE a transaction the CALLER owns; none opens one. It takes
  the repo as its first argument, because a release belongs in whatever transaction is
  already recording the session's end — `Loopctl.Repo` inside `Repo.with_tenant/2` for the
  ledger's own writes, `Loopctl.AdminRepo` for a step of a claim release, which runs there.
  On `Loopctl.Repo` the caller's transaction must already carry the tenant's RLS context, or
  the rows are invisible and nothing is released; on `AdminRepo` the explicit `tenant_id`
  predicate every query below carries is the only scoping. `Loopctl.Runners` wraps these for
  callers that have no transaction of their own.
  """

  import Ecto.Query

  alias Loopctl.Repo
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.Runner
  alias Loopctl.WorkBreakdown.Story

  @default_limit 6
  @lock_timeout_ms 5_000
  @release_grace_seconds 300
  @unpushed_grace_seconds 120

  # `pg_advisory_xact_lock` takes two int4s. The namespace isolates this lock class from
  # every other advisory lock keyed on a tenant (`Loopctl.Egress` uses 0x4105_0001).
  @admission_lock_ns 0x4105_0803

  @doc """
  The most sessions a tenant may have in flight across all its runners
  (`RUNNER_MAX_IN_FLIGHT_SESSIONS`, default #{@default_limit}).
  """
  @spec limit() :: pos_integer()
  def limit do
    case Application.get_env(:loopctl, :runner_max_in_flight_sessions) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_limit
    end
  end

  @doc "How long a capacity transaction waits for a lock before giving up."
  @spec lock_timeout_ms() :: pos_integer()
  def lock_timeout_ms, do: @lock_timeout_ms

  @doc "How long past its wall clock an unreleased reservation is still presumed running."
  @spec release_grace_seconds() :: pos_integer()
  def release_grace_seconds, do: @release_grace_seconds

  @doc """
  How long a reservation whose dispatch was never pushed under it is presumed still on its
  way to a socket.
  """
  @spec unpushed_grace_seconds() :: pos_integer()
  def unpushed_grace_seconds, do: @unpushed_grace_seconds

  @doc "Bounds every lock wait for the rest of the current transaction."
  @spec set_lock_timeout!(Ecto.Repo.t()) :: :ok
  def set_lock_timeout!(repo \\ Repo) do
    repo.query!("SELECT set_config('lock_timeout', $1, true)", ["#{@lock_timeout_ms}ms"])
    :ok
  end

  @doc """
  Whether a `Postgrex.Error` is a lock wait this code should answer with a retryable
  refusal: `lock_timeout` ran out, or Postgres broke a deadlock by choosing this
  transaction. Either way the transaction that raised it is aborted, so a caller rescues it
  OUTSIDE the transaction and nothing it wrote survives.
  """
  @spec retryable?(Exception.t()) :: boolean()
  def retryable?(%Postgrex.Error{postgres: %{code: code}})
      when code in [:lock_not_available, :deadlock_detected],
      do: true

  def retryable?(_error), do: false

  @doc """
  Admission then reservation for `record`, in the caller's transaction: refuses when the
  tenant's active runners already hold `limit/0` slots, then takes a slot on the dispatch's
  runner and stamps the row with it.

  The caller must already hold the tenant's admission lock (`lock_admission!/2`, taken FIRST
  in the transaction — the lock order above) and the dispatch row.
  """
  @spec admit_and_reserve(Ecto.Repo.t(), DispatchRecord.t(), DateTime.t()) ::
          {:ok, DispatchRecord.t()}
          | {:error, :admission_limit_reached | :runner_at_capacity}
  def admit_and_reserve(repo \\ Repo, %DispatchRecord{} = record, now \\ DateTime.utc_now()) do
    with :ok <- admit(repo, record.tenant_id),
         {:ok, _in_flight} <- reserve(repo, record.tenant_id, record.runner_id) do
      {:ok, stamp_reservation(repo, record, now)}
    end
  end

  @doc """
  `:ok` when the tenant's active runners hold fewer than `limit/0` slots. Serialized only
  when the caller holds the admission lock (`admit_and_reserve/3`); unlocked it is a read.
  """
  @spec admit(Ecto.Repo.t(), Ecto.UUID.t()) :: :ok | {:error, :admission_limit_reached}
  def admit(repo \\ Repo, tenant_id) do
    if tenant_in_flight(repo, tenant_id) < limit(),
      do: :ok,
      else: {:error, :admission_limit_reached}
  end

  @doc "The slots a tenant's active runners hold."
  @spec tenant_in_flight(Ecto.Repo.t(), Ecto.UUID.t()) :: non_neg_integer()
  def tenant_in_flight(repo \\ Repo, tenant_id) do
    repo.one(
      from r in Runner,
        where: r.tenant_id == ^tenant_id and is_nil(r.revoked_at),
        select: coalesce(sum(r.in_flight), 0)
    )
  end

  @doc """
  Takes one slot on an active runner that has one free. Returns the runner's new
  `in_flight`. The slot belongs to no dispatch until `admit_and_reserve/3` stamps one, so
  the heal sweep returns a slot taken here on its own.
  """
  @spec reserve(Ecto.Repo.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, pos_integer()} | {:error, :runner_at_capacity}
  def reserve(repo \\ Repo, tenant_id, runner_id) do
    query =
      from r in Runner,
        where: r.id == ^runner_id and r.tenant_id == ^tenant_id,
        where: is_nil(r.revoked_at) and r.in_flight < r.max_sessions,
        select: r.in_flight

    case repo.update_all(query, inc: [in_flight: 1], set: [updated_at: DateTime.utc_now()]) do
      {1, [in_flight]} -> {:ok, in_flight}
      {0, _} -> {:error, :runner_at_capacity}
    end
  end

  # The dispatch row records WHICH slot it now holds. `slot_generation` only ever rises, so
  # a release naming an earlier one can never free this slot.
  defp stamp_reservation(repo, %DispatchRecord{} = record, now) do
    generation = record.slot_generation + 1

    {1, _} =
      from(d in DispatchRecord,
        where: d.id == ^record.id and d.tenant_id == ^record.tenant_id
      )
      |> repo.update_all(
        set: [
          released_at: nil,
          reserved_at: now,
          slot_generation: generation,
          updated_at: now
        ]
      )

    %{record | released_at: nil, reserved_at: now, slot_generation: generation}
  end

  @doc """
  Releases the slot `generation` of a dispatch, exactly once. `:already_released` when that
  generation's slot is already back — a replay, a release naming a slot the row no longer
  holds, or a row the heal got to first.
  """
  @spec release(Ecto.Repo.t(), DispatchRecord.t(), integer(), DateTime.t()) ::
          :released | :already_released
  def release(repo \\ Repo, record, generation, now \\ DateTime.utc_now())

  def release(repo, %DispatchRecord{} = record, generation, now) when is_integer(generation) do
    marked =
      from(d in DispatchRecord,
        where: d.id == ^record.id and d.tenant_id == ^record.tenant_id,
        where: is_nil(d.released_at) and d.slot_generation == ^generation
      )
      |> repo.update_all(set: [released_at: now, updated_at: now])

    case marked do
      {1, _} ->
        give_back(repo, record.tenant_id, record.runner_id, 1)
        :released

      {0, _} ->
        :already_released
    end
  end

  @doc """
  Releases every reservation of `runner_id` that can no longer be running, then sets its
  `in_flight` to the count of the ones left (see the moduledoc). Idempotent.
  """
  @spec heal(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, %{released: non_neg_integer(), in_flight: non_neg_integer() | nil}}
  def heal(tenant_id, runner_id, now \\ DateTime.utc_now()) do
    {released, _ids} =
      now
      |> dead_reservations()
      |> where([d], d.tenant_id == ^tenant_id and d.runner_id == ^runner_id)
      |> Repo.update_all(set: [released_at: now, updated_at: now])

    if released > 0, do: give_back(Repo, tenant_id, runner_id, released)

    {:ok, %{released: released, in_flight: recount(tenant_id, runner_id)}}
  end

  @doc """
  Every unreleased reservation that can no longer be running, fleet-wide, as of `now`. The
  heal scopes it to one runner; `Loopctl.Workers.HealRunnerCapacityWorker` reads it whole to
  find the runners that need one.
  """
  @spec dead_reservations(DateTime.t()) :: Ecto.Query.t()
  def dead_reservations(now) do
    claim_current =
      from s in Story,
        where: s.tenant_id == parent_as(:dispatch).tenant_id,
        where: s.id == parent_as(:dispatch).story_id,
        where: s.claim_epoch == parent_as(:dispatch).claim_epoch,
        select: 1

    runner_active =
      from r in Runner,
        where: r.tenant_id == parent_as(:dispatch).tenant_id,
        where: r.id == parent_as(:dispatch).runner_id,
        where: is_nil(r.revoked_at),
        select: 1

    from d in DispatchRecord,
      as: :dispatch,
      where: is_nil(d.released_at),
      # Never pushed under THIS reservation, and the push had time to happen: a dispatch
      # is broadcast to a channel that pushes it at once or not at all, so an unpushed
      # reservation is an undelivered one.
      # The runner stops a session at its wall clock. Timed from acceptance, else from
      # the push this reservation made, else from the reservation itself.
      where:
        d.status in ["refused", "superseded"] or not exists(claim_current) or
          not exists(runner_active) or
          (d.status == "sent" and (is_nil(d.pushed_at) or d.pushed_at < d.reserved_at) and
             fragment(
               "? + make_interval(secs => ?) < ?",
               d.reserved_at,
               type(^@unpushed_grace_seconds, :integer),
               type(^now, :utc_datetime_usec)
             )) or
          fragment(
            "? + make_interval(secs => ? + ?) < ?",
            coalesce(
              d.replied_at,
              fragment("GREATEST(?, ?)", d.reserved_at, coalesce(d.pushed_at, d.reserved_at))
            ),
            d.wall_clock_seconds,
            type(^@release_grace_seconds, :integer),
            type(^now, :utc_datetime_usec)
          ),
      select: d.id
  end

  # Under the runner's row lock, so a reservation or release racing this commits either
  # before the count (and is in it) or after the write (and applies on top of it). The
  # count is its own statement, so it reads with a snapshot taken after the lock is held.
  defp recount(tenant_id, runner_id) do
    locked =
      Repo.one(
        from r in Runner,
          where: r.id == ^runner_id and r.tenant_id == ^tenant_id,
          lock: "FOR UPDATE",
          select: %{in_flight: r.in_flight, max_sessions: r.max_sessions}
      )

    case locked do
      nil ->
        nil

      %{in_flight: in_flight, max_sessions: max} ->
        write_count(tenant_id, runner_id, in_flight, max)
    end
  end

  defp write_count(tenant_id, runner_id, in_flight, max_sessions) do
    live = Repo.aggregate(unreleased(tenant_id, runner_id), :count)

    # Above `max_sessions` only if the runner was re-enrolled smaller while holding slots;
    # the CHECK would refuse the exact count, and admitting nothing until the rows drain is
    # the same outcome.
    target = min(live, max_sessions)

    if target != in_flight do
      from(r in Runner, where: r.id == ^runner_id and r.tenant_id == ^tenant_id)
      |> Repo.update_all(set: [in_flight: target, updated_at: DateTime.utc_now()])
    end

    target
  end

  @doc "A runner's live reservations."
  @spec unreleased(Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def unreleased(tenant_id, runner_id) do
    from d in DispatchRecord,
      where: d.tenant_id == ^tenant_id and d.runner_id == ^runner_id,
      where: is_nil(d.released_at)
  end

  defp give_back(repo, tenant_id, runner_id, count) do
    from(r in Runner,
      where: r.id == ^runner_id and r.tenant_id == ^tenant_id,
      update: [set: [in_flight: fragment("GREATEST(? - ?, 0)", r.in_flight, ^count)]]
    )
    |> repo.update_all([])
  end

  @doc """
  Serializes a tenant's admissions for the rest of the caller's transaction, on a
  transaction-scoped advisory lock that releases on commit or rollback with no unlock path
  to forget.

  **The FIRST lock of any transaction that admits** — before the story fence, the dispatch
  row and the chain (the lock order above). Taken after a story lock it cycles with every
  dispatch.
  """
  @spec lock_admission!(Ecto.Repo.t(), Ecto.UUID.t()) :: :ok
  def lock_admission!(repo \\ Repo, tenant_id) do
    {:ok, <<key::signed-integer-32, _rest::binary>>} = Ecto.UUID.dump(tenant_id)
    repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@admission_lock_ns, key])
    :ok
  end

  @doc "The advisory-lock namespace admissions serialize on. Public so a test can stage it."
  @spec admission_lock_namespace() :: pos_integer()
  def admission_lock_namespace, do: @admission_lock_ns

  @doc """
  The STABLE signed int4 advisory-lock key for a tenant — the UUID's first four bytes, never
  `:erlang.phash2/1`, whose hashing is not guaranteed stable across OTP releases: during a
  rolling deploy two nodes must agree on the key or they do not serialize at all.
  """
  @spec admission_lock_key(Ecto.UUID.t()) :: integer()
  def admission_lock_key(tenant_id) do
    {:ok, <<key::signed-integer-32, _rest::binary>>} = Ecto.UUID.dump(tenant_id)
    key
  end
end
