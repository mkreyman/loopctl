defmodule Loopctl.Custody do
  @moduledoc """
  US-41.7 — egress posture as a WITNESSED CUSTODY CLAIM in the existing audit
  chain / STH.

  Epic 26 gave loopctl a hash-chained, append-only audit chain with signed tree
  heads and a witness protocol; it answers *who did this work*. This module
  extends the SAME structure — no parallel signing scheme (AC-41.7.4) — to answer
  *where did the data go*.

  ## The shape of a claim

  A claim is an APPEND-ONLY SEQUENCE of per-operation postures bound to one
  article or memory row (AC-41.7.1). Every content-touching operation — the
  create/extract, each embedding, each re-embed, each classification or merge —
  appends its own entry recording the posture RESOLVED for THAT operation: the
  embedding endpoint and its classification, the chat endpoint and its
  classification, `local_only`, `encrypt_body`, and a timestamp. A single
  write-time snapshot would be falsified the moment an async embedding job or an
  agent-triggered re-embed shipped the body somewhere else.

  ## Completeness is PROVEN, never assumed (AC-41.7.2)

  The chain append is asynchronous (see the hot-path budget below), so "the
  entries I can see are all the entries there were" is exactly the assumption an
  ordinary lost Oban job would falsify — silently converting an operation that
  DID egress into a satisfied zero-egress attestation. Instead:

    * `assign/5` inserts the entry INSIDE the content transaction, which is what
      allocates the monotonic per-row `operation_sequence`;
    * `claim/3` requires the entries to form a CONTIGUOUS `0..max` sequence.

  Any gap — a batch job that exhausted retries or was discarded, a deleted row, a
  node that died between the provider call and the flush — degrades the aggregate
  to `incomplete`, NEVER to no-third-party-egress.

  ## Three states, not two (AC-41.7.8)

    * `no_claim_recorded` — no sequence was ever assigned (a row written before
      this story, or one in a scope with no `local_only` marking).
    * `claim_pending` — sequence numbers exist but one or more batch appends have
      not flushed; the payload carries the pending count and the batch references.
    * `claim_recorded` — a complete sequence, itself qualified `complete` or
      `incomplete`.

  None of these may be read as a positive attestation unless it is
  `claim_recorded` + `complete` + every entry local.

  ## Hot-path budget (AC-41.7.7)

  `Loopctl.AuditChain.append/2` runs a `SELECT ... FOR UPDATE`-serialized `Multi`
  on `Loopctl.AdminRepo`, whose pool is **3 connections** (`ADMIN_POOL_SIZE`,
  `config/runtime.exs`) shared with all admin work — saturating it is the
  documented outage mode that forced `HeavyReadRepo` into existence. A harvest
  writes many articles, which is precisely that load profile. So the WRITE PATH IS:

      content transaction: 1 INSERT into `custody_posture_entries` (no chain work)
        -> debounced, per-tenant unique Oban job (`audit` queue)
          -> ONE `AuditChain.append/2` per BATCH, not per article

  There is NEVER a synchronous per-article chain round-trip.

  ## Idempotency (AC-41.7.7)

  `(tenant_id, subject_type, subject_id, operation_sequence)` is UNIQUE, so a
  retry cannot duplicate an entry; and `flush_batch/2` re-derives its batch id
  deterministically from the Oban job id and skips the append when a chain entry
  for that batch already exists. Replaying a partially-succeeded batch is a
  no-op: no duplicate entries, chain and STH unchanged.

  ## Wording (AC-41.7.6)

  Every string this module emits is scoped to *the endpoints loopctl called for
  the recorded operations on this row*. It never claims anything about what those
  endpoints did with the data afterwards, and it never emits an unqualified
  zero-third-party-egress claim while coverage is partial.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Adapters.SQL
  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.Custody.PostureEntry
  alias Loopctl.Egress
  alias Loopctl.Egress.Scope
  alias Loopctl.Workers.CustodyPostureAppendWorker

  @chain_action "custody_posture_batch_recorded"
  @chain_entity_type "custody_posture_batch"

  @attestation_scope "This claim attests ONLY to the endpoints loopctl called for the " <>
                       "recorded operations on this row, on the covered egress paths listed " <>
                       "in `coverage`. It makes NO statement about what those endpoints did " <>
                       "with the data afterwards, and none about egress paths not listed as " <>
                       "covered."

  @uncovered_reasons %{
    webhook_delivery:
      "Webhook delivery is enforced by the same fail-closed egress policy since US-41.5, " <>
        "but it is not a content-touching operation on this row, so no per-row posture " <>
        "entry is recorded for it and this claim does not cover it.",
    ingestion_fetch:
      "The ingestion fetch is enforced by the same egress policy, but it is an INBOUND " <>
        "fetch rather than a per-row content-touching operation, so this claim does not " <>
        "cover it."
  }

  @all_known_paths [:provider_calls, :ingestion_fetch, :webhook_delivery]

  @doc """
  The operations that append a custody posture entry.

  `:create` is the write/extract, `:embed` the first vectorisation, `:reembed` an
  agent-triggered or model-change re-vectorisation (US-41.1 AC-41.1.10),
  `:classify` and `:merge` the LLM curation passes.
  """
  @spec operations() :: [atom()]
  def operations, do: [:create, :embed, :reembed, :classify, :merge]

  # ---------------------------------------------------------------------------
  # Recording (hot path)
  # ---------------------------------------------------------------------------

  @doc """
  Assigns the next `operation_sequence` for a row and records the posture
  RESOLVED right now for `operation`.

  Runs on `repo` so a caller inside a content transaction assigns the sequence
  INSIDE that transaction (AC-41.7.2) with no extra pool checkout.

  Returns `{:ok, %PostureEntry{}}`, `{:ok, :not_applicable}` when the scope
  carries no `local_only` marking (AC-41.7.8(a) — no sequence is ever assigned,
  which is what makes "no claim recorded" legible rather than ambiguous), or
  `{:error, reason}`.
  """
  @spec assign(Ecto.Repo.t(), Scope.t(), String.t(), Ecto.UUID.t(), atom()) ::
          {:ok, PostureEntry.t()} | {:ok, :not_applicable} | {:error, term()}
  def assign(repo, %Scope{} = scope, subject_type, subject_id, operation)
      when is_binary(subject_type) and is_binary(subject_id) do
    if claimable_scope?(scope) do
      do_assign(repo, scope, subject_type, subject_id, operation)
    else
      {:ok, :not_applicable}
    end
  end

  @doc """
  `assign/5` on `Loopctl.AdminRepo`, then enqueue the debounced batch flush.

  This is the entry point for a worker that is NOT already inside a content
  transaction (an embedding job, a re-embed, a classification pass). It never
  raises and never fails its caller: a posture-recording fault must not fail the
  operation it describes, and the resulting gap is surfaced as `incomplete` by
  `claim/3` rather than passing as a satisfied claim.
  """
  @spec record(Scope.t(), String.t(), Ecto.UUID.t(), atom()) ::
          {:ok, PostureEntry.t()} | {:ok, :not_applicable} | {:error, term()}
  def record(%Scope{} = scope, subject_type, subject_id, operation) do
    case assign(AdminRepo, scope, subject_type, subject_id, operation) do
      {:ok, %PostureEntry{}} = ok ->
        enqueue_flush(scope.tenant_id)
        ok

      other ->
        other
    end
  rescue
    e ->
      Logger.error("Loopctl.Custody: posture recording failed: #{Exception.message(e)}")
      {:error, :recording_failed}
  end

  @doc """
  Adds the sequence assignment to an existing `Ecto.Multi` so it commits with the
  content write, and schedules the batch flush after the transaction succeeds.

  The Multi step never fails the enclosing transaction: an assignment error is
  returned as `{:ok, {:error, reason}}` so the article write still lands, and the
  missing entry then shows up as a GAP (never as a satisfied claim).
  """
  @spec assign_in_multi(Multi.t(), atom(), Scope.t(), (map() -> Ecto.UUID.t()), atom()) ::
          Multi.t()
  def assign_in_multi(multi, name, %Scope{} = scope, subject_id_fun, operation)
      when is_function(subject_id_fun, 1) do
    Multi.run(multi, name, fn repo, changes ->
      case assign(repo, scope, "article", subject_id_fun.(changes), operation) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:ok, {:error, reason}}
      end
    end)
  end

  @doc """
  Enqueues the per-tenant, debounced batch flush.

  Unique per tenant across the schedulable states, so a bulk harvest of N
  articles produces ONE job (and therefore ONE `AdminRepo` chain append) per
  debounce window rather than N.
  """
  @spec enqueue_flush(Ecto.UUID.t()) :: :ok
  def enqueue_flush(tenant_id) when is_binary(tenant_id) do
    %{tenant_id: tenant_id}
    |> CustodyPostureAppendWorker.new(schedule_in: flush_debounce_seconds())
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Loopctl.Custody: flush enqueue failed: #{inspect(reason)}")
    end

    :ok
  end

  @doc "Seconds the batch flush is debounced by. Batching is the pool budget (AC-41.7.7)."
  @spec flush_debounce_seconds() :: non_neg_integer()
  def flush_debounce_seconds do
    Application.get_env(:loopctl, :custody_flush_debounce_seconds, 5)
  end

  # A posture entry is only assigned for a scope the tenant has actually marked
  # `local_only`. Recording for every unmarked tenant would bloat the chain with
  # entries nobody asked for, and AC-41.7.8(a) explicitly wants "a scope with no
  # local_only marking" to read as NO CLAIM RECORDED rather than as a claim.
  defp claimable_scope?(%Scope{} = scope) do
    Egress.effective_local_only?(scope)
  rescue
    _ -> false
  end

  # ONE statement: the `SELECT MAX(...) + 1` subquery allocates the next
  # per-row sequence, and the unique index rejects a concurrent duplicate (retried
  # once below). Every parameter is explicitly CAST — Postgres cannot deduce a
  # consistent type for a parameter used in both the INSERT target list and the
  # subquery predicate, and an ambiguous-parameter error inside the caller's
  # content transaction would poison it.
  @assign_sql """
  INSERT INTO custody_posture_entries
    (id, tenant_id, subject_type, subject_id, operation_sequence, operation,
     posture, local_endpoints_only, occurred_at, state, inserted_at, updated_at)
  SELECT $1::uuid, $2::uuid, $3::varchar, $4::uuid,
    COALESCE((SELECT MAX(operation_sequence) + 1 FROM custody_posture_entries
              WHERE tenant_id = $2::uuid AND subject_type = $3::varchar
                AND subject_id = $4::uuid), 0),
    $5::varchar, $6::jsonb, $7::boolean, $8::timestamptz, 'pending',
    $8::timestamptz, $8::timestamptz
  RETURNING id, operation_sequence
  """

  defp do_assign(repo, scope, subject_type, subject_id, operation, attempt \\ 1) do
    posture = Egress.operation_posture(scope)
    now = DateTime.utc_now()

    params = [
      Ecto.UUID.bingenerate(),
      dump_uuid!(scope.tenant_id),
      subject_type,
      dump_uuid!(subject_id),
      to_string(operation),
      posture,
      posture.local_endpoints_only,
      now
    ]

    case guarded_query(repo, @assign_sql, params) do
      # A concurrent assignment took the sequence number first. The unique index
      # is doing its job; re-read and take the next one. Bounded so a persistent
      # constraint problem surfaces as an error rather than a spin.
      {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} when attempt < 3 ->
        do_assign(repo, scope, subject_type, subject_id, operation, attempt + 1)

      {:ok, %{rows: [[id, sequence]]}} ->
        {:ok,
         %PostureEntry{
           id: load_uuid!(id),
           tenant_id: scope.tenant_id,
           subject_type: subject_type,
           subject_id: subject_id,
           operation_sequence: sequence,
           operation: to_string(operation),
           posture: posture,
           local_endpoints_only: posture.local_endpoints_only,
           occurred_at: now,
           state: "pending"
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Runs the assignment behind a SAVEPOINT when the caller is already inside a
  # transaction, so a failed INSERT rolls back only ITSELF. Without this, any
  # error here would abort the enclosing CONTENT transaction — i.e. a
  # posture-recording fault would destroy the article write it merely describes,
  # exactly inverting the priority. Outside a transaction the savepoint is
  # unnecessary (and illegal), so it is skipped.
  defp guarded_query(repo, sql, params) do
    if repo.in_transaction?() do
      savepoint = "custody_assign"

      case SQL.query(repo, "SAVEPOINT #{savepoint}", []) do
        {:ok, _} ->
          result = SQL.query(repo, sql, params)
          release_or_rollback(repo, savepoint, result)
          result

        {:error, _} = error ->
          error
      end
    else
      SQL.query(repo, sql, params)
    end
  end

  defp release_or_rollback(repo, savepoint, {:ok, _}) do
    SQL.query(repo, "RELEASE SAVEPOINT #{savepoint}", [])
  end

  defp release_or_rollback(repo, savepoint, {:error, _}) do
    SQL.query(repo, "ROLLBACK TO SAVEPOINT #{savepoint}", [])
  end

  defp dump_uuid!(uuid) do
    {:ok, dumped} = Ecto.UUID.dump(uuid)
    dumped
  end

  defp load_uuid!(binary) do
    {:ok, loaded} = Ecto.UUID.load(binary)
    loaded
  end

  # ---------------------------------------------------------------------------
  # Batch flush (Oban)
  # ---------------------------------------------------------------------------

  @doc """
  The DETERMINISTIC batch id for an Oban job id.

  Deterministic so a retry of the same job claims the SAME rows and looks up the
  SAME chain entry — which is what makes the replay a no-op instead of a second
  append into an append-only, later-signed structure.
  """
  @spec batch_id(integer() | nil) :: Ecto.UUID.t()
  # Oban's INLINE testing engine executes a job with no persisted id. There is no
  # retry in that mode (the job never enters the queue), so a fresh id is safe;
  # in every real mode the job id exists and the batch id is stable across
  # attempts, which is what makes the replay a no-op.
  def batch_id(nil), do: Ecto.UUID.generate()

  def batch_id(job_id) when is_integer(job_id) do
    <<raw::binary-size(16), _rest::binary>> =
      :crypto.hash(:sha256, "custody-posture-batch:" <> Integer.to_string(job_id))

    load_uuid!(raw)
  end

  @doc """
  Flushes one batch: claim the tenant's pending entries, append ONE audit-chain
  entry covering them, mark them recorded.

  Idempotent on replay (AC-41.7.7). Returns `{:ok, count}` or `{:error, reason}`.
  """
  @spec flush_batch(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def flush_batch(tenant_id, batch_id) do
    claim_pending(tenant_id, batch_id)

    case batch_entries(tenant_id, batch_id) do
      [] ->
        {:ok, 0}

      entries ->
        append_batch(tenant_id, batch_id, entries)
    end
  end

  defp claim_pending(tenant_id, batch_id) do
    from(e in PostureEntry,
      where:
        e.tenant_id == ^tenant_id and e.state == "pending" and
          (is_nil(e.batch_id) or e.batch_id == ^batch_id)
    )
    |> AdminRepo.update_all(set: [batch_id: batch_id, updated_at: DateTime.utc_now()])
  end

  defp batch_entries(tenant_id, batch_id) do
    from(e in PostureEntry,
      where: e.tenant_id == ^tenant_id and e.batch_id == ^batch_id and e.state == "pending",
      order_by: [asc: e.subject_id, asc: e.operation_sequence]
    )
    |> AdminRepo.all()
  end

  defp append_batch(tenant_id, batch_id, entries) do
    case existing_batch_entry(tenant_id, batch_id) do
      nil ->
        payload = %{
          "batch_id" => batch_id,
          "entries" => Enum.map(entries, &chain_payload_entry/1)
        }

        case AuditChain.append(tenant_id, %{
               action: @chain_action,
               actor_lineage: [],
               entity_type: @chain_entity_type,
               entity_id: batch_id,
               payload: payload
             }) do
          {:ok, chain_entry} ->
            mark_recorded(tenant_id, batch_id, chain_entry)
            {:ok, length(entries)}

          {:error, reason} ->
            {:error, reason}
        end

      chain_entry ->
        # The append already committed on a previous attempt; only the bookkeeping
        # update was lost. Finish it — do NOT append a second entry.
        mark_recorded(tenant_id, batch_id, chain_entry)
        {:ok, length(entries)}
    end
  end

  defp existing_batch_entry(tenant_id, batch_id) do
    from(e in AuditChain.Entry,
      where:
        e.tenant_id == ^tenant_id and e.entity_type == ^@chain_entity_type and
          e.entity_id == ^batch_id,
      limit: 1
    )
    |> AdminRepo.one()
  end

  defp chain_payload_entry(%PostureEntry{} = entry) do
    %{
      "subject_type" => entry.subject_type,
      "subject_id" => entry.subject_id,
      "operation_sequence" => entry.operation_sequence,
      "operation" => entry.operation,
      "local_endpoints_only" => entry.local_endpoints_only,
      "occurred_at" => DateTime.to_iso8601(entry.occurred_at),
      "posture" => entry.posture
    }
  end

  defp mark_recorded(tenant_id, batch_id, chain_entry) do
    from(e in PostureEntry,
      where: e.tenant_id == ^tenant_id and e.batch_id == ^batch_id and e.state == "pending"
    )
    |> AdminRepo.update_all(
      set: [
        state: "recorded",
        chain_entry_id: chain_entry.id,
        chain_position: chain_entry.chain_position,
        recorded_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      ]
    )
  end

  @doc """
  Marks a batch's still-pending entries FAILED after the flush job exhausted its
  attempts.

  A failure to record must be SURFACED, never silently dropped (AC-41.7.7): a
  failed entry degrades the aggregate to `incomplete` and appears on
  `list_failures/2`.
  """
  @spec mark_batch_failed(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) :: {non_neg_integer(), nil}
  def mark_batch_failed(tenant_id, batch_id, reason) do
    from(e in PostureEntry,
      where: e.tenant_id == ^tenant_id and e.batch_id == ^batch_id and e.state == "pending"
    )
    |> AdminRepo.update_all(
      set: [
        state: "failed",
        failure_reason: String.slice(reason, 0, 500),
        updated_at: DateTime.utc_now()
      ]
    )
  end

  @doc "Entries whose chain append was dropped — the failure surface (AC-41.7.7)."
  @spec list_failures(Ecto.UUID.t(), keyword()) :: [PostureEntry.t()]
  def list_failures(tenant_id, opts \\ []) do
    from(e in PostureEntry,
      where: e.tenant_id == ^tenant_id and e.state == "failed",
      order_by: [desc: e.occurred_at],
      limit: ^Keyword.get(opts, :limit, 100)
    )
    |> AdminRepo.all()
  end

  @doc "Every recorded entry for one row, in sequence order."
  @spec list_entries(Ecto.UUID.t(), String.t(), Ecto.UUID.t()) :: [PostureEntry.t()]
  def list_entries(tenant_id, subject_type, subject_id) do
    from(e in PostureEntry,
      where:
        e.tenant_id == ^tenant_id and e.subject_type == ^subject_type and
          e.subject_id == ^subject_id,
      order_by: [asc: e.operation_sequence]
    )
    |> AdminRepo.all()
  end

  # ---------------------------------------------------------------------------
  # Read surface (AC-41.7.5)
  # ---------------------------------------------------------------------------

  @doc """
  The custody claim for one article or memory row.

  Returns one of the three AC-41.7.8 states. `zero_third_party_egress` is
  reported ONLY for a `claim_recorded` + `complete` sequence in which every entry
  was local; it is always qualified by `coverage`, and by
  `attestation_scope`, which states exactly what the claim does and does not say.
  """
  @spec claim(Ecto.UUID.t(), String.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def claim(tenant_id, subject_type, subject_id) do
    if subject_type in PostureEntry.subject_types() do
      {:ok, build_claim(tenant_id, subject_type, subject_id)}
    else
      {:error, :invalid_subject_type}
    end
  end

  defp build_claim(tenant_id, subject_type, subject_id) do
    entries = list_entries(tenant_id, subject_type, subject_id)

    base = %{
      tenant_id: tenant_id,
      subject_type: subject_type,
      subject_id: subject_id,
      coverage: coverage(),
      attestation_scope: @attestation_scope,
      tenant_declared_label: Egress.tenant_declared_label()
    }

    Map.merge(base, claim_state(tenant_id, entries))
  end

  defp claim_state(_tenant_id, []) do
    %{
      claim_state: "no_claim_recorded",
      entries: [],
      summary:
        "No custody claim was recorded for this row. No operation sequence was ever " <>
          "assigned — either the row predates custody recording, or its scope carries no " <>
          "local_only marking. This is the ABSENCE of a claim: it asserts nothing about " <>
          "egress in either direction and must not be read as one."
    }
  end

  defp claim_state(tenant_id, entries) do
    max_sequence = entries |> Enum.map(& &1.operation_sequence) |> Enum.max()
    sequences = MapSet.new(entries, & &1.operation_sequence)
    contiguous? = Enum.all?(0..max_sequence, &MapSet.member?(sequences, &1))

    pending = Enum.filter(entries, &(&1.state == "pending"))
    failed = Enum.filter(entries, &(&1.state == "failed"))

    rendered = Enum.map(entries, &render_entry/1)
    endpoints = involved_endpoints(entries)

    cond do
      not contiguous? or failed != [] ->
        incomplete_claim(entries, rendered, endpoints, max_sequence, contiguous?, failed)

      pending != [] ->
        pending_claim(tenant_id, rendered, pending, endpoints, max_sequence)

      true ->
        complete_claim(entries, rendered, endpoints, max_sequence)
    end
  end

  defp incomplete_claim(_entries, rendered, endpoints, max_sequence, contiguous?, failed) do
    %{
      claim_state: "claim_recorded",
      completeness: "incomplete",
      third_party_egress_on_covered_paths: "unknown",
      highest_assigned_sequence: max_sequence,
      contiguous: contiguous?,
      failed_entries: Enum.map(failed, &render_entry/1),
      entries: rendered,
      endpoints_involved: endpoints,
      summary:
        "INCOMPLETE. The recorded operation sequence for this row has a gap or a dropped " <>
          "append, so loopctl cannot prove it recorded every content-touching operation. " <>
          "An incomplete sequence is NEVER reported as no-third-party-egress: an " <>
          "unrecorded operation may have called any endpoint."
    }
  end

  defp pending_claim(tenant_id, rendered, pending, endpoints, max_sequence) do
    %{
      claim_state: "claim_pending",
      completeness: "pending",
      third_party_egress_on_covered_paths: "unknown",
      highest_assigned_sequence: max_sequence,
      pending_entry_count: length(pending),
      batch_refs: pending |> Enum.map(& &1.batch_id) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      enqueued_batch_refs: enqueued_batch_refs(tenant_id),
      entries: rendered,
      endpoints_involved: endpoints,
      summary:
        "PENDING. Operation sequence numbers are assigned for this row but one or more " <>
          "batch appends have not yet been written into the audit chain. This is NOT an " <>
          "attestation, and it is NOT 'no claim recorded' — the claim exists and is in " <>
          "flight."
    }
  end

  defp complete_claim(entries, rendered, endpoints, max_sequence) do
    all_local? = Enum.all?(entries, & &1.local_endpoints_only)

    summary =
      if all_local? do
        "COMPLETE. Over a contiguous sequence of #{max_sequence + 1} recorded operations, " <>
          "every endpoint loopctl called on the covered egress paths was classified local " <>
          "for this scope, so loopctl made no third-party call on those paths while " <>
          "producing this row. See `coverage` for which paths that is and " <>
          "`attestation_scope` for what this does not say."
      else
        "COMPLETE, MIXED. Over a contiguous sequence of #{max_sequence + 1} recorded " <>
          "operations, at least one endpoint loopctl called was NOT classified local for " <>
          "this scope. See `endpoints_involved` for the endpoints and their " <>
          "classifications."
      end

    %{
      claim_state: "claim_recorded",
      completeness: "complete",
      third_party_egress_on_covered_paths: not all_local?,
      posture: if(all_local?, do: "all_local", else: "mixed"),
      highest_assigned_sequence: max_sequence,
      contiguous: true,
      entries: rendered,
      endpoints_involved: endpoints,
      summary: summary
    }
  end

  defp render_entry(%PostureEntry{} = entry) do
    %{
      operation_sequence: entry.operation_sequence,
      operation: entry.operation,
      state: entry.state,
      local_endpoints_only: entry.local_endpoints_only,
      occurred_at: entry.occurred_at,
      posture: entry.posture,
      chain_position: entry.chain_position,
      chain_entry_id: entry.chain_entry_id,
      failure_reason: entry.failure_reason
    }
  end

  # Every DISTINCT endpoint that appears in the sequence, with the classification
  # recorded at the time it was called (AC-41.7.5: "if not, which endpoints were
  # involved").
  defp involved_endpoints(entries) do
    entries
    |> Enum.flat_map(fn entry ->
      entry.posture
      |> Map.get("endpoints", Map.get(entry.posture, :endpoints, []))
      |> List.wrap()
    end)
    |> Enum.map(&stringify_endpoint/1)
    |> Enum.uniq()
  end

  defp stringify_endpoint(endpoint) when is_map(endpoint) do
    %{
      kind: fetch_any(endpoint, :kind),
      endpoint: fetch_any(endpoint, :endpoint),
      host: fetch_any(endpoint, :host),
      verdict: fetch_any(endpoint, :verdict),
      local: fetch_any(endpoint, :local)
    }
  end

  defp fetch_any(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  # Oban job ids of the flush batches currently scheduled for this tenant. The
  # pending payload names them so a reader between the content write and the flush
  # can point at the work it is waiting on (AC-41.7.8(b)).
  defp enqueued_batch_refs(tenant_id) do
    from(j in "oban_jobs",
      where:
        j.worker == "Loopctl.Workers.CustodyPostureAppendWorker" and
          j.state in ["available", "scheduled", "executing", "retryable"] and
          fragment("?->>'tenant_id' = ?", j.args, ^tenant_id),
      select: j.id,
      limit: 20
    )
    |> Loopctl.Repo.all()
    |> Enum.map(&batch_id/1)
  rescue
    _ -> []
  end

  # ---------------------------------------------------------------------------
  # Coverage (AC-41.7.6)
  # ---------------------------------------------------------------------------

  @doc """
  The explicit COVERAGE field: which egress paths this attestation covers, which
  it does not, and why.

  `complete?` is false whenever any known path is uncovered — and the claim's own
  wording stays qualified ("on the covered egress paths") in BOTH cases, so the
  surface never emits an unqualified zero-third-party-egress claim.
  """
  @spec coverage() :: map()
  def coverage do
    covered = coverage_source().covered_paths()
    uncovered = Enum.reject(@all_known_paths, &(&1 in covered))

    %{
      covered_paths: Enum.map(covered, &to_string/1),
      uncovered_paths:
        Enum.map(uncovered, fn path ->
          %{
            path: to_string(path),
            reason:
              Map.get(
                @uncovered_reasons,
                path,
                "Not instrumented for per-row posture recording."
              )
          }
        end),
      complete: uncovered == [],
      note:
        "A claim is scoped to the covered paths above. Any path listed as uncovered is " <>
          "outside what this claim proves, whatever else enforces it."
    }
  end

  @doc "The attestation-scope wording, exposed so the MCP tool description cannot drift from it."
  @spec attestation_scope() :: String.t()
  def attestation_scope, do: @attestation_scope

  @doc "The audit-chain action custody posture batches are appended under."
  @spec chain_action() :: String.t()
  def chain_action, do: @chain_action

  defp coverage_source do
    Application.get_env(:loopctl, :custody_coverage_source, Loopctl.Custody.Coverage)
  end
end
