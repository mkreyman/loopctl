defmodule Loopctl.Runners.DispatchLedger do
  @moduledoc """
  The dispatch ledger and trace intake of the runner channel (issue #803).

  ## Ledger

  `record_sent/3` writes a dispatch's identity BEFORE `Loopctl.Runners.dispatch/3`
  broadcasts it, and finds the existing row when the same `dispatch_id` is dispatched again
  (design §3). A re-dispatch is refused when that row names a different runner, story, epoch
  or kind (`:dispatch_id_conflict`) or has already been answered
  (`:dispatch_already_replied`); otherwise it is the retry of a push the channel may have
  dropped, and is sent again. Nothing is recorded or sent when the dispatch's `claim_epoch`
  is not the story's current one (`:stale_claim_epoch`).

  A dispatch holds a slot on its runner (`Loopctl.Runners.Capacity`). `record_sent/3` takes it
  in the SAME transaction that writes the row — admission over the tenant's total, then the
  runner's own `in_flight < max_sessions` — so a row exists exactly when its slot does and a
  crash between the two commits neither (`:admission_limit_reached`, `:runner_at_capacity`,
  or `:capacity_busy` when a lock wait ran out or a deadlock was broken). A re-dispatch of a
  row that still holds its slot takes no second one; a re-dispatch of a row whose slot was
  already released takes a fresh one, under a NEW `slot_generation`, so a release meant for
  the old slot can never free the new one. A refusal (`record_reply/3`) and a supersede (the
  claim fence) release the slot in the transaction that records them, exactly once.

  ## Lock order

  The fleet-wide order, which `Loopctl.Runners.Capacity` states in full:

      capacity advisory lock (0x41050803) -> story row
        -> runner_dispatches / story_stages row -> chain advisory lock (0x4105A1D7)
        -> audit-chain head -> runners row

  So `record_sent/3` takes the tenant's admission lock as the FIRST thing in its transaction —
  before the claim fence, not with the reservation at the end — and `record_reply/3` and
  `record_trace/3` fence the story before locking the dispatch row. Both used to be the other
  way round, and each closed a cycle with a caller holding a story `FOR UPDATE`. The reply and
  trace paths resolve the row's story from an UNLOCKED pre-read (`story_id` never changes
  after the row is written) so the fence can come first; the fence itself is then decided on
  the row read under its lock.

  `record_reply/3` applies a runner's `dispatch_reply` under a row lock. The row must belong
  to the CALLING runner in the calling tenant (otherwise `:unknown_dispatch` — another
  runner's dispatch is indistinguishable from none), the reply's `claim_epoch` must equal
  the dispatched one AND the story's current `claim_epoch` (`:stale_claim_epoch`), and the
  row must still be `sent`. When the story's epoch has moved past the row's — the claim was
  released or reclaimed — the row is marked `superseded` in the same transaction. A repeat of
  the reply already recorded is `:ok`; a different one is `:already_replied`.

  No audit-chain entry is written for a reply. The chain is kept for custody transitions
  (claim, merge, escalate — design §11), a reply is the runner's own report about its
  machine, and the ledger row already records it with its time.

  ## Trace

  `record_trace/3` stores a batch for a run of an ACCEPTED dispatch the calling runner
  holds, at the dispatched epoch. The first batch binds the run to the dispatch; a run is
  one dispatch's, and a dispatch has one run (`:run_mismatch`). Events are inserted with
  `ON CONFLICT DO NOTHING` on `(tenant_id, run_id, seq)`, then the dispatch's
  `trace_acked_seq` is advanced in SQL to the end of the contiguous run of stored seqs that
  starts at 0 — never by loading the run's rows. `trace_cursor/3` reads it back.

  A reply or trace value Postgres still refuses after the contract cast is answered
  `{:error, :rejected_by_database}`, logged with its SQLSTATE and identifiers (never its
  values) and counted as the `[:loopctl, :runners, :ledger_rejected_by_database]` telemetry
  event.

  A reply or trace that could not get a LOCK is a different answer: every transaction here
  bounds its waits (`Capacity.lock_timeout_ms/0`) and answers `{:error, :capacity_busy}` on a
  timeout or a broken deadlock, which the channel turns into `rate_limited` with that
  interval. Both halves matter. Unbounded, a reply queued behind a claim release held a pool
  connection for as long as that transaction ran; and reraising crashed the channel holding
  the runner's socket, after which the runner rejoined and re-sent the same message — the
  unending loop the `rejected_by_database` backstop exists to prevent. `rejected_by_database`
  is the wrong answer for a transient fault, too: it reaches the runner as `invalid_payload`,
  which tells it to STOP resending.

  Neither replies nor trace are refused on a custody halt: a halt stops new custody
  progress, and a halted tenant must still be able to record what already happened.

  ## Repo and isolation

  Every read and write runs on the RLS-enforced `Loopctl.Repo`, inside
  `Repo.with_tenant/2`, and every query ALSO carries an explicit `tenant_id` (and, where
  the caller is a runner, `runner_id`) predicate. Never `AdminRepo`: its pool is a handful
  of connections that `ValidateWitnessHeader` reads on every authenticated request, and a
  fleet of runners resuming their traces after a deploy would queue the whole API behind
  them. `with_tenant/2` must own its transaction, so none of these functions may be called
  from inside a `Repo` transaction — it raises there rather than leaking the tenant context.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.Repo
  alias Loopctl.Runners.Capacity
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.TraceEvent
  alias Loopctl.WorkBreakdown.Story

  @doc """
  Records a validated dispatch as `sent`, or finds the row an earlier dispatch of the same
  `dispatch_id` wrote. See the moduledoc for the refusals.
  """
  @spec record_sent(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, DispatchRecord.t()}
          | {:error,
             :stale_claim_epoch
             | :dispatch_id_conflict
             | :dispatch_already_replied
             | :admission_limit_reached
             | :runner_at_capacity
             | :capacity_busy}
  def record_sent(tenant_id, runner_id, dispatch) do
    now = DateTime.utc_now()

    row = %{
      id: Ecto.UUID.generate(),
      tenant_id: tenant_id,
      runner_id: runner_id,
      dispatch_id: dispatch.dispatch_id,
      story_id: dispatch.story_id,
      claim_epoch: dispatch.claim_epoch,
      kind: dispatch.kind,
      status: "sent",
      trace_acked_seq: -1,
      wall_clock_seconds: dispatch.wall_clock_seconds,
      # Born holding NO slot: the row is inserted first (that is how a retry is told from a
      # first send), and `take_slot/1` clears this in the same transaction. The CHECK that
      # every unreleased row is bounded therefore holds at every instant, not only at commit
      # — a CHECK cannot be deferred to commit in Postgres.
      released_at: now,
      slot_generation: 0,
      inserted_at: now,
      updated_at: now
    }

    in_tenant(tenant_id, fn ->
      # Every wait below — the admission lock, the story share lock, the runner row — is
      # bounded, so a stuck transaction elsewhere costs a dispatcher `:capacity_busy`, never
      # an open transaction waiting indefinitely.
      Capacity.set_lock_timeout!(Repo)

      # FIRST, before the story fence: the fleet lock order. Held to the end of the
      # transaction, it is what makes the tenant's admissions serialize.
      Capacity.lock_admission!(Repo, tenant_id)

      # Nothing is sent for a claim that has already moved on: the dispatch must carry the
      # story's CURRENT epoch, read under a share lock so a release cannot commit between
      # this read and the row it gates.
      if current_claim_epoch(tenant_id, dispatch.story_id) != dispatch.claim_epoch,
        do: Repo.rollback(:stale_claim_epoch)

      # Inserted BEFORE the slot is taken, holding none. A concurrent first send of the same
      # id waits here on the unique index and then finds this transaction's committed row;
      # whether the row (new or found) holds a slot is what decides below.
      Repo.insert_all(DispatchRecord, [row],
        on_conflict: :nothing,
        conflict_target: [:tenant_id, :dispatch_id]
      )

      # Locked, so two retries of a released row cannot both take a fresh slot for it.
      record =
        Repo.one!(
          from r in DispatchRecord,
            where: r.tenant_id == ^tenant_id and r.dispatch_id == ^dispatch.dispatch_id,
            lock: "FOR UPDATE"
        )

      cond do
        not same_dispatch?(record, runner_id, dispatch) ->
          Repo.rollback(:dispatch_id_conflict)

        record.status != "sent" ->
          Repo.rollback(:dispatch_already_replied)

        not is_nil(record.released_at) ->
          record |> refresh_wall_clock(dispatch, now) |> take_slot()

        true ->
          refresh_wall_clock(record, dispatch, now)
      end
    end)
  rescue
    error in Postgrex.Error ->
      if Capacity.retryable?(error),
        do: {:error, :capacity_busy},
        else: reraise(error, __STACKTRACE__)
  end

  # A failure rolls the whole transaction back, the row this call inserted included, so no
  # reservation is ever left without its dispatch or a dispatch without its reservation.
  defp take_slot(%DispatchRecord{} = record) do
    case Capacity.admit_and_reserve(Repo, record, DateTime.utc_now()) do
      {:ok, reserved} -> reserved
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A re-send may carry a DIFFERENT wall clock — it is not part of the dispatch's identity
  # (`same_dispatch?/3`), and the runner will run the session for the clock it was last sent.
  # The stored one bounds the slot in `Capacity.heal/3`, so it has to be the one in flight:
  # left at the first send's value, a re-send with a longer clock has its slot reclaimed
  # under a running session.
  defp refresh_wall_clock(%DispatchRecord{} = record, dispatch, now) do
    if record.wall_clock_seconds == dispatch.wall_clock_seconds do
      record
    else
      {1, _} =
        from(d in DispatchRecord,
          where: d.id == ^record.id and d.tenant_id == ^record.tenant_id
        )
        |> Repo.update_all(
          set: [wall_clock_seconds: dispatch.wall_clock_seconds, updated_at: now]
        )

      %{record | wall_clock_seconds: dispatch.wall_clock_seconds}
    end
  end

  defp same_dispatch?(record, runner_id, dispatch) do
    record.runner_id == runner_id and record.story_id == dispatch.story_id and
      record.claim_epoch == dispatch.claim_epoch and record.kind == dispatch.kind
  end

  @doc """
  Stamps `pushed_at` on a dispatch the runner's channel is ABOUT TO push (issue #815, and
  #803's capacity bound). The latest push wins, so a re-sent dispatch records when it last
  left.

  Stamped BEFORE the push, and the channel pushes only on `:ok`. Capacity now reads this
  column: a reservation whose dispatch was never pushed under it is released after a short
  bound (`Loopctl.Runners.Capacity`), so a stamp that failed AFTER the push would take a
  running session's slot away two minutes later. Written first, a failure means the runner
  never got the dispatch, which is exactly what the missing stamp then says. A database fault
  is still logged and swallowed rather than crashing the channel that holds the socket — the
  channel drops the dispatch instead, and the slot goes back.
  """
  @spec mark_pushed(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | :error
  def mark_pushed(tenant_id, dispatch_id) do
    {:ok, _} =
      in_tenant(tenant_id, fn ->
        # Bounded: this runs in the channel process, which holds the runner's socket, and the
        # push waits on it. Past the timeout the dispatch is dropped and re-dispatched, which
        # is cheaper than a socket that stops answering.
        Capacity.set_lock_timeout!(Repo)

        Repo.update_all(
          from(r in DispatchRecord,
            where: r.tenant_id == ^tenant_id and r.dispatch_id == ^dispatch_id
          ),
          set: [pushed_at: DateTime.utc_now()]
        )
      end)

    :ok
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning(
        "runner ledger pushed_at not recorded: tenant_id=#{tenant_id} " <>
          "dispatch_id=#{dispatch_id} error=#{inspect(error.__struct__)}"
      )

      :error
  end

  @doc "A tenant's ledger row for `dispatch_id`, or nil."
  @spec get_record(Ecto.UUID.t(), Ecto.UUID.t()) :: DispatchRecord.t() | nil
  def get_record(tenant_id, dispatch_id) do
    {:ok, record} =
      in_tenant(tenant_id, fn ->
        Repo.one(
          from r in DispatchRecord,
            where: r.tenant_id == ^tenant_id and r.dispatch_id == ^dispatch_id
        )
      end)

    record
  end

  @doc """
  Releases the slot `generation` of `dispatch_id`, exactly once, in a transaction of its own:
  `{:ok, :released}` the first time, `{:ok, :already_released}` on every replay and for a
  generation the row no longer holds. For the caller that learns a dispatch's session ended,
  which the ledger does not model.

  Read the generation from the row (`get_record/2`, `slot_generation`) at the point the
  session STARTED — an accepted dispatch can never be re-sent, so its generation is final
  from its reply onward.

  **A caller inside a transaction of its own must use `release_slot_in/4`.** This function
  opens one (`Repo.with_tenant/2` raises inside another `Repo` transaction, and against
  `AdminRepo` it would take a second connection and commit apart from the caller). Called
  AFTER a caller's transaction commits, it is also a second commit: a node that dies in
  between leaves the slot held until the heal sweep's bound
  (`Loopctl.Runners.Capacity`), which is the whole reason the in-transaction form exists.
  """
  @spec release_slot(Ecto.UUID.t(), Ecto.UUID.t(), integer()) ::
          {:ok, :released | :already_released}
          | {:error, :unknown_dispatch | :capacity_busy}
  def release_slot(tenant_id, dispatch_id, generation) when is_integer(generation) do
    in_tenant(tenant_id, fn ->
      Capacity.set_lock_timeout!(Repo)

      case release_slot_in(Repo, tenant_id, dispatch_id, generation) do
        {:ok, outcome} -> outcome
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  rescue
    error in Postgrex.Error ->
      if Capacity.retryable?(error),
        do: {:error, :capacity_busy},
        else: reraise(error, __STACKTRACE__)
  end

  @doc """
  Releases the slot of a dispatch that was NEVER DELIVERED under its current reservation —
  `sent`, and either never pushed or last pushed under an earlier one. For the channel that
  DROPS a dispatch instead of pushing it, and for a broadcast that failed.

  It names no generation on purpose: the caller of this one knows only that a delivery did
  not happen, and the row itself says which slot that was. The undelivered predicate is what
  keeps it off a RUNNING session's slot — a re-send of a dispatch that already holds a pushed
  slot, dropped by a second socket, matches nothing and releases nothing.
  """
  @spec release_undelivered_slot(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, :released | :already_released} | {:error, :unknown_dispatch | :capacity_busy}
  def release_undelivered_slot(tenant_id, dispatch_id) do
    in_tenant(tenant_id, fn ->
      Capacity.set_lock_timeout!(Repo)

      query =
        from r in DispatchRecord,
          where: r.tenant_id == ^tenant_id and r.dispatch_id == ^dispatch_id,
          lock: "FOR UPDATE"

      case Repo.one(query) do
        nil -> Repo.rollback(:unknown_dispatch)
        record -> release_if_undelivered(record)
      end
    end)
  rescue
    error in Postgrex.Error ->
      if Capacity.retryable?(error),
        do: {:error, :capacity_busy},
        else: reraise(error, __STACKTRACE__)
  end

  defp release_if_undelivered(%DispatchRecord{} = record) do
    if undelivered?(record),
      do: Capacity.release(Repo, record, record.slot_generation),
      else: :already_released
  end

  # `sent` and never pushed under the slot it holds now. A reply of any kind, or a push made
  # under this reservation, means a session may be running on it.
  defp undelivered?(%DispatchRecord{status: "sent", released_at: nil} = record) do
    is_nil(record.pushed_at) or
      (not is_nil(record.reserved_at) and
         DateTime.compare(record.pushed_at, record.reserved_at) == :lt)
  end

  defp undelivered?(%DispatchRecord{}), do: false

  @doc """
  `release_slot/3` inside the CALLER's transaction, on the caller's repo — the form for a
  step of a claim release or a stage transition, which must commit with the transition that
  decided it.

  The caller owns the transaction and must already be in it; on `Loopctl.Repo` it must also
  carry the tenant's RLS context (`Repo.set_rls_context/1`), or the row is invisible and the
  answer is `{:error, :unknown_dispatch}`. Keep the lock order: the story row (if the caller
  locks one) before this row, and the `runners` row after it — which is what this does.
  """
  @spec release_slot_in(Ecto.Repo.t(), Ecto.UUID.t(), Ecto.UUID.t(), integer()) ::
          {:ok, :released | :already_released} | {:error, :unknown_dispatch}
  def release_slot_in(repo, tenant_id, dispatch_id, generation) when is_integer(generation) do
    unless repo.in_transaction?() do
      raise ArgumentError,
            "Loopctl.Runners.DispatchLedger.release_slot_in/4 must run inside the caller's " <>
              "#{inspect(repo)} transaction; use release_slot/3 when you have none."
    end

    query =
      from r in DispatchRecord,
        where: r.tenant_id == ^tenant_id and r.dispatch_id == ^dispatch_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      nil -> {:error, :unknown_dispatch}
      record -> {:ok, Capacity.release(repo, record, generation)}
    end
  end

  @doc """
  Applies a validated `dispatch_reply` from `runner_id`. See the moduledoc for the rules.
  """
  @spec record_reply(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, DispatchRecord.t()}
          | {:error,
             :unknown_dispatch
             | :stale_claim_epoch
             | :already_replied
             | :rejected_by_database
             | :capacity_busy}
  def record_reply(tenant_id, runner_id, reply) do
    context = %{operation: :record_reply, dispatch_id: reply.dispatch_id, run_id: nil}

    runner_write(tenant_id, runner_id, context, fn ->
      with {:ok, record} <- fence_then_lock(tenant_id, runner_id, reply.dispatch_id),
           :ok <- epoch_matches(record, reply.claim_epoch),
           {:ok, record} <- apply_reply(record, reply) do
        release_if_refused(record)
        record
      end
    end)
    |> flatten()
  end

  defp apply_reply(%DispatchRecord{status: "sent"} = record, reply) do
    record
    |> Ecto.Changeset.change(
      status: reply.decision,
      reason: Map.get(reply, :reason),
      reason_detail: Map.get(reply, :detail),
      replied_at: DateTime.utc_now()
    )
    |> Repo.update()
  end

  defp apply_reply(%DispatchRecord{} = record, reply) do
    if record.status == reply.decision and record.reason == Map.get(reply, :reason) and
         record.reason_detail == Map.get(reply, :detail),
       do: {:ok, record},
       else: {:error, :already_replied}
  end

  # A refused dispatch starts no session. Also on an identical repeat of the refusal, where
  # the release is a no-op, so a first reply whose release was lost with its transaction
  # cannot leave the slot held.
  defp release_if_refused(%DispatchRecord{status: "refused"} = record),
    do: Capacity.release(Repo, record, record.slot_generation)

  defp release_if_refused(%DispatchRecord{}), do: :ok

  @doc """
  Stores a validated `trace` batch from `runner_id` and returns the run's contiguous
  `acked_seq`. See the moduledoc for the rules.
  """
  @spec record_trace(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, integer()}
          | {:error,
             :unknown_dispatch
             | :stale_claim_epoch
             | :dispatch_not_accepted
             | :run_mismatch
             | :rejected_by_database
             | :capacity_busy}
  def record_trace(tenant_id, runner_id, batch) do
    context = %{operation: :record_trace, dispatch_id: batch.dispatch_id, run_id: batch.run_id}

    runner_write(tenant_id, runner_id, context, fn ->
      with {:ok, record} <- fence_then_lock(tenant_id, runner_id, batch.dispatch_id),
           :ok <- epoch_matches(record, batch.claim_epoch),
           :ok <- accepted(record),
           {:ok, record} <- bind_run(record, batch.run_id) do
        insert_events(record, batch.events)
        advance_cursor(record)
      else
        # Follows a failed statement, which aborted the transaction.
        {:error, :run_mismatch} -> Repo.rollback(:run_mismatch)
        {:error, reason} -> {:error, reason}
      end
    end)
    |> flatten()
  end

  # A refusal is RETURNED from the transaction, not rolled back, so a `superseded` write
  # made on the way to it commits. The one refusal that follows a failed statement
  # (`bind_run/2`'s unique violation, which aborts the transaction) rolls back instead.
  defp flatten({:ok, {:error, reason}}), do: {:error, reason}
  defp flatten(result), do: result

  @doc """
  The stored contiguous `acked_seq` of a run `runner_id` holds, or -1 — also for a run it
  does not hold, so the cursor reveals nothing about another runner's runs.
  """
  @spec trace_cursor(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: integer()
  def trace_cursor(tenant_id, runner_id, run_id) do
    {:ok, acked} =
      in_tenant(tenant_id, fn ->
        Repo.one(
          from r in DispatchRecord,
            where: r.tenant_id == ^tenant_id and r.runner_id == ^runner_id,
            where: r.run_id == ^run_id,
            select: r.trace_acked_seq
        )
      end)

    acked || -1
  end

  # The one way this module reaches the database: an RLS transaction it owns. A database
  # error raises: `record_sent/3` and the reads are given server-side values, so an error
  # there is a server bug.
  defp in_tenant(tenant_id, fun), do: Repo.with_tenant(tenant_id, fun)

  # `in_tenant/2` for a write of RUNNER-SUPPLIED values (`record_reply/3`, `record_trace/3`)
  # and only those. A value Postgres refuses as data comes back as
  # `{:error, :rejected_by_database}` rather than a raise: SQLSTATE class 22 (a NUL in text
  # or jsonb, a number out of range) and the `runner_trace_events_seq` CHECK. Raised inside
  # the channel's handle_in it would crash the channel, the runner would resend the same
  # message on rejoin, and the loop would never end. The contract cast refuses the known
  # cases first; this is the backstop, so reaching it is logged and counted — a run whose
  # `acked_seq` stops advancing must leave an operator a signal. Any other error raises.
  defp runner_write(tenant_id, runner_id, context, fun) do
    in_tenant(tenant_id, fn ->
      Capacity.set_lock_timeout!(Repo)
      fun.()
    end)
  rescue
    error in Postgrex.Error ->
      cond do
        Capacity.retryable?(error) ->
          report_busy(error, tenant_id, runner_id, context)
          {:error, :capacity_busy}

        data_exception?(error) ->
          report_rejection(error, tenant_id, runner_id, context)
          {:error, :rejected_by_database}

        true ->
          reraise(error, __STACKTRACE__)
      end
  end

  # A lock this write could not get inside `Capacity.lock_timeout_ms/0`, or a deadlock
  # Postgres broke by choosing it. Nothing was written; the runner is told to send it again.
  defp report_busy(%Postgrex.Error{postgres: postgres}, tenant_id, runner_id, context) do
    metadata = %{
      operation: context.operation,
      sqlstate: postgres[:pg_code],
      tenant_id: tenant_id,
      runner_id: runner_id,
      dispatch_id: context.dispatch_id,
      run_id: context.run_id
    }

    Logger.warning(
      "runner ledger write could not get a lock: operation=#{metadata.operation} " <>
        "sqlstate=#{metadata.sqlstate} tenant_id=#{tenant_id} runner_id=#{runner_id} " <>
        "dispatch_id=#{metadata.dispatch_id} run_id=#{inspect(metadata.run_id)}"
    )

    :telemetry.execute([:loopctl, :runners, :ledger_lock_unavailable], %{count: 1}, metadata)
  end

  defp data_exception?(%Postgrex.Error{postgres: %{pg_code: "22" <> _}}), do: true

  defp data_exception?(%Postgrex.Error{postgres: %{constraint: "runner_trace_events_seq"}}),
    do: true

  defp data_exception?(_error), do: false

  # Identifiers and the SQLSTATE only. Never the error's message or detail, which can quote
  # the refused value, and never the payload.
  defp report_rejection(%Postgrex.Error{postgres: postgres}, tenant_id, runner_id, context) do
    metadata = %{
      operation: context.operation,
      sqlstate: postgres[:pg_code],
      constraint: postgres[:constraint],
      tenant_id: tenant_id,
      runner_id: runner_id,
      dispatch_id: context.dispatch_id,
      run_id: context.run_id
    }

    Logger.warning(
      "runner ledger write rejected by the database: operation=#{metadata.operation} " <>
        "sqlstate=#{metadata.sqlstate} constraint=#{inspect(metadata.constraint)} " <>
        "tenant_id=#{tenant_id} runner_id=#{runner_id} dispatch_id=#{metadata.dispatch_id} " <>
        "run_id=#{inspect(metadata.run_id)}"
    )

    :telemetry.execute([:loopctl, :runners, :ledger_rejected_by_database], %{count: 1}, metadata)
  end

  # The lock order (see the moduledoc): the story's row, then the dispatch's. The story is
  # resolved from an UNLOCKED pre-read, which learns only `story_id` — written once with the
  # row and never changed — and the fence is then decided on the row read UNDER its lock, so
  # nothing is judged on the unlocked copy.
  defp fence_then_lock(tenant_id, runner_id, dispatch_id) do
    with {:ok, %DispatchRecord{story_id: story_id}} <- held(tenant_id, runner_id, dispatch_id) do
      current = current_claim_epoch(tenant_id, story_id)

      with {:ok, record} <- held(tenant_id, runner_id, dispatch_id, true),
           :ok <- story_fence(record, current) do
        {:ok, record}
      end
    end
  end

  # The ownership predicate: tenant AND runner. A row another runner holds is refused
  # exactly like a row that does not exist.
  defp held(tenant_id, runner_id, dispatch_id, locked? \\ false) do
    query =
      from r in DispatchRecord,
        where: r.tenant_id == ^tenant_id and r.runner_id == ^runner_id,
        where: r.dispatch_id == ^dispatch_id

    query = if locked?, do: lock(query, "FOR UPDATE"), else: query

    case Repo.one(query) do
      nil -> {:error, :unknown_dispatch}
      record -> {:ok, record}
    end
  end

  # The fence against a zombie runner (issue #803). The authoritative epoch is the story's
  # (`stories.claim_epoch`, bumped by every claim and every release — `Progress`), not the
  # epoch this row recorded when it was sent. Read under a share lock BEFORE the row lock
  # (the lock order), in the same transaction. When the story has moved past the row, the
  # claim this dispatch served is over: the row is marked `superseded` — so it stops reading
  # as a live dispatch — and every message about it is `stale_claim_epoch`. A story that no
  # longer exists is treated the same way.
  defp story_fence(%DispatchRecord{} = record, current_epoch) do
    if current_epoch == record.claim_epoch do
      :ok
    else
      supersede(record)
      {:error, :stale_claim_epoch}
    end
  end

  defp current_claim_epoch(tenant_id, story_id) do
    Repo.one(
      from s in Story,
        where: s.id == ^story_id and s.tenant_id == ^tenant_id,
        lock: "FOR SHARE",
        select: s.claim_epoch
    )
  end

  # Only a live row: a refused one is already terminal, and its reason must stay. The claim
  # the dispatch served is over, so its slot goes back in the same transaction.
  defp supersede(%DispatchRecord{} = record) do
    Repo.update_all(
      from(r in DispatchRecord,
        where: r.id == ^record.id and r.tenant_id == ^record.tenant_id,
        where: r.status in ["sent", "accepted"]
      ),
      set: [status: "superseded", updated_at: DateTime.utc_now()]
    )

    Capacity.release(Repo, record, record.slot_generation)
  end

  # A superseded dispatch's claim was reclaimed, so every epoch it carries is stale.
  defp epoch_matches(%DispatchRecord{status: "superseded"}, _epoch),
    do: {:error, :stale_claim_epoch}

  defp epoch_matches(%DispatchRecord{claim_epoch: epoch}, epoch), do: :ok
  defp epoch_matches(%DispatchRecord{}, _epoch), do: {:error, :stale_claim_epoch}

  defp accepted(%DispatchRecord{status: "accepted"}), do: :ok
  defp accepted(%DispatchRecord{}), do: {:error, :dispatch_not_accepted}

  defp bind_run(%DispatchRecord{run_id: run_id} = record, run_id), do: {:ok, record}

  defp bind_run(%DispatchRecord{run_id: nil} = record, run_id) do
    record
    |> Ecto.Changeset.change(run_id: run_id)
    |> Ecto.Changeset.unique_constraint(:run_id, name: :runner_dispatches_tenant_run_uidx)
    |> Repo.update()
    |> case do
      {:ok, record} -> {:ok, record}
      {:error, _changeset} -> {:error, :run_mismatch}
    end
  end

  defp bind_run(%DispatchRecord{}, _run_id), do: {:error, :run_mismatch}

  # The first copy of a `(run_id, seq)` wins; a re-sent one is dropped by the unique index.
  defp insert_events(record, events) do
    now = DateTime.utc_now()

    rows =
      Enum.map(events, fn event ->
        %{
          id: Ecto.UUID.generate(),
          tenant_id: record.tenant_id,
          runner_dispatch_id: record.id,
          run_id: record.run_id,
          seq: event.seq,
          event_id: event.event_id,
          parent: event.parent,
          ts: usec(event.ts),
          type: event.type,
          data: Map.get(event, :data, %{}),
          inserted_at: now
        }
      end)

    Repo.insert_all(TraceEvent, rows,
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :run_id, :seq]
    )
  end

  defp usec(%DateTime{microsecond: {us, _precision}} = ts), do: %{ts | microsecond: {us, 6}}

  # The contiguous ack, advanced from the stored cursor so a long run is not rescanned from
  # seq 0 on every batch. Seqs up to `acked` are all stored (the invariant). If `acked + 1`
  # is not stored the cursor stays; otherwise the new cursor is the first stored seq at or
  # after it whose successor is missing — every seq in between has its successor, so the
  # whole stretch is contiguous. The row lock serialises batches of one run.
  defp advance_cursor(%DispatchRecord{trace_acked_seq: acked} = record) do
    next = acked + 1

    new_acked =
      if Repo.exists?(run_events(record) |> where([e], e.seq == ^next)) do
        successor =
          from n in TraceEvent,
            where: n.tenant_id == parent_as(:event).tenant_id,
            where: n.run_id == parent_as(:event).run_id,
            where: n.seq == parent_as(:event).seq + 1,
            select: 1

        Repo.one(
          from e in run_events(record),
            where: e.seq >= ^next and not exists(successor),
            select: min(e.seq)
        )
      else
        acked
      end

    if new_acked != acked do
      {1, _} =
        Repo.update_all(
          from(r in DispatchRecord,
            where: r.id == ^record.id and r.tenant_id == ^record.tenant_id
          ),
          set: [trace_acked_seq: new_acked, updated_at: DateTime.utc_now()]
        )
    end

    new_acked
  end

  defp run_events(record) do
    from e in TraceEvent,
      as: :event,
      where: e.tenant_id == ^record.tenant_id and e.run_id == ^record.run_id
  end
end
