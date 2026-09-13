defmodule Loopctl.Runners.DispatchLedger do
  @moduledoc """
  The dispatch ledger and trace intake of the runner channel (issue #803).

  ## Ledger

  `record_sent/3` writes a dispatch's identity BEFORE `Loopctl.Runners.dispatch/3`
  broadcasts it, and finds the existing row when the same `dispatch_id` is dispatched again
  (design §3). A re-dispatch is refused when that row names a different runner, story, epoch
  or kind (`:dispatch_id_conflict`) or has already been answered
  (`:dispatch_already_replied`); otherwise it is the retry of a push the channel may have
  dropped, and is sent again.

  `record_reply/3` applies a runner's `dispatch_reply` under a row lock. The row must belong
  to the CALLING runner in the calling tenant (otherwise `:unknown_dispatch` — another
  runner's dispatch is indistinguishable from none), the reply's `claim_epoch` must equal
  the dispatched one (`:stale_claim_epoch`), and the row must still be `sent`. A repeat of
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

  Neither replies nor trace are refused on a custody halt: a halt stops new custody
  progress, and a halted tenant must still be able to record what already happened.

  ## Isolation

  `AdminRepo` with an explicit `tenant_id` AND `runner_id` predicate on every read, the
  convention of `Loopctl.Runners`. RLS is enabled on both tables as defense-in-depth.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.TraceEvent

  @doc """
  Records a validated dispatch as `sent`, or finds the row an earlier dispatch of the same
  `dispatch_id` wrote. See the moduledoc for the refusals.
  """
  @spec record_sent(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, DispatchRecord.t()} | {:error, :dispatch_id_conflict | :dispatch_already_replied}
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

    AdminRepo.insert_all(DispatchRecord, [row],
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :dispatch_id]
    )

    record =
      AdminRepo.one!(
        from r in DispatchRecord,
          where: r.tenant_id == ^tenant_id and r.dispatch_id == ^dispatch.dispatch_id
      )

    cond do
      not same_dispatch?(record, runner_id, dispatch) -> {:error, :dispatch_id_conflict}
      record.status != "sent" -> {:error, :dispatch_already_replied}
      true -> {:ok, record}
    end
  end

  defp same_dispatch?(record, runner_id, dispatch) do
    record.runner_id == runner_id and record.story_id == dispatch.story_id and
      record.claim_epoch == dispatch.claim_epoch and record.kind == dispatch.kind
  end

  @doc "A tenant's ledger row for `dispatch_id`, or nil."
  @spec get_record(Ecto.UUID.t(), Ecto.UUID.t()) :: DispatchRecord.t() | nil
  def get_record(tenant_id, dispatch_id) do
    AdminRepo.one(
      from r in DispatchRecord,
        where: r.tenant_id == ^tenant_id and r.dispatch_id == ^dispatch_id
    )
  end

  @doc """
  Applies a validated `dispatch_reply` from `runner_id`. See the moduledoc for the rules.
  """
  @spec record_reply(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, DispatchRecord.t()}
          | {:error, :unknown_dispatch | :stale_claim_epoch | :already_replied}
  def record_reply(tenant_id, runner_id, reply) do
    AdminRepo.transaction(fn ->
      with {:ok, record} <- lock_held(tenant_id, runner_id, reply.dispatch_id),
           :ok <- epoch_matches(record, reply.claim_epoch),
           {:ok, record} <- apply_reply(record, reply) do
        record
      else
        {:error, reason} -> AdminRepo.rollback(reason)
      end
    end)
  end

  defp apply_reply(%DispatchRecord{status: "sent"} = record, reply) do
    record
    |> Ecto.Changeset.change(
      status: reply.decision,
      reason: Map.get(reply, :reason),
      reason_detail: Map.get(reply, :detail),
      replied_at: DateTime.utc_now()
    )
    |> AdminRepo.update()
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
             :unknown_dispatch | :stale_claim_epoch | :dispatch_not_accepted | :run_mismatch}
  def record_trace(tenant_id, runner_id, batch) do
    AdminRepo.transaction(fn ->
      with {:ok, record} <- lock_held(tenant_id, runner_id, batch.dispatch_id),
           :ok <- epoch_matches(record, batch.claim_epoch),
           :ok <- accepted(record),
           {:ok, record} <- bind_run(record, batch.run_id) do
        insert_events(record, batch.events)
        advance_cursor(record)
      else
        {:error, reason} -> AdminRepo.rollback(reason)
      end
    end)
  end

  @doc """
  The stored contiguous `acked_seq` of a run `runner_id` holds, or -1 — also for a run it
  does not hold, so the cursor reveals nothing about another runner's runs.
  """
  @spec trace_cursor(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: integer()
  def trace_cursor(tenant_id, runner_id, run_id) do
    AdminRepo.one(
      from r in DispatchRecord,
        where: r.tenant_id == ^tenant_id and r.runner_id == ^runner_id and r.run_id == ^run_id,
        select: r.trace_acked_seq
    ) || -1
  end

  # The ownership predicate: tenant AND runner. A row another runner holds is refused
  # exactly like a row that does not exist.
  defp lock_held(tenant_id, runner_id, dispatch_id) do
    query =
      from r in DispatchRecord,
        where: r.tenant_id == ^tenant_id and r.runner_id == ^runner_id,
        where: r.dispatch_id == ^dispatch_id,
        lock: "FOR UPDATE"

    case AdminRepo.one(query) do
      nil -> {:error, :unknown_dispatch}
      record -> {:ok, record}
    end
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
    |> AdminRepo.update()
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

    AdminRepo.insert_all(TraceEvent, rows,
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
      if AdminRepo.exists?(run_events(record) |> where([e], e.seq == ^next)) do
        successor =
          from n in TraceEvent,
            where: n.tenant_id == parent_as(:event).tenant_id,
            where: n.run_id == parent_as(:event).run_id,
            where: n.seq == parent_as(:event).seq + 1,
            select: 1

        AdminRepo.one(
          from e in run_events(record),
            where: e.seq >= ^next and not exists(successor),
            select: min(e.seq)
        )
      else
        acked
      end

    if new_acked != acked do
      {1, _} =
        AdminRepo.update_all(
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
