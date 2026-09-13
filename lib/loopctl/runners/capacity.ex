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

  `reserve/2` is one conditional UPDATE (`in_flight < max_sessions`, runner not revoked).
  Two dispatchers on two loopctl nodes racing for the last slot both issue it; Postgres
  row-locks the runner, the second re-evaluates the predicate against the first's committed
  value, and exactly one gets a row back.

  ## Admission

  All of a tenant's runners share one Anthropic account, and the account's rate limit is
  what bites on parallel work, so the tenant's TOTAL in-flight sessions are capped as well
  (`limit/0`). `admit/1` sums the active runners' `in_flight` under a transaction-scoped
  advisory lock keyed on the tenant, so two admissions in one tenant serialize and the
  second sees the first's reservation. Chosen over a per-tenant counter row with its own
  compare-and-set because that would be a SECOND counter of the same facts, able to drift
  from the per-runner ones and needing a heal of its own; the sum is over a handful of
  rows. The lock is taken only by admissions, never by a release, which can only lower the
  sum, so a release never waits on it.

  ## Release, exactly once

  `release/2` sets `released_at` with `WHERE released_at IS NULL` and decrements only when
  that write matched a row. A release replayed for the same dispatch — a reply re-sent after
  a lost acknowledgement, a supersede found again by a later trace, the heal sweep finding
  what an inline release already did — matches nothing and changes nothing. The decrement
  never goes below zero.

  A slot is released when its dispatch reaches a terminal state the ledger models:
  `refused` (`DispatchLedger.record_reply/3`), `superseded` (the claim fence), or an explicit
  `Loopctl.Runners.release_slot/2` when the caller learns the session ended. The ledger has
  no completed state, so `heal/3` covers the rest.

  ## Heal

  `heal/3` releases every unreleased reservation of a runner that can no longer be running:

  - its dispatch is `refused` or `superseded`;
  - its story is gone, or its `claim_epoch` moved past the dispatch's (the claim ended);
  - its runner is revoked — including by an api-key revoke, whose trigger revokes the runner
    row without passing through `Loopctl.Runners.revoke_runner/3`;
  - its wall clock has run out: the runner stops a session at `wall_clock_seconds`, so past
    the later of its acceptance (or last push) plus that plus `release_grace_seconds/0`, the
    session is over whether or not anything said so.

  Then it recomputes `in_flight` from the unreleased rows. That second step is what returns
  a slot taken with `Loopctl.Runners.reserve_slot/2` and never tied to a dispatch.
  `Loopctl.Workers.HealRunnerCapacityWorker` runs it every minute.

  A revoked runner's slots stop counting against the tenant AT ONCE — `admit/1` sums active
  runners only, and `reserve/2` refuses a revoked one — while the rows themselves are
  released by the next heal.

  ## Locks and waits

  Lock order is ledger row, then runner row, on every path that holds both (reserve after
  its insert, release, heal's first step). Heal's recount takes the runner row and then only
  READS ledger rows. The advisory lock is taken only before a runner row. So no cycle.

  Every transaction here that can queue behind another sets `lock_timeout`
  (`lock_timeout_ms/0`). A dispatcher behind a stuck admission gets `:capacity_busy` rather
  than an unbounded wait inside an open transaction; nothing is reserved and it may retry.

  ## Partitions

  A runner that disconnects holding a slot keeps it: its session may still be running, and
  the heal's wall-clock bound, the claim lease (whose reclaim bumps the epoch) and revocation
  are what end it — never Presence, which drops a silent node's entries after 30 s whether
  or not the machine is still working. A runner that loses loopctl mid-session and is
  released by the wall clock then accepts late is the one case the counter can undercount;
  the runner's own local `max_sessions` (it refuses `at_capacity`) is the backstop there.

  Every function here runs INSIDE a `Loopctl.Repo` transaction whose tenant context is set
  (`Repo.with_tenant/2`); none opens one. `Loopctl.Runners` wraps them for callers.
  """

  import Ecto.Query

  alias Loopctl.Repo
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.Runner
  alias Loopctl.WorkBreakdown.Story

  @default_limit 6
  @lock_timeout_ms 5_000
  @release_grace_seconds 300

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

  @doc "Bounds every lock wait for the rest of the current transaction."
  @spec set_lock_timeout!() :: :ok
  def set_lock_timeout! do
    Repo.query!("SELECT set_config('lock_timeout', $1, true)", ["#{@lock_timeout_ms}ms"])
    :ok
  end

  @doc """
  Whether a `Postgrex.Error` is a lock wait that ran out of `lock_timeout`. The transaction
  that raised it is aborted, so a caller rescues it OUTSIDE the transaction.
  """
  @spec lock_timeout?(Exception.t()) :: boolean()
  def lock_timeout?(%Postgrex.Error{postgres: %{code: :lock_not_available}}), do: true
  def lock_timeout?(_error), do: false

  @doc """
  Admission then reservation, in the caller's transaction: serializes the tenant's
  admissions, refuses when its active runners already hold `limit/0` slots, then reserves
  one on `runner_id`.
  """
  @spec admit_and_reserve(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, non_neg_integer()} | {:error, :admission_limit_reached | :runner_at_capacity}
  def admit_and_reserve(tenant_id, runner_id) do
    lock_admission!(tenant_id)

    with :ok <- admit(tenant_id) do
      reserve(tenant_id, runner_id)
    end
  end

  @doc """
  `:ok` when the tenant's active runners hold fewer than `limit/0` slots. Serialized only
  when the caller holds the admission lock (`admit_and_reserve/2`); unlocked it is a read.
  """
  @spec admit(Ecto.UUID.t()) :: :ok | {:error, :admission_limit_reached}
  def admit(tenant_id) do
    if tenant_in_flight(tenant_id) < limit(), do: :ok, else: {:error, :admission_limit_reached}
  end

  @doc "The slots a tenant's active runners hold."
  @spec tenant_in_flight(Ecto.UUID.t()) :: non_neg_integer()
  def tenant_in_flight(tenant_id) do
    Repo.one(
      from r in Runner,
        where: r.tenant_id == ^tenant_id and is_nil(r.revoked_at),
        select: coalesce(sum(r.in_flight), 0)
    )
  end

  @doc """
  Takes one slot on an active runner that has one free. Returns the runner's new
  `in_flight`.
  """
  @spec reserve(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, pos_integer()} | {:error, :runner_at_capacity}
  def reserve(tenant_id, runner_id) do
    query =
      from r in Runner,
        where: r.id == ^runner_id and r.tenant_id == ^tenant_id,
        where: is_nil(r.revoked_at) and r.in_flight < r.max_sessions,
        select: r.in_flight

    case Repo.update_all(query, inc: [in_flight: 1], set: [updated_at: DateTime.utc_now()]) do
      {1, [in_flight]} -> {:ok, in_flight}
      {0, _} -> {:error, :runner_at_capacity}
    end
  end

  @doc """
  Releases the slot a dispatch holds, exactly once. `:already_released` for a dispatch
  whose slot is already back — a replay, or a row the heal got to first.
  """
  @spec release(DispatchRecord.t(), DateTime.t()) :: :released | :already_released
  def release(%DispatchRecord{} = record, now \\ DateTime.utc_now()) do
    marked =
      from(d in DispatchRecord,
        where: d.id == ^record.id and d.tenant_id == ^record.tenant_id,
        where: is_nil(d.released_at)
      )
      |> Repo.update_all(set: [released_at: now])

    case marked do
      {1, _} ->
        give_back(record.tenant_id, record.runner_id, 1)
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
      tenant_id
      |> dead_reservations(runner_id, now)
      |> Repo.update_all(set: [released_at: now])

    if released > 0, do: give_back(tenant_id, runner_id, released)

    {:ok, %{released: released, in_flight: recount(tenant_id, runner_id)}}
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

      %{in_flight: in_flight, max_sessions: max_sessions} ->
        live =
          Repo.aggregate(
            from(d in DispatchRecord,
              where: d.tenant_id == ^tenant_id and d.runner_id == ^runner_id,
              where: is_nil(d.released_at)
            ),
            :count
          )

        # Above `max_sessions` only if the runner was re-enrolled smaller while holding
        # slots; the CHECK would refuse the exact count, and admitting nothing until the
        # rows drain is the same outcome.
        target = min(live, max_sessions)

        if target != in_flight do
          from(r in Runner, where: r.id == ^runner_id and r.tenant_id == ^tenant_id)
          |> Repo.update_all(set: [in_flight: target, updated_at: DateTime.utc_now()])
        end

        target
    end
  end

  defp give_back(tenant_id, runner_id, count) do
    from(r in Runner,
      where: r.id == ^runner_id and r.tenant_id == ^tenant_id,
      update: [set: [in_flight: fragment("GREATEST(? - ?, 0)", r.in_flight, ^count)]]
    )
    |> Repo.update_all([])
  end

  defp dead_reservations(tenant_id, runner_id, now) do
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
      where: d.tenant_id == ^tenant_id and d.runner_id == ^runner_id,
      where: is_nil(d.released_at),
      where:
        d.status in ["refused", "superseded"] or not exists(claim_current) or
          not exists(runner_active) or
          fragment(
            "? + make_interval(secs => ? + ?) < ?",
            coalesce(d.replied_at, coalesce(d.pushed_at, d.inserted_at)),
            d.wall_clock_seconds,
            type(^@release_grace_seconds, :integer),
            type(^now, :utc_datetime_usec)
          ),
      select: d.id
  end

  defp lock_admission!(tenant_id) do
    {:ok, <<key::signed-integer-32, _rest::binary>>} = Ecto.UUID.dump(tenant_id)
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@admission_lock_ns, key])
    :ok
  end
end
