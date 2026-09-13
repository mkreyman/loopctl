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
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.TraceEvent
  alias Loopctl.WorkBreakdown.Story

  @doc """
  Records a validated dispatch as `sent`, or finds the row an earlier dispatch of the same
  `dispatch_id` wrote. See the moduledoc for the refusals.
  """
  @spec record_sent(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, DispatchRecord.t()}
          | {:error, :stale_claim_epoch | :dispatch_id_conflict | :dispatch_already_replied}
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
      inserted_at: now,
      updated_at: now
    }

    in_tenant(tenant_id, fn ->
      # Nothing is sent for a claim that has already moved on: the dispatch must carry the
      # story's CURRENT epoch, read under a share lock so a release cannot commit between
      # this read and the row it gates.
      if current_claim_epoch(tenant_id, dispatch.story_id) != dispatch.claim_epoch,
        do: Repo.rollback(:stale_claim_epoch)

      Repo.insert_all(DispatchRecord, [row],
        on_conflict: :nothing,
        conflict_target: [:tenant_id, :dispatch_id]
      )

      record =
        Repo.one!(
          from r in DispatchRecord,
            where: r.tenant_id == ^tenant_id and r.dispatch_id == ^dispatch.dispatch_id
        )

      cond do
        not same_dispatch?(record, runner_id, dispatch) -> Repo.rollback(:dispatch_id_conflict)
        record.status != "sent" -> Repo.rollback(:dispatch_already_replied)
        true -> record
      end
    end)
  end

  defp same_dispatch?(record, runner_id, dispatch) do
    record.runner_id == runner_id and record.story_id == dispatch.story_id and
      record.claim_epoch == dispatch.claim_epoch and record.kind == dispatch.kind
  end

  @doc """
  Stamps `pushed_at` on a dispatch the runner's channel has just pushed to its socket
  (issue #815). The latest push wins, so a re-sent dispatch records when it last left.

  Observability, not custody: the push has already happened, so a database fault here is
  logged and swallowed rather than crashing the channel that holds the runner's socket.
  """
  @spec mark_pushed(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | :error
  def mark_pushed(tenant_id, dispatch_id) do
    {:ok, _} =
      in_tenant(tenant_id, fn ->
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
  Applies a validated `dispatch_reply` from `runner_id`. See the moduledoc for the rules.
  """
  @spec record_reply(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, DispatchRecord.t()}
          | {:error,
             :unknown_dispatch | :stale_claim_epoch | :already_replied | :rejected_by_database}
  def record_reply(tenant_id, runner_id, reply) do
    context = %{operation: :record_reply, dispatch_id: reply.dispatch_id, run_id: nil}

    runner_write(tenant_id, runner_id, context, fn ->
      with {:ok, record} <- lock_held(tenant_id, runner_id, reply.dispatch_id),
           :ok <- story_fence(record),
           :ok <- epoch_matches(record, reply.claim_epoch),
           {:ok, record} <- apply_reply(record, reply) do
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
             | :rejected_by_database}
  def record_trace(tenant_id, runner_id, batch) do
    context = %{operation: :record_trace, dispatch_id: batch.dispatch_id, run_id: batch.run_id}

    runner_write(tenant_id, runner_id, context, fn ->
      with {:ok, record} <- lock_held(tenant_id, runner_id, batch.dispatch_id),
           :ok <- story_fence(record),
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
    in_tenant(tenant_id, fun)
  rescue
    error in Postgrex.Error ->
      if data_exception?(error) do
        report_rejection(error, tenant_id, runner_id, context)
        {:error, :rejected_by_database}
      else
        reraise(error, __STACKTRACE__)
      end
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

  # The ownership predicate: tenant AND runner. A row another runner holds is refused
  # exactly like a row that does not exist.
  defp lock_held(tenant_id, runner_id, dispatch_id) do
    query =
      from r in DispatchRecord,
        where: r.tenant_id == ^tenant_id and r.runner_id == ^runner_id,
        where: r.dispatch_id == ^dispatch_id,
        lock: "FOR UPDATE"

    case Repo.one(query) do
      nil -> {:error, :unknown_dispatch}
      record -> {:ok, record}
    end
  end

  # The fence against a zombie runner (issue #803). The authoritative epoch is the story's
  # (`stories.claim_epoch`, bumped by every claim and every release — `Progress`), not the
  # epoch this row recorded when it was sent. Read under a share lock in the transaction that
  # holds the row lock. When the story has moved past the row, the claim this dispatch
  # served is over: the row is marked `superseded` — so it stops reading as a live dispatch —
  # and every message about it is `stale_claim_epoch`. A story that no longer exists is
  # treated the same way.
  defp story_fence(%DispatchRecord{} = record) do
    if current_claim_epoch(record.tenant_id, record.story_id) == record.claim_epoch do
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

  # Only a live row: a refused one is already terminal, and its reason must stay.
  defp supersede(%DispatchRecord{} = record) do
    Repo.update_all(
      from(r in DispatchRecord,
        where: r.id == ^record.id and r.tenant_id == ^record.tenant_id,
        where: r.status in ["sent", "accepted"]
      ),
      set: [status: "superseded", updated_at: DateTime.utc_now()]
    )
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
