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
        -> runner_dispatches / story_stages row -> runners row
        -> chain advisory lock (0x4105A1D7) -> audit-chain head

  **The chain append is always LAST** (corrected in the #824 review — this copy, and
  `Capacity`'s, put the `runners` row after the chain, while every writer in the fleet takes
  it before: `Loopctl.Runners.revoke_runner/3` and the session-end slot release in
  `Loopctl.Delivery.Stages`. Nothing takes the chain first and a `runners` row second, so the
  table moved rather than the code.) Nothing in THIS module appends to the chain at all — a
  reply is the runner's own report about its machine, not a custody transition — so the part
  of the order it follows ends at the `runners` row.

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

  ## Retention

  `prune_trace_events/3` is the trace table's retention pass, called by
  `Loopctl.Workers.DeliveryLoopPruneWorker`. It deletes events past a tenant's window whose
  dispatch is TERMINAL — `released_at` set — in bounded batches, oldest first. A dispatch
  nothing has released keeps its whole trace however old it is: `released_at` is the one
  column that says the session is over (a finished run stays `accepted` for ever, so
  `status` cannot say it), and a slot nothing gave back is either still running or a leak
  `Loopctl.Workers.HealRunnerCapacityWorker` is about to release.

  Retention does NOT disturb the resume protocol. A runner resumes from `trace_acked_seq`,
  a column on the DISPATCH row, and `advance_cursor/1` only ever reads seqs above it — see
  the note there — so a pruned event below the cursor is invisible to both. The trace file
  on the runner's disk stays the source of truth for the run; this table is the copy
  loopctl keeps, and the window is a disk bound, not amnesia. The audit chain is a
  different table and is never touched here.

  **INVARIANT for anyone adding an age-based prune of `runner_dispatches` ITSELF: a row with
  `status = "refused"` and `reason = "kind_not_supported"` is EVIDENCE, not history, and must
  never be deleted.** Those rows are the entire storage of the capability memory
  `kind_unsupported?/3` reads (contract 1.5.0) — there is no column and no second copy — so
  deleting one makes a machine that told loopctl it cannot do a kind eligible for that kind
  again: silently, on a schedule, with no reply from the runner and nothing in any log to say
  why the dispatches resumed. Only the trace TABLE has retention today, and the coupling is
  invisible from a pruner's own file, which is why this is stated here AND asserted by a
  source scan in `dispatch_ledger_test.exs` that goes red the moment anything under `lib/`
  deletes a `DispatchRecord`. Exclude these rows in the pruner's predicate, or leave this
  table alone.

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

  alias Loopctl.LocalGuc
  alias Loopctl.Repo
  alias Loopctl.Runners.Capacity
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.TraceEvent
  alias Loopctl.WorkBreakdown.Story

  # Retention (see "Retention" in the moduledoc). The batch is one DELETE statement's worth of
  # rows and the budget is one tenant's worth per run: both bound how long a single statement
  # and a single run can hold a connection of the RLS pool, and the budget is what makes a run
  # that cannot keep up stop cleanly instead of running until something else times out.
  @prune_batch_size 1_000
  @prune_budget 20_000
  @prune_statement_timeout_ms 15_000

  @doc "The rows one retention DELETE statement takes."
  @spec prune_batch_size() :: pos_integer()
  def prune_batch_size, do: @prune_batch_size

  @doc "The rows one retention run may delete for one tenant."
  @spec prune_budget() :: pos_integer()
  def prune_budget, do: @prune_budget

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
      # RECORDED ON THE FIRST INSERT AND NEVER REWRITTEN (#846.2 review round 2, finding 4).
      # `on_conflict: :nothing` below means a retry leaves this alone, which is the whole
      # property: `Loopctl.Delivery.Placement` re-sends the name that is here rather than
      # re-deriving one from a declaration the machine may have changed since.
      branch: dispatch.branch,
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
          take_slot(record)

        true ->
          # A deliberate re-send of a row that still holds its slot is a NEW delivery
          # attempt, so the previous attempt's decision is cleared: without that, a dispatch
          # already marked `pushed` could never be re-sent to a socket that lost the frame,
          # and would wait out the heal sweep's reply grace instead. This is the dispatcher's
          # own transaction, ordered before the broadcast it then makes, so it cannot race
          # the push and drop that broadcast wakes — those two still decide between
          # themselves. Safe only while the row is `sent`: an ACCEPTED dispatch never reaches
          # here (`:dispatch_already_replied` above), so no running session's decision is
          # ever cleared.
          clear_delivery(record, now)
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

  defp clear_delivery(%DispatchRecord{delivery: nil} = record, _now), do: record

  defp clear_delivery(%DispatchRecord{} = record, now) do
    {1, _} =
      from(d in DispatchRecord, where: d.id == ^record.id and d.tenant_id == ^record.tenant_id)
      |> Repo.update_all(set: [delivery: nil, updated_at: now])

    %{record | delivery: nil}
  end

  defp same_dispatch?(record, runner_id, dispatch) do
    record.runner_id == runner_id and record.story_id == dispatch.story_id and
      record.claim_epoch == dispatch.claim_epoch and record.kind == dispatch.kind
  end

  @doc """
  Takes the delivery DECISION for a dispatch's current reservation, for the channel about to
  push it: `{:ok, :pushed}` when this caller won and must push, `{:ok, {:already, outcome}}`
  when another process already decided (`"pushed"` by a second socket, `"dropped"` by a
  channel that refused), and `{:error, :capacity_busy}` when the row's lock could not be had
  in time — in which case NOTHING was decided and nothing is pushed.

  One broadcast wakes every channel subscribed to the runner, and a pusher and a dropper are
  separate transactions in separate processes with no ordering between them. Both take this
  row `FOR UPDATE` and compare-and-set `delivery`, so exactly one decides and the other
  respects it. As independent writes they raced: a dropping channel could read no push, free
  the slot and commit just before the pushing one started a session on it, leaving a running
  session with no slot — which the heal sweep cannot find, because it only looks at
  UNRELEASED rows.

  A winning push also refreshes `wall_clock_seconds` to the clock of the dispatch actually
  delivered, which is what `Loopctl.Runners.Capacity.heal/3` bounds an accepted session by.
  Recorded here rather than in `record_sent/3` because a re-send that is then DROPPED must
  not move the bound of a session an earlier push started.
  """
  @spec record_push(Ecto.UUID.t(), map()) ::
          {:ok, :pushed | {:already, String.t()}}
          | {:error, :unknown_dispatch | :capacity_busy}
  def record_push(tenant_id, dispatch), do: decide_delivery(tenant_id, dispatch, "pushed")

  @doc """
  Takes the delivery decision for a dispatch a channel is DROPPING instead of pushing, and
  gives its slot back in the same transaction when it wins: `{:ok, :released}`,
  `{:ok, {:already, outcome}}` when a push (or another drop) got there first, or
  `{:error, :capacity_busy}`.

  A drop that loses to a push releases nothing — that slot is holding a session. A drop whose
  own decision could not be recorded is left to the heal sweep's undelivered grace rather
  than to a second wait inside the channel process, which holds the runner's socket.
  """
  @spec record_drop(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, :released | {:already, String.t()}}
          | {:error, :unknown_dispatch | :capacity_busy}
  def record_drop(tenant_id, dispatch_id),
    do:
      decide_delivery(tenant_id, %{dispatch_id: dispatch_id, wall_clock_seconds: nil}, "dropped")

  @doc """
  `record_push/2` and `record_drop/2` inside the CALLER's transaction, on the caller's repo:
  the compare-and-set on `delivery` and, for a drop that wins, the release. Returns
  `:pushed` | `:released` | `{:already, outcome}`, and raises `Ecto.NoResultsError` semantics
  through `nil` — a caller inside its own transaction handles a missing row itself.

  The caller owns the transaction and its lock timeout; `record_push/2` and `record_drop/2`
  are the forms that own one of their own. Public because the decision is the ONE ordering
  point between a push and a drop, so a test must be able to hold it open.
  """
  @spec decide_delivery_in(Ecto.Repo.t(), Ecto.UUID.t(), map(), String.t()) ::
          :pushed | :released | {:already, String.t()} | nil
  def decide_delivery_in(repo, tenant_id, dispatch, outcome) do
    now = DateTime.utc_now()

    query =
      from r in DispatchRecord,
        where: r.tenant_id == ^tenant_id and r.dispatch_id == ^dispatch.dispatch_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      nil -> nil
      %DispatchRecord{delivery: nil} = row -> decide(repo, row, outcome, dispatch, now)
      %DispatchRecord{delivery: decided} -> {:already, decided}
    end
  end

  defp decide_delivery(tenant_id, dispatch, outcome) do
    in_tenant(tenant_id, fn ->
      Capacity.set_lock_timeout!(Repo)

      case decide_delivery_in(Repo, tenant_id, dispatch, outcome) do
        nil -> Repo.rollback(:unknown_dispatch)
        result -> result
      end
    end)
  rescue
    error in Postgrex.Error ->
      if Capacity.retryable?(error),
        do: {:error, :capacity_busy},
        else: reraise(error, __STACKTRACE__)
  end

  defp decide(repo, %DispatchRecord{} = record, "pushed", dispatch, now) do
    {1, _} =
      from(d in DispatchRecord, where: d.id == ^record.id and d.tenant_id == ^record.tenant_id)
      |> repo.update_all(
        set: [
          delivery: "pushed",
          pushed_at: now,
          wall_clock_seconds: dispatch.wall_clock_seconds,
          updated_at: now
        ]
      )

    :pushed
  end

  defp decide(repo, %DispatchRecord{} = record, "dropped", _dispatch, now) do
    {1, _} =
      from(d in DispatchRecord, where: d.id == ^record.id and d.tenant_id == ^record.tenant_id)
      |> repo.update_all(set: [delivery: "dropped", updated_at: now])

    Capacity.release(repo, record, record.slot_generation, now)
    :released
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
  Whether `runner_id` has told this tenant it does not do `kind` — a `dispatch_reply` refused
  with `kind_not_supported` (contract 1.5.0).

  The memory is DERIVED from the ledger rather than kept in a column, and that is the whole
  design decision. The ledger already records every reply with its reason, keyed by exactly
  the pair the statement is about (`runner_id`, `kind`), so the evidence and the conclusion
  cannot drift apart, no migration is needed, and there is no second place to forget to
  clear. A capability that CHANGES — the machine is upgraded and now does the kind — is
  cleared the way a runner's other bindings are: revoke and re-enroll, which mints a new
  `runners` row that no reply refers to. A column would have to be un-set by hand instead,
  and a stale one would silently starve a machine that had gained the capability.

  What deriving it COSTS, stated plainly because "no second place to forget to clear"
  understates it: the memory's lifetime is now this TABLE's retention. Nothing prunes
  `runner_dispatches` today, and the day something does, these rows must be excluded or the
  memory resets on a schedule. The invariant is in the moduledoc's Retention section and a
  source scan asserts it — read it before adding a pruner.

  It is a statement about capability, not health: a refusal releases its slot in the same
  transaction that records it, and nothing in loopctl reads a refusal as a runner being
  unwell. This read is what keeps loopctl from asking the same machine the same impossible
  question again.

  Served by the PARTIAL index `runner_dispatches_unsupported_kind_idx` on
  `(tenant_id, runner_id, kind) WHERE status = 'refused' AND reason = 'kind_not_supported'`
  (migration `20260919100000`), so the common NO-MATCH answer costs a lookup rather than a
  scan of every dispatch the runner ever held — which is what it cost on the general
  `(tenant_id, runner_id)` index, on the dispatch hot path, in a table with no retention.

  The `status` predicate is defence in depth over an L2 invariant rather than the enforcement:
  the `runner_dispatches_reason_iff_refused` CHECK already makes a reason without a refusal
  impossible, which is why no test can turn that clause red — see the note on it in
  `dispatch_ledger_test.exs`.
  """
  @spec kind_unsupported?(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) :: boolean()
  def kind_unsupported?(tenant_id, runner_id, kind)
      when is_binary(tenant_id) and is_binary(runner_id) and is_binary(kind) do
    {:ok, unsupported?} =
      in_tenant(tenant_id, fn ->
        Repo.exists?(
          from r in DispatchRecord,
            where: r.tenant_id == ^tenant_id and r.runner_id == ^runner_id,
            # LITERALS, never pinned variables or module attributes with `^`. Ecto inlines a
            # literal into the SQL, so Postgres sees `status = 'refused'` as a constant and can
            # PROVE the partial index's predicate covers this query. Pinned, the same values
            # arrive as bind parameters, the proof fails, and the planner falls back to a
            # sequential scan — the index becomes dead weight and nothing anywhere goes red.
            # Verified against the planner: literals use the index, bind parameters do not.
            where: r.kind == ^kind and r.status == "refused",
            where: r.reason == "kind_not_supported"
        )
      end)

    unsupported?
  end

  @doc """
  Every kind each of a tenant's runners has refused with `kind_not_supported`, as
  `%{runner_id => [kind]}`. Runners that have refused nothing are absent.

  The OPERATOR's view of what each machine has actually REFUSED, and the reason it exists:
  `implement` is the only dispatchable kind today, so ONE `kind_not_supported` reply removes an
  UNDECLARING machine from all work for the life of its `runners` row. With nothing exposing
  it, an operator sees a connected, unrevoked, idle runner that silently never gets work — and
  a runner that maps a transient local condition to that reason bricks itself. Surfaced on
  `GET /api/v1/runners` and `GET /api/v1/runners/pool`, it is one line of output away instead
  of a database session.

  Since contract 1.6.0 a row here is no longer the last word on what a runner will be sent:
  a runner that declares its kinds on join (`RunnerJoin.kinds`) is decided by that declaration
  and this record is not read for it (`Loopctl.Runners.dispatch/3`, step 6). So a kind listed
  here for a DECLARING runner is history — what it refused before — rather than a statement
  about the next dispatch, and re-enrolment is no longer the way to clear one: reconnecting
  with the kind declared is. The record is kept for both audiences: it is the audit trail of
  the refusal, and it is still the whole decision for a runner that declares nothing.

  One grouped query for the whole tenant, so a list of runners costs one round trip rather
  than one each, and served by the same partial index as `kind_unsupported?/3` — including
  its dependence on the predicate values staying LITERALS; see the comment there.
  """
  @spec unsupported_kinds(Ecto.UUID.t()) :: %{Ecto.UUID.t() => [String.t()]}
  def unsupported_kinds(tenant_id) when is_binary(tenant_id) do
    {:ok, pairs} =
      in_tenant(tenant_id, fn ->
        Repo.all(
          # Literals for the same reason as `kind_unsupported?/3` — pinning them makes the
          # partial index unusable and turns this into a scan of the tenant's whole history.
          from r in DispatchRecord,
            where: r.tenant_id == ^tenant_id and r.status == "refused",
            where: r.reason == "kind_not_supported",
            distinct: true,
            select: {r.runner_id, r.kind}
        )
      end)

    pairs
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {runner_id, kinds} -> {runner_id, Enum.sort(kinds)} end)
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
  The session a runner is running under `dispatch_id`: `{:ok, %{story_id:, claim_epoch:,
  slot_generation:}}` for an ACCEPTED dispatch this runner holds in this tenant.

  For the `stage` path (#803, contract 1.4.0), which needs the story the dispatch is for and
  the slot generation to release when the session ends. It is a READ and takes no lock: the
  three values it returns are all final from the dispatch's acceptance onward — `story_id`
  is written with the row and never changed, an accepted dispatch is never re-sent so its
  `slot_generation` cannot advance, and `claim_epoch` is the row's, which nothing rewrites.
  The authoritative fence is still the STORY's epoch, taken under a share lock inside
  `Loopctl.Delivery.Stages.advance/4`'s own transaction; this one only refuses a message
  whose epoch does not even match the dispatch it names, before that transaction is opened.

  `:unknown_dispatch` for a row another runner or another tenant holds, exactly as for one
  that does not exist. `:dispatch_not_accepted` for a row still `sent`, `refused` or
  `superseded`: no session is running, so there is no transition to report.
  """
  @spec accepted_session(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, %{story_id: Ecto.UUID.t(), claim_epoch: integer(), slot_generation: integer()}}
          | {:error, :unknown_dispatch | :dispatch_not_accepted}
  def accepted_session(tenant_id, runner_id, dispatch_id) do
    {:ok, result} =
      in_tenant(tenant_id, fn ->
        Repo.one(
          from r in DispatchRecord,
            where: r.tenant_id == ^tenant_id and r.runner_id == ^runner_id,
            where: r.dispatch_id == ^dispatch_id,
            select: %{
              status: r.status,
              story_id: r.story_id,
              claim_epoch: r.claim_epoch,
              slot_generation: r.slot_generation
            }
        )
      end)

    case result do
      nil -> {:error, :unknown_dispatch}
      %{status: "accepted"} = row -> {:ok, Map.delete(row, :status)}
      %{} -> {:error, :dispatch_not_accepted}
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

  @doc """
  Deletes one tenant's trace events past `cutoff` whose dispatch is terminal, oldest first,
  in batches of `:batch_size` up to `:budget` rows. See "Retention" in the moduledoc.

  Returns `%{deleted: n, budget_exhausted: bool, error: nil | term()}`. `budget_exhausted`
  means eligible rows were LEFT — it is probed, not inferred from arithmetic, so a tenant
  that lands exactly on its budget with nothing left reports `false`. The next run resumes
  where this one stopped, because candidates are ordered by age and nothing puts a pruned row
  back.

  **It does not raise.** A batch that faults returns with the fault in `:error` AND the count
  of everything the earlier batches committed, because those are the batches a long run makes
  most of: raising would report zero deleted on exactly the run that deleted the most. The
  caller decides what a fault means.

  Each batch is its OWN transaction, with its own `statement_timeout` and `lock_timeout`, so
  nothing here holds a transaction open across a large delete and a run interrupted between
  batches leaves every earlier batch committed. Candidate rows are taken
  `FOR UPDATE SKIP LOCKED`, so two overlapping runs prune disjoint sets instead of one
  waiting on the other, and neither double-counts.

  `opts` (`:batch_size`, `:budget`) are an INTERNAL contract and are not validated here —
  `Loopctl.Workers.DeliveryLoopPruneWorker` validates everything an operator can supply
  before it reaches them.
  """
  @spec prune_trace_events(Ecto.UUID.t(), DateTime.t(), keyword()) ::
          %{deleted: non_neg_integer(), budget_exhausted: boolean(), error: nil | term()}
  def prune_trace_events(tenant_id, %DateTime{} = cutoff, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @prune_batch_size)
    budget = Keyword.get(opts, :budget, @prune_budget)

    prune_loop(tenant_id, cutoff, batch_size, budget, 0)
  end

  # The ONE stop: reaching the budget ends the run. Every batch recurses through here,
  # including the one that lands exactly on the budget, so this clause is the only place
  # `budget_exhausted` becomes true and a test can reach it. It PROBES for a further candidate
  # rather than assuming one — a tenant with exactly `budget` eligible rows has none left, and
  # reporting that as "budget reached, rows left" is a false positive on the one signal an
  # operator alerts on.
  # The probe reads WITHOUT the row lock: it decides a report, so it must not take locks a
  # concurrent run would then skip, and under `SKIP LOCKED` the answer would depend on what
  # another run happens to hold rather than on what exists.
  defp prune_loop(tenant_id, cutoff, _batch_size, budget, deleted) when deleted >= budget do
    case attempt(tenant_id, fn ->
           tenant_id
           |> prunable_events(cutoff, 1)
           |> exclude(:lock)
           |> Repo.exists?()
         end) do
      # A probe that could not run cannot say the backlog is empty, so it says it is not.
      {:ok, more?} -> %{deleted: deleted, budget_exhausted: more?, error: nil}
      {:error, error} -> %{deleted: deleted, budget_exhausted: true, error: error}
    end
  end

  defp prune_loop(tenant_id, cutoff, batch_size, budget, deleted) do
    take = min(batch_size, budget - deleted)

    batch =
      attempt(tenant_id, fn ->
        delete_events(tenant_id, Repo.all(prunable_events(tenant_id, cutoff, take)))
      end)

    case batch do
      {:ok, 0} -> %{deleted: deleted, budget_exhausted: false, error: nil}
      {:ok, count} -> prune_loop(tenant_id, cutoff, batch_size, budget, deleted + count)
      {:error, error} -> %{deleted: deleted, budget_exhausted: false, error: error}
    end
  end

  # One batch, or the probe, RETURNING its fault instead of raising it. Raising would throw
  # away the count of everything the earlier batches already COMMITTED, and those batches are
  # the ones a long run makes most of: the caller would report zero deleted on exactly the run
  # that deleted the most.
  defp attempt(tenant_id, fun) do
    {:ok, bounded(tenant_id, fun)}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # One batch, or the probe: its own RLS transaction under its own bounded timeouts, scoped by
  # `LocalGuc` so neither outlives it. Both GUCs are set in ONE round trip.
  defp bounded(tenant_id, fun) do
    {:ok, result} =
      in_tenant(tenant_id, fn ->
        LocalGuc.scoped(Repo, ["statement_timeout", "lock_timeout"], fn ->
          Repo.query!(
            "SELECT set_config('statement_timeout', $1, true), set_config('lock_timeout', $2, true)",
            ["#{@prune_statement_timeout_ms}ms", "#{Capacity.lock_timeout_ms()}ms"]
          )

          fun.()
        end)
      end)

    result
  end

  defp delete_events(_tenant_id, []), do: 0

  defp delete_events(tenant_id, ids) do
    {count, _} =
      Repo.delete_all(from(e in TraceEvent, where: e.tenant_id == ^tenant_id and e.id in ^ids))

    count
  end

  # A batch of one tenant's prunable event ids, oldest first. `released_at` is the terminality
  # test: a dispatch still holding its slot may still be running, and its trace is kept
  # whatever its age. `SKIP LOCKED` makes two concurrent runs disjoint rather than serial.
  #
  # SELECTED first and deleted by id in a SECOND statement of the SAME transaction, never as
  # `DELETE ... WHERE id IN (this)`. The `FOR UPDATE` makes the subquery non-hashable, so the
  # planner may re-execute it once per candidate row — and under `SKIP LOCKED` each execution
  # returns a DIFFERENT set, so one statement deletes a multiple of `limit`. It is
  # plan-dependent, so it passed the file's own tests and failed in the full suite: the budget
  # tests caught a run of 4 against a budget of 2. The row locks this statement takes are held
  # until the transaction commits, so the delete that follows still sees exactly this set.
  defp prunable_events(tenant_id, cutoff, limit) do
    terminal_dispatch =
      from d in DispatchRecord,
        where: d.tenant_id == parent_as(:prunable).tenant_id,
        where: d.id == parent_as(:prunable).runner_dispatch_id,
        where: not is_nil(d.released_at),
        select: 1

    from e in TraceEvent,
      as: :prunable,
      where: e.tenant_id == ^tenant_id,
      where: e.inserted_at < ^cutoff,
      where: exists(terminal_dispatch),
      order_by: [asc: e.inserted_at],
      limit: ^limit,
      lock: "FOR UPDATE SKIP LOCKED",
      select: e.id
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
  # seq 0 on every batch. Every seq up to `acked` was STORED at the moment the cursor reached
  # it (the invariant), and the cursor is a column on this row, never recomputed from the
  # events. If `acked + 1` is not stored the cursor stays; otherwise the new cursor is the
  # first stored seq at or after it whose successor is missing — every seq in between has its
  # successor, so the whole stretch is contiguous. The row lock serialises batches of one run.
  #
  # Retention (`prune_trace_events/3`) may DELETE stored seqs at or below `acked`, so the
  # invariant is about what was stored, not about what is still there. Nothing here reads
  # below `acked + 1` and the cursor never moves backwards, so a pruned event cannot lower an
  # ack or make a runner resend. Do not "simplify" this into a scan from seq 0 — with
  # retention behind it, that would reset a live run's cursor to -1.
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
