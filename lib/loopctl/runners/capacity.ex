defmodule Loopctl.Runners.Capacity do
  @moduledoc """
  Capacity reservation and admission control for the runner pool (issue #803, design §7
  and §9 "Admission control").

  ## Where the state lives

  In Postgres, and only there. `runners.max_sessions` is how many slots loopctl will reserve
  on a machine — the machine's OWN declaration re-applied from the join payload on every
  connect, CAPPED at `runners.enrolled_max_sessions`, the grant an operator made at
  enrollment and no join ever writes (`apply_declared/5`) — `runners.in_flight` the slots
  reserved on it now, and every reservation is one `runner_dispatches` row whose
  `released_at` is NULL. The invariant is

      runners.in_flight = count(runner_dispatches WHERE runner_id AND released_at IS NULL)

  and every write below keeps it inside one transaction. No process owns a counter, so a
  node that dies mid-dispatch leaves nothing behind but a rolled-back transaction.

  It holds with ONE deliberate exception: `apply_declared/5` clamps `in_flight` DOWN when a
  machine rejoins declaring fewer sessions than it currently holds, because
  `runners_in_flight_range` makes the honest count unrepresentable there. The counter is then
  SHORT of the rows until they drain.

  What each writer does about that gap:

  * `reserve/3` INCREMENTS, under the predicate `in_flight < max_sessions`. On the dispatch
    path both sides of the count move together, because the ledger clears the dispatch row's
    `released_at` in the same transaction, so the gap is unchanged. Taken on
    its own through `Loopctl.Runners.reserve_slot/2` it leaves the counter ABOVE the live
    rows instead, which is the untied slot a recount reclaims.
  * `release/4` RECOUNTS (`give_back/3`) instead of decrementing. A decrement is the right
    answer only while `in_flight = count(unreleased)` holds, so from a clamped row it frees a
    slot a session still holds; a recount converges from any drifted value.
  * `apply_declared/5` clamps inside its own statement and then RECOUNTS. The clamp only ever
    LOWERS, so a machine that rejoins declaring MORE — reverting a configuration change, say
    — used to keep the short counter while its ceiling went back up, and `reserve/3` handed
    out a slot the machine was already using.
  * `heal/3` recounts too, after releasing the reservations that can no longer be running.

  Presence carries `max_sessions` and `in_flight` too, as the RUNNER reports them, and
  nothing here ever reads them: a CRDT with no compare-and-set cannot hand out the last slot
  to exactly one caller. The runner's `max_sessions` is not merely a hint, though — it is
  copied into the row on every join, bounded by the enrolled grant, so that every decision
  below is still taken on one counter under a row lock. `in_flight` stays a hint: the
  runner's count is of sessions it is running, loopctl's is of slots it has handed out, and
  only the second can decide the next.

  ## Reserve

  `reserve/3` is one conditional UPDATE (`in_flight < max_sessions`, runner not revoked)
  and stamps the dispatch row's `reserved_at` and next `slot_generation`. Two dispatchers
  on two loopctl nodes racing for the last slot both issue it; Postgres row-locks the
  runner, the second re-evaluates the predicate against the first's committed value, and
  exactly one gets a row back.

  ## Admission

  All of a tenant's runners share one Anthropic account, and the account's rate limit is
  what bites on parallel work, so the tenant's TOTAL in-flight sessions are capped as well
  (`limit/0`). `admit/2` sums the active runners' load under the transaction-scoped
  advisory lock keyed on the tenant that the caller takes FIRST (`lock_admission!/2`), so two
  admissions in one tenant serialize and the second sees the first's reservation. Chosen over a per-tenant counter row with its own
  compare-and-set because that would be a SECOND counter of the same facts, able to drift
  from the per-runner ones and needing a heal of its own; the sum is over a handful of
  rows. The lock is taken only by admissions, never by a release, which can only lower the
  sum, so a release never waits on it.

  Each runner's contribution is the GREATER of its `in_flight` and its live reservations,
  because `in_flight` is deliberately short of the truth after the clamp below and the live
  count is short of it for a slot `Loopctl.Runners.reserve_slot/2` tied to no dispatch. See
  `tenant_in_flight/2`.

  ## Release, exactly once PER SLOT

  A dispatch row can hold several slots over its life: one released because the push never
  reached a socket is taken again when the same `dispatch_id` is re-sent. So a release
  names the `slot_generation` it means, and `release/4` sets `released_at`
  `WHERE released_at IS NULL AND slot_generation = $g`, recounting the runner's slots only
  when that write matched a row. A release replayed for an earlier generation — a reply
  re-sent after a lost acknowledgement, a supersede found again by a later trace, the heal
  sweep finding what an inline release already did, a caller retrying after the dispatch was
  re-sent — matches nothing and changes nothing, because the recount that follows a matched
  write is not reached at all.

  The release does not DECREMENT: it recounts the runner's unreleased rows under the row
  lock and writes `min(live, max_sessions)` (`give_back/3`). A decrement is the right answer
  only while the invariant above holds, and `apply_declared/5` breaks it deliberately when a
  machine rejoins declaring fewer sessions than it currently holds.

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
  - it was never DELIVERED under this reservation (`delivery` is not `"pushed"`) and
    `unpushed_grace_seconds/0` has passed. A dispatch reaches a socket within milliseconds of
    its broadcast or not at all, so an undelivered reservation is one whose runner dropped
    its socket between the pool read and the broadcast;
  - it was PUSHED and never answered: `reply_grace_seconds/0` past the push with `replied_at`
    still nil. A runner answers every dispatch it validated, so silence past that grace means
    the push did not land (a stamp whose commit ack was lost, a channel that died between the
    two) or the runner is gone. Bounded by the wall clock instead, a slot pinned by a push
    that never happened waited out a whole session;
  - its wall clock has run out: the runner stops a session at `wall_clock_seconds`, so past
    its acceptance plus that plus `release_grace_seconds/0` the session is over whether or
    not anything said so.

  Then it recomputes `in_flight` from the unreleased rows. That second step is what returns
  a slot taken with `Loopctl.Runners.reserve_slot/2` and never tied to a dispatch.
  `Loopctl.Workers.HealRunnerCapacityWorker` runs it every minute.

  A revoked runner's slots stop counting against the tenant AT ONCE — `admit/2` sums active
  runners only, and `reserve/3` refuses a revoked one — while the rows themselves are
  released by the next heal.

  ## Lock order — one order for the whole fleet

  Every transaction in loopctl that touches more than one of these takes them in THIS order,
  and never in another:

      capacity advisory lock (0x41050803)
        -> story row
        -> runner_dispatches / story_stages row
        -> runners row
        -> chain advisory lock (0x4105A1D7)
        -> audit-chain head

  **Take the capacity lock FIRST in any transaction that also touches a story or the chain,
  never after** — a transaction holding a story and then asking for it closes a cycle with
  every dispatch, which takes it before anything else
  (`Loopctl.Runners.DispatchLedger.record_sent/3`).

  **And the chain append is always LAST** (corrected in the #824 review). This table put the
  `runners` row after the chain until then, and it was wrong about the fleet as it stands:
  `Loopctl.Runners.revoke_runner/3` locks the `runners` row and THEN appends
  (`lock_runner` -> `mark_revoked` -> `:audit`), and so does the session-end slot release in
  `Loopctl.Delivery.Stages`. Nothing anywhere takes the chain first and a `runners` row
  second, so the TABLE moved rather than the code. Keeping the chain last is also what makes
  the order safe to extend: the tenant's chain head is the row every writer in the tenant
  contends on, so it is the one to hold for the shortest time.

  **What an operator sees because the capacity lock is first:** a claim release sitting on a
  story makes every dispatch in that tenant queue behind it, and past `lock_timeout_ms/0`
  each falls out as `:capacity_busy` with nothing reserved. That is the deliberate trade —
  a bounded queue and a retryable refusal instead of a deadlock — and a burst of
  `:capacity_busy` in one tenant means a long-held story lock, not a capacity shortage.

  Two paths used to break this. `record_reply/3` and `record_trace/3` locked the dispatch row
  before fencing the story, which with a concurrent claim release (holding the story
  `FOR UPDATE`) deadlocked in ~1 s — well inside `lock_timeout_ms/0`, so the timeout never
  saw it. And `admit_and_reserve/3` took the advisory lock AFTER the story fence, which
  cycles the same way against a caller that follows the order above. `heal/3` takes dispatch
  rows then the runner row and never a story or advisory lock; its recount holds the runner
  row and only READS dispatch rows.

  `release/4` is now the SAME shape and for the same reason: since it recounts instead of
  decrementing (`give_back/3`) it marks its dispatch row, then locks the runner row, then
  COUNTS the runner's unreleased rows. That count is a plain read taking no row locks, so it
  cannot close a cycle with a reserve holding a dispatch row — which is what keeps the added
  statement inside the one order. `reserve/3` runs the other way round, runner row then
  dispatch row, and is safe because its caller already holds BOTH the tenant's admission lock
  and the dispatch row before it starts (`admit_and_reserve/3`).

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
  @reply_grace_seconds 120

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
  How long a reservation whose dispatch was never delivered under it is presumed still on its
  way to a socket.
  """
  @spec unpushed_grace_seconds() :: pos_integer()
  def unpushed_grace_seconds, do: @unpushed_grace_seconds

  @doc """
  How long a PUSHED dispatch may go unanswered before its slot is presumed free. A runner
  answers every dispatch it validated, so this bounds a push that never landed.
  """
  @spec reply_grace_seconds() :: pos_integer()
  def reply_grace_seconds, do: @reply_grace_seconds

  @doc """
  How long a caller told `:capacity_busy` waits before sending the same message again.
  Longer than `lock_timeout_ms/0` on purpose: retrying at exactly the wait that just ran out
  puts the caller back in the same queue with no backoff, spending about half its time
  blocked.
  """
  @spec busy_retry_ms() :: pos_integer()
  def busy_retry_ms, do: 3 * @lock_timeout_ms

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

  @doc """
  The slots a tenant's active runners hold: per runner, the GREATER of its counter and its
  live reservations, summed.

  ## Why it is not just `SUM(in_flight)` (#846.4 review round 2, finding 2)

  Neither number alone is the tenant's true load, because each is knowingly short in one
  direction:

  * `in_flight` is short after `apply_declared/5` CLAMPS it. A machine holding 3 that rejoins
    declaring 1 is left at `in_flight: 1` with three unreleased rows, and `write_count/5` pins
    the counter at `min(live, max_sessions)` so the gap persists until those sessions drain.
    That break is correct for `reserve/3` — the machine takes no new work, which is what it
    asked for — and it is WRONG here, because `admit/2` is a cap on what the tenant may run
    at once, and those 3 sessions are running. Summed raw, one runner could lower the tenant's
    visible load by up to 63 and let `RUNNER_MAX_IN_FLIGHT_SESSIONS` be exceeded by that much
    for as long as the extra sessions ran. `heal/3` cannot recover it: `min(3, 1) = 1` equals
    the drifted value, so the drift is stable rather than transient. This became reachable
    when capacity started following the declaration; before that, the only route to
    `live > max` was re-enrolment at a smaller value, which creates a NEW row.
  * the live count is short for a slot taken with `Loopctl.Runners.reserve_slot/2`, which
    increments the counter and ties it to no dispatch row at all.

  The greater of the two is therefore the honest answer to "how many sessions is this
  tenant running", and it equals both of them wherever the module's invariant holds — which
  is everywhere except the two cases above.

  Taken as one LEFT JOIN grouped per runner, with the `max/2` applied in Elixir over the
  handful of rows the moduledoc already counted on. `runner_dispatches_unreleased_idx`
  (`(tenant_id, runner_id) WHERE released_at IS NULL`) is the index that covers the joined
  side.
  """
  @spec tenant_in_flight(Ecto.Repo.t(), Ecto.UUID.t()) :: non_neg_integer()
  def tenant_in_flight(repo \\ Repo, tenant_id) do
    from(r in Runner,
      left_join: d in DispatchRecord,
      on: d.tenant_id == r.tenant_id and d.runner_id == r.id and is_nil(d.released_at),
      where: r.tenant_id == ^tenant_id and is_nil(r.revoked_at),
      group_by: [r.id, r.in_flight],
      select: {r.in_flight, count(d.id)}
    )
    |> repo.all()
    |> Enum.reduce(0, fn {counter, live}, total -> total + max(counter, live) end)
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

  @doc """
  Sets an active runner's held `max_sessions` to the capacity its machine DECLARED, BOUNDED
  BY the capacity it was ENROLLED with, in one conditional UPDATE, then RECOUNTS `in_flight`.
  Returns `{:ok, %{max_sessions: m, in_flight: f}}` with the values after both, or
  `:unchanged` when the predicate matched nothing.

  `only_lower: true` narrows that predicate to a write that takes the held capacity DOWN; a
  declaration that would raise it answers `:unchanged`. See "a write whose CURRENCY the caller
  cannot establish" below.

  `declared` must already be inside `Runner.max_sessions_range/0` — the caller validates it
  (`Loopctl.Runners.declared_max_sessions/1`), because a value this column cannot hold is a
  fact about the CONTRACT's domain and not about one runner's row.

  ## The enrolled value is a CEILING, so a machine may lower itself and never raise itself

  The held number is `LEAST(declared, enrolled_max_sessions)`, never the declaration alone.
  The machine owns the fact and is believed DOWNWARD without argument; upward it is bounded
  by the grant an operator made at enrollment, which `runners.enrolled_max_sessions` keeps
  and no join ever writes.

  Two reasons, and the second is the one that makes it a rule rather than a taste:

  1. **The asymmetry says take the minimum.** Holding more than a machine can run places a
     dispatch it refuses `at_capacity`, and that refusal costs the story's claim and parks it
     (`Loopctl.Delivery.Placement`). Holding less only under-uses the machine until it
     reconnects. When a disagreement can only be expensive in one direction, take the side
     that cannot be expensive — which is the smaller number, whichever side said it.
  2. **Without it a runner can enlarge its own share of the tenant's admission budget.**
     `admit/2` caps a tenant's TOTAL in-flight sessions, and `DispatchDriver` keeps choosing
     the machine with room. A compromised or misconfigured runner declaring 64 therefore
     absorbs the budget once the honest machines are full, and every dispatch it wins carries
     story content and a freshly minted ephemeral key. Before capacity followed the
     declaration at all, a runner could not enlarge its own share; the ceiling is what keeps
     that true.

  An operator who wants a machine to carry MORE than its grant REVOKES it and enrolls it
  again — there is no endpoint that raises `enrolled_max_sessions` on a live row,
  deliberately, because such an endpoint is a second way to widen a security bound and wants
  its own change. The revoke is not optional: `runners_active_name_uidx` is partial on
  `revoked_at IS NULL`, so the same machine name cannot hold two active runners. See
  `Loopctl.Runners.enroll_runner/3` for what that costs the operator.

  ## Why the predicate carries `max_sessions != LEAST(declared, enrolled)`

  A runner re-declares the same number on every reconnect, so the overwhelmingly common
  call has nothing to write. Without the predicate each one still takes the `runners` row's
  lock — the row every dispatch in the tenant contends on — for the length of a no-op. With
  it, an unchanged capacity touches no row and returns `:unchanged`. It compares the value
  that will actually be WRITTEN rather than the raw declaration, so a machine declaring above
  its ceiling on every join is a no-op too instead of rewriting the same clamped number for
  ever. A runner that is gone or revoked answers `:unchanged` as well: its capacity decides
  nothing, and `reserve/3` refuses it on its own.

  ## `only_lower: true` — a write whose CURRENCY the caller cannot establish (#846.4 review round 3, finding 5)

  With it the predicate becomes `max_sessions > LEAST(declared, enrolled)`, so the call can
  only take the held capacity DOWN and answers `:unchanged` for anything that would raise it.

  It exists for the retry in `LoopctlWeb.RunnerChannel`, which re-applies a declaration its
  own connection carried and may by then be the older of two — a second socket can have
  joined, written a smaller number and gone again between two 30-second rechecks, and no
  liveness check made at the moment of the retry can see a connection that is already over.
  What the caller can say is which DIRECTION is safe when it does not know: the module's
  asymmetry (see above) says holding more than a machine can run places a dispatch it refuses
  `at_capacity` and costs the story's claim, while holding less only under-uses it. So an
  uncertain write is allowed to be wrong only in the cheap direction.

  This costs the retry nothing it was for. The state it exists to repair is a row left holding
  a LARGER stale number while the machine has declared a smaller one — "until it lands, the
  machine is dispatchable against the stale number" — and that repair is a lowering. What it
  gives up is a retried RAISE: a machine whose declaration went up and whose join write failed
  stays under-used until it reconnects.

  ## Why `in_flight` is clamped in the SAME statement, and why the clamp is SAFE ONLY because releases recount

  `runners_in_flight_range` CHECKs `in_flight <= max_sessions`, so lowering capacity under
  the slots a machine currently holds is unrepresentable and a bare write would raise.

  The clamp BREAKS the module's counter invariant on purpose, and this is the one place in
  the module where `in_flight = count(unreleased)` is knowingly false: a runner rejoining at
  1 while holding 2 live dispatches is left at `in_flight: 1` with two unreleased rows. That
  is representable and correct as a RUNNER admission decision — `reserve/3`'s
  `in_flight < max_sessions` is false, so the machine takes no new work until its live
  dispatches drain, which is what a machine declaring fewer sessions is asking for.

  It is NOT correct for the TENANT's budget, and that half is bounded elsewhere rather than
  accepted (#846.4 review round 2, finding 2). `admit/2` caps what the tenant may run at once
  and those 2 sessions ARE running, so a counter summed raw would have let the tenant admit
  one more than `RUNNER_MAX_IN_FLIGHT_SESSIONS` allows for every slot a single machine hid —
  up to 63 of them, for as long as the extra sessions ran, and stably, since `heal/3`'s
  `min(2, 1) = 1` equals the drifted value. `tenant_in_flight/2` therefore takes each runner's
  load as the greater of `in_flight` and `count(unreleased)` — and the second is this clamp's
  own live rows. So
  the break is scoped to exactly the decision it is right for; nothing downstream has to know
  the counter can be short.

  It is only safe because the release path RECOUNTS (`give_back/3`) instead of decrementing.
  A decrementing release took that row to `in_flight: 0` the moment the FIRST of the two
  sessions ended, while the second was still running, and `reserve/3` then handed out a slot
  on a machine already running its declared maximum — reinstating the over-dispatch this
  whole path exists to end. `heal/3` did not rescue it either: `write_count/5` computes
  `min(live, max_sessions) = min(2, 1) = 1`, which EQUALS the drifted counter, so the drift
  was a stable state rather than a transient one. The `give_back/3` doc carries the rest.

  ## Why a RECOUNT follows the statement (#846.4 review round 3, finding 1)

  `LEAST(in_flight, LEAST(declared, enrolled))` only ever LOWERS, so the clamp on its own says
  nothing about a declaration that goes back UP while the clamped sessions are still running.
  That is a reachable sequence, not a hypothetical, and it is the one the contract's own
  promise walks into — "lowering it below the sessions loopctl currently holds sends no more
  work until those drain, rather than cancelling them":

      machine holds 2, rejoins declaring 1  -> max_sessions 1, in_flight 1, 2 unreleased rows
      operator reverts the configuration
      machine rejoins declaring 2           -> max_sessions 2, in_flight STILL 1, live 2

  `reserve/3` gates on `in_flight < max_sessions`, so at `1 < 2` it hands out a THIRD slot on
  a machine already running its declared maximum. `heal/3` closes it within the minute, and
  the dispatch that went out in the meantime is already on the machine.

  So the statement is followed by `recount/3` — the same one `give_back/3` and `heal/3` run,
  under the same argument about the lock order. It writes `min(count(unreleased),
  max_sessions)`, which is `min(2, 2) = 2` above and leaves every other case exactly where the
  clamp left it: on a LOWER the count is `min(2, 1) = 1`, which the clamp already wrote, so
  there is nothing to write.

  It COULD have been folded into the statement instead — a correlated `count(*)` over the
  unreleased rows would make `LEAST(GREATEST(in_flight, live), new_max)` a single expression,
  and `runners_in_flight_range` would be satisfied by it. Reusing `recount/3` is preferred
  because it keeps ONE spelling of the recount in the module: a second one in SQL would have
  to be kept in step with `write_count/5` by hand, and the two disagreeing is a drift nothing
  would report. The clamp itself stays in the statement and is not optional there — the CHECK
  is evaluated per statement, so a bare write of the new `max_sessions` under the live count
  raises before any later recount could run.

  The lock order is the one `give_back/3` documents and is not extended here: the UPDATE takes
  the `runners` row, and the recount then re-takes that same row (already held, in the caller's
  transaction) and COUNTS dispatch rows, which is a plain read taking no row locks.

  The cost is one `SELECT count(*)` on a join that MOVES the capacity, and none on the rest —
  which is most of them, since the predicate above answers `:unchanged` for the re-declaration
  that arrives on every reconnect.
  """
  @spec apply_declared(Ecto.Repo.t(), Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), keyword()) ::
          {:ok, %{max_sessions: pos_integer(), in_flight: non_neg_integer()}} | :unchanged
  def apply_declared(repo \\ Repo, tenant_id, runner_id, declared, opts \\ [])
      when is_integer(declared) and declared > 0 do
    query =
      from r in Runner,
        where: r.id == ^runner_id and r.tenant_id == ^tenant_id,
        where: is_nil(r.revoked_at),
        where: ^moves_capacity(declared, Keyword.get(opts, :only_lower, false)),
        update: [
          set: [
            max_sessions: fragment("LEAST(?, ?)", ^declared, r.enrolled_max_sessions),
            in_flight:
              fragment(
                "LEAST(?, LEAST(?, ?))",
                r.in_flight,
                ^declared,
                r.enrolled_max_sessions
              )
          ]
        ],
        select: %{max_sessions: r.max_sessions, in_flight: r.in_flight}

    case repo.update_all(query, set: [updated_at: DateTime.utc_now()]) do
      {1, [held]} -> {:ok, %{held | in_flight: recounted(repo, tenant_id, runner_id, held)}}
      {0, _} -> :unchanged
    end
  end

  # `!=` writes in whichever direction the declaration moved; `>` writes only downward. Both
  # compare the value that would actually be WRITTEN, so a declaration above the enrolled
  # ceiling is judged at the ceiling rather than raw.
  defp moves_capacity(declared, false) do
    dynamic([r], r.max_sessions != fragment("LEAST(?, ?)", ^declared, r.enrolled_max_sessions))
  end

  defp moves_capacity(declared, true) do
    dynamic([r], r.max_sessions > fragment("LEAST(?, ?)", ^declared, r.enrolled_max_sessions))
  end

  # The row is locked by the UPDATE that just matched it, in this transaction, so `recount/3`
  # finds it; the `nil` clause is the shape of its return and not a state reachable from here.
  defp recounted(repo, tenant_id, runner_id, held) do
    recount(repo, tenant_id, runner_id) || held.in_flight
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
          # A NEW slot has no delivery decision yet, whatever the last one ended as.
          delivery: nil,
          updated_at: now
        ]
      )

    %{record | released_at: nil, reserved_at: now, slot_generation: generation, delivery: nil}
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
        give_back(repo, record.tenant_id, record.runner_id)
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

    # No `give_back/3` here any more: it recounts, and `recount/2` below is that same
    # statement. Releasing the rows and then counting what is left is the whole of the heal.
    {:ok, %{released: released, in_flight: recount(tenant_id, runner_id)}}
  end

  # Never DELIVERED under this reservation, and delivery had time to happen: a dispatch
  # reaches a socket within milliseconds of its broadcast (`delivery` is the one decision,
  # taken under the row lock) or not at all.
  defmacrop undelivered_too_long(dispatch, now) do
    quote do
      (is_nil(unquote(dispatch).delivery) or unquote(dispatch).delivery != "pushed") and
        fragment(
          "? + make_interval(secs => ?) < ?",
          unquote(dispatch).reserved_at,
          type(^unquote(@unpushed_grace_seconds), :integer),
          type(unquote(now), :utc_datetime_usec)
        )
    end
  end

  # Pushed and never answered. A runner answers every dispatch it validated, so silence past
  # the grace means the push did not land or the runner is gone.
  defmacrop unanswered_too_long(dispatch, now) do
    quote do
      unquote(dispatch).delivery == "pushed" and is_nil(unquote(dispatch).replied_at) and
        fragment(
          "? + make_interval(secs => ?) < ?",
          coalesce(unquote(dispatch).pushed_at, unquote(dispatch).reserved_at),
          type(^unquote(@reply_grace_seconds), :integer),
          type(unquote(now), :utc_datetime_usec)
        )
    end
  end

  # An accepted session ends at the runner's own wall clock. A resume may re-push a SHORTER
  # clock while the session the first frame started is still running under the longer one, so
  # the bound is the largest clock this dispatch was ever pushed with — the same value the
  # claim's lease re-anchor uses — never merely the latest.
  defmacrop wall_clock_over(dispatch, now) do
    quote do
      not is_nil(unquote(dispatch).replied_at) and
        fragment(
          "? + make_interval(secs => coalesce(?, ?) + ?) < ?",
          unquote(dispatch).replied_at,
          unquote(dispatch).wall_clock_seconds_max,
          unquote(dispatch).wall_clock_seconds,
          type(^unquote(@release_grace_seconds), :integer),
          type(unquote(now), :utc_datetime_usec)
        )
    end
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
          not exists(runner_active) or undelivered_too_long(d, ^now) or
          unanswered_too_long(d, ^now) or wall_clock_over(d, ^now),
      select: d.id
  end

  # Under the runner's row lock, so a reservation or release racing this commits either
  # before the count (and is in it) or after the write (and applies on top of it). The
  # count is its own statement, so it reads with a snapshot taken after the lock is held.
  defp recount(repo \\ Repo, tenant_id, runner_id) do
    locked =
      repo.one(
        from r in Runner,
          where: r.id == ^runner_id and r.tenant_id == ^tenant_id,
          lock: "FOR UPDATE",
          select: %{in_flight: r.in_flight, max_sessions: r.max_sessions}
      )

    case locked do
      nil ->
        nil

      %{in_flight: in_flight, max_sessions: max} ->
        write_count(repo, tenant_id, runner_id, in_flight, max)
    end
  end

  defp write_count(repo, tenant_id, runner_id, in_flight, max_sessions) do
    live = repo.aggregate(unreleased(tenant_id, runner_id), :count)

    # Above `max_sessions` when the machine rejoined declaring fewer sessions than it holds
    # (`apply_declared/5`) or was re-enrolled smaller; the CHECK would refuse the exact
    # count, and admitting nothing until the rows drain is the same outcome. This `min/2` is
    # what keeps a release from freeing a slot a session still holds: at `live > max` the
    # released row lowers `live` and the answer stays pinned at `max`, so `reserve/3` sees
    # no room until the machine is genuinely under its declared capacity.
    target = min(live, max_sessions)

    if target != in_flight do
      from(r in Runner, where: r.id == ^runner_id and r.tenant_id == ^tenant_id)
      |> repo.update_all(set: [in_flight: target, updated_at: DateTime.utc_now()])
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

  # A RELEASE RECOUNTS; IT DOES NOT DECREMENT (#846.4 review finding 1). The caller has just
  # marked one or more ledger rows released, so the answer this owes is the same one
  # `write_count/5` gives everywhere else: `min(count(unreleased), max_sessions)`.
  #
  # It used to be `GREATEST(in_flight - n, 0)`, which is the right answer ONLY while
  # `in_flight = count(unreleased)` holds — and `apply_declared/5` knowingly breaks that
  # invariant when a machine rejoins declaring fewer sessions than it currently holds. On a
  # row left at `in_flight: 1` with two unreleased rows, decrementing on the first release
  # wrote `0` while the second session was still running, and `reserve/3` then handed out a
  # slot on a machine already at its declared maximum. That is the over-dispatch the
  # declaration path exists to end, reinstated one function along.
  #
  # Recounting is the fix rather than DEFERRING the lowering until the row drains, because
  # nothing would ever apply a deferred one: `apply_declared/5` runs on a JOIN and a machine
  # that is already connected does not join again. A deferral would leave the larger
  # capacity live and `reserve/3` would hand out a slot the instant one drained — the same
  # over-dispatch, kept for longer. Recounting also needs no new state and no new sweep: it
  # converges from any drifted value, including one an older release left behind.
  #
  # The cost is two statements where there was one. Under the runner's row lock, so a
  # reservation or release racing this commits either before the count (and is in it) or
  # after the write (and applies on top of it) — the same argument `recount/2` makes, which
  # is why this IS `recount/2`. Every caller is already inside a transaction, so the lock is
  # held to its commit: `release/4`'s callers run in `DispatchLedger`'s `in_tenant/2`,
  # `runner_write/4` or an explicit `release_slot_in/4` that refuses to run outside one.
  defp give_back(repo, tenant_id, runner_id) do
    recount(repo, tenant_id, runner_id)
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
