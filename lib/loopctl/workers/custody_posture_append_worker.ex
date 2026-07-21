defmodule Loopctl.Workers.CustodyPostureAppendWorker do
  @moduledoc """
  US-41.7 (AC-41.7.7) — appends a BATCH of recorded egress postures into the
  tenant's hash-chained audit log.

  ## Why a batch job and not a synchronous append

  `Loopctl.AuditChain.append/2` runs a `SELECT ... FOR UPDATE`-serialized `Multi`
  on `Loopctl.AdminRepo`, whose pool is **3 connections** (`ADMIN_POOL_SIZE`,
  `config/runtime.exs`) shared with all admin work. A harvest writes many
  articles; one synchronous append per article would put N serialized round-trips
  through that 3-connection pool — the documented outage mode that forced
  `HeavyReadRepo` into existence. So the content transaction only inserts a cheap
  outbox row, and THIS job performs exactly ONE chain append per batch.

  ## Uniqueness and debounce

  Unique per `tenant_id` across every schedulable state, inserted with a debounce
  delay. A bulk harvest of N articles therefore collapses to one in-flight job
  (and one append) per window, regardless of N.

  ## Idempotency

  Replaying a partially-succeeded batch is a NO-OP:

    * the batch id is derived DETERMINISTICALLY from the Oban job id, so a retry
      claims the same rows;
    * `(tenant_id, subject_type, subject_id, operation_sequence)` is UNIQUE, so
      no entry can be duplicated;
    * the flush looks the batch's chain entry up by `entity_id` before appending,
      so a retry after a committed append + lost bookkeeping update finishes the
      bookkeeping instead of appending a second entry into an append-only,
      later-signed structure.

  ## Failure is surfaced, not swallowed

  On the FINAL attempt the batch's still-pending entries are marked `failed` with
  the reason, which degrades the row's claim to `incomplete` (never to a
  satisfied attestation) and puts it on `Loopctl.Custody.list_failures/2`.
  """

  use Oban.Worker,
    queue: :audit,
    max_attempts: 5,
    unique: [
      keys: [:tenant_id],
      period: 300,
      # DELIBERATELY EXCLUDES `:executing`. A flush claims the rows that are
      # pending AT THE MOMENT IT RUNS; a row inserted while a flush is executing
      # is NOT in that claim, so it needs its own job. Including `:executing` here
      # would dedupe that insert against the in-flight job and strand the row
      # pending forever with nothing scheduled to flush it — which the claim
      # reader would correctly (but permanently) report as `claim_pending`.
      states: [:available, :scheduled, :retryable]
    ]

  require Logger

  alias Loopctl.Custody

  @impl Oban.Worker
  def perform(%Oban.Job{id: id, attempt: attempt, max_attempts: max, args: args}) do
    tenant_id = Map.fetch!(args, "tenant_id")
    batch_id = Custody.batch_id(id)

    case Custody.flush_batch(tenant_id, batch_id) do
      {:ok, _count} ->
        :ok

      {:error, reason} when attempt >= max ->
        # Last attempt: record the drop so a missing claim can never read as a
        # satisfied one (AC-41.7.7).
        #
        # A STABLE CODE plus a correlation id — never `inspect(reason)`. The raw
        # term is typically a %Postgrex.Error{} (whose inspect renders the postgres
        # message/detail/hint/constraint, and for some classes the offending
        # statement) or an %Ecto.Changeset{} carrying rejected values, and this
        # string is served verbatim to :agent-role callers via GET
        # /custody/failures and via an incomplete claim's `failure_reason`. The raw
        # term stays in the Logger.error below.
        Custody.mark_batch_failed(tenant_id, batch_id, Custody.failure_reason(reason, id))

        Logger.error(
          "CustodyPostureAppendWorker: tenant=#{tenant_id} batch=#{batch_id} chain append " <>
            "exhausted retries (#{inspect(reason)}); entries marked failed"
        )

        {:discard, {:custody_append_failed, inspect(reason)}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
