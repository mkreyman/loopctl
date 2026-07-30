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
  appends its own entry recording the posture RESOLVED for THAT operation, and
  only for the endpoints THAT operation actually resolves (see
  `endpoint_kinds/1`). A single write-time snapshot would be falsified the moment
  an async embedding job or an agent-triggered re-embed shipped the body
  somewhere else.

  ## Completeness is PROVEN, never assumed (AC-41.7.2)

  The chain append is asynchronous (see the hot-path budget below), so "the
  entries I can see are all the entries there were" is exactly the assumption an
  ordinary lost Oban job would falsify — silently converting an operation that
  DID egress into a satisfied zero-egress attestation. Instead:

    * every operation allocates its `operation_sequence` from a SEPARATE,
      PERSISTED per-row high-water mark (`custody_row_sequences`) BEFORE anything
      is sent anywhere;
    * `claim/3` requires the surviving entries to form a CONTIGUOUS sequence up
      to that persisted high-water mark — NOT up to the maximum of the rows that
      happen to still exist.

  That distinction is the whole guarantee. Measuring against the surviving rows
  would let TAIL loss (or truncation) restore a satisfied attestation, and a
  `MAX(sequence) + 1` allocator would then hand the erased number out again,
  destroying the evidence. Any gap — a batch job that exhausted retries, a
  deleted row, a node that died between the provider call and the flush, an
  assignment that itself failed — degrades the aggregate to `incomplete`, NEVER
  to no-third-party-egress.

  The sequence is allocated BEFORE the outbound provider call, and the call's
  outcome is patched onto the entry afterwards (`record_outcome/2`). A provider
  call that egressed and then failed therefore still leaves a recorded operation
  naming the endpoint it went to — the case AC-41.7.2 names explicitly ("a node
  that died between the provider call and the append").

  ## Recording may start mid-life — but it NEVER stops mid-life

  A sequence is first assigned only for a scope the tenant has marked
  `local_only`, so a tenant that harvested against vendor endpoints and marked
  `local_only` afterwards has a row whose FIRST recorded operation is not its
  creation. `claim/3` reports that as `partial_history` — never as a complete
  claim about "producing this row" — because operation 0 not being `:create`
  means loopctl has no record of the row's own creation.

  The SYMMETRIC case is the dangerous one and is handled structurally: once a row
  has a persisted sequence, EVERY later content-touching operation on it is
  recorded **whether or not the scope still carries a `local_only` marking**. If
  eligibility were re-evaluated per operation against the live marking, clearing
  `local_only` mid-life would TRUNCATE the sequence — a later re-embed against a
  vendor endpoint would allocate nothing, the surviving all-local prefix would
  stay contiguous up to an unchanged high-water mark, and `claim/3` would keep
  printing `complete` / no-third-party-egress for a row whose body had since
  left. That is reachable by an ordinary settings change, with no attacker.

  So eligibility is `scope is marked local_only` **OR** `this row already has a
  persisted sequence`, and both halves are evaluated INSIDE the single allocating
  statement (`@assign_sql`'s `eligible` CTE) so the check and the allocation
  cannot race. The consequence is honest rather than silent: the later operation
  records the non-local endpoint it actually called, and the aggregate degrades
  to `mixed` / third-party-egress-true.

  ## Three states, not two (AC-41.7.8)

    * `no_claim_recorded` — no sequence was ever assigned (a row written before
      this story, or one in a scope with no `local_only` marking).
    * `claim_pending` — sequence numbers exist but one or more batch appends have
      not flushed; the payload carries the pending count and the batch references.
    * `claim_recorded` — a sequence contiguous up to the persisted high-water
      mark, itself qualified `complete`, `partial_history` or `incomplete`.

  None of these may be read as a positive attestation unless it is
  `claim_recorded` + `complete` + every recorded endpoint network-local.

  ## `tenant_declared` is NOT network-local

  A `tenant_declared` endpoint is a PUBLIC host the tenant merely ATTESTED is its
  own. Counting it as "local" in the aggregate would print "loopctl made no
  third-party call" for content that went to a public address loopctl never
  verified. So the aggregate distinguishes them: `third_party_egress_on_covered_paths`
  is `false` only when every recorded endpoint was `:network_local`, and
  `"tenant_declared_unverified"` when the sequence is all-local but leans on an
  unverified attestation.

  ## Hot-path budget (AC-41.7.7)

  `Loopctl.AuditChain.append/2` runs a `SELECT ... FOR UPDATE`-serialized `Multi`
  on `Loopctl.AdminRepo`, whose pool is **3 connections** (`ADMIN_POOL_SIZE`,
  `config/runtime.exs`) shared with all admin work — saturating it is the
  documented outage mode that forced `HeavyReadRepo` into existence. A harvest
  writes many articles, which is precisely that load profile. So the WRITE PATH IS:

      content transaction: 2 cheap statements (allocate + insert), no chain work
        -> debounced, per-tenant unique Oban job (`audit` queue)
          -> ONE `AuditChain.append/2` per BATCH, capped (see `batch_limit/0`)

  There is NEVER a synchronous per-article chain round-trip, and a batch is
  bounded so one jsonb payload can never grow with a tenant's whole backlog.

  The OUTBOX write is batched too. `record_all/2` — the bulk-embedding path, which
  ships N rows' bodies in one provider array call — resolves the eligibility
  lookup ONCE, the posture ONCE PER DISTINCT OPERATION, and writes ALL N
  allocations and ALL N entries in TWO multi-row statements. So a bulk embed's
  admin cost is CONSTANT in N (plus one debounced `Oban.insert/1`), where the first
  cut spent `3N` serialized admin queries on the same 3-connection pool this budget
  is written against.

  ## Idempotency (AC-41.7.7)

  `(tenant_id, subject_type, subject_id, operation_sequence)` is UNIQUE, so a
  retry cannot duplicate an entry; and `flush_batch/2` looks its chain entry up
  BEFORE claiming any rows, so a replay after "append committed, bookkeeping
  lost" finishes the bookkeeping for the rows THAT LEAF ALREADY CONTAINS and
  never sweeps newly-arrived pending rows into it. Claiming first (as the first
  cut did) would mark rows `recorded` against a chain entry that does not contain
  them — handing the reader an inclusion proof for a leaf missing their
  operations.

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

  # One chain append carries at most this many posture entries. Unbounded, a bulk
  # harvest would put a jsonb payload proportional to the tenant's whole pending
  # backlog into ONE row inside the FOR UPDATE-serialized append on the
  # 3-connection AdminRepo pool — trading the forbidden per-article round-trip for
  # a single row Postgres has to TOAST and every later merkle rebuild pays for.
  # The remainder is re-enqueued.
  @batch_limit 500

  @attestation_scope "This claim attests ONLY to the endpoints loopctl called for the " <>
                       "recorded operations on this row, on the covered egress paths listed " <>
                       "in `coverage`. It makes NO statement about what those endpoints did " <>
                       "with the data afterwards, and none about egress paths not listed as " <>
                       "covered."

  @tenant_declared_caveat "At least one endpoint was classified tenant-declared: a PUBLIC " <>
                            "host the tenant attested is its own. loopctl did not verify that " <>
                            "attestation, so this is NOT the same as network locality and is " <>
                            "deliberately not reported as no-third-party-egress."

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

  @operations [:create, :embed, :reembed, :classify, :merge]

  @doc """
  The operations that append a custody posture entry.

  `:create` is the write/extract, `:embed` the first vectorisation, `:reembed` an
  agent-triggered or model-change re-vectorisation (US-41.1 AC-41.1.10),
  `:classify` and `:merge` the LLM curation passes.

  The vocabulary is ALSO a database CHECK constraint
  (`custody_posture_entries_operation_check`), so an out-of-vocabulary operation
  cannot persist an entry that consumes a sequence number nobody can interpret.
  """
  @spec operations() :: [atom()]
  def operations, do: @operations

  @doc """
  The endpoint kinds an operation actually resolves and calls.

  AC-41.7.3 requires an entry to record "the ACTUAL resolved values used for THAT
  operation". Recording every resolved endpoint on every entry would state a
  falsehood in an immutable, chain-signed row: an `:embed` naming the chat
  endpoint it never called, and `endpoints_involved` listing endpoints for which
  no call was made.

  `:create` resolves NOTHING **by itself** — the content write makes no provider
  call; its entry exists to anchor sequence 0 (so `claim/3` can tell a complete
  history from one that started mid-life) and to record the scope's `local_only`
  marking at creation time.

  A create path that DOES make a provider call must say so. The knowledge-wiki
  novelty gate (`Loopctl.Knowledge.ProposalGate`) embeds the proposal's own title
  and body SYNCHRONOUSLY inside `Knowledge.propose_article/3`, before the article
  row exists — there is no earlier row to hang an entry on, and a gated
  (`:low_novelty`) proposal is created as a DRAFT, which never enqueues an
  embedding worker, so the create entry would otherwise be the row's ONLY entry
  and would vacuously read `all_network_local` for a body that had already been
  POSTed to the resolved embedding host. Callers on such a path pass
  `endpoint_kinds: [:embedding]` to `assign/6`/`assign_in_multi/7`, which records
  the endpoint the gate actually called. The flag is threaded from the assessment
  (`gate_embedded`), never assumed: a proposal that REUSED a caller-supplied
  vector made no call, and recording an endpoint that was not called would be a
  falsehood in the other direction.

  **Scope limit — read this before quoting an egress total.** The ledger is
  PER-ROW: an entry hangs off an article, so a gate verdict that creates NO row
  (`:duplicate`, and `:skipped_low_novelty` under `on_low_novelty: :skip`) records
  nothing, even though the gate embedded that proposal's title and body first. A
  claim over the ledger is therefore "every provider call made ON BEHALF OF THE
  ROWS THAT EXIST", never "every provider call this tenant's content ever caused".
  Row-less gate egress is bounded by the `skipped`/`deduplicated` counters in
  `Loopctl.Knowledge.IngestionWriteStats`; count those alongside if the question
  being asked is about egress volume rather than a row's history.
  """
  @spec endpoint_kinds(atom()) :: [atom()]
  def endpoint_kinds(:create), do: []
  def endpoint_kinds(:embed), do: [:embedding]
  def endpoint_kinds(:reembed), do: [:embedding]
  def endpoint_kinds(:classify), do: [:chat]
  def endpoint_kinds(:merge), do: [:chat]

  # An operation outside the vocabulary records EVERY resolved endpoint — the
  # conservative superset. It is rejected by the database CHECK immediately after,
  # but the posture must never be the thing that narrows a claim by accident.
  def endpoint_kinds(other) when is_atom(other), do: :all

  # ---------------------------------------------------------------------------
  # Recording (hot path)
  # ---------------------------------------------------------------------------

  @doc """
  Allocates the next `operation_sequence` for a row and records the posture
  RESOLVED right now for `operation`.

  Runs on `repo` so a caller inside a content transaction allocates the sequence
  INSIDE that transaction (AC-41.7.2) with no extra pool checkout.

  Call this BEFORE the outbound provider call, then `record_outcome/2` after it:
  a call that egressed and then failed must still leave a recorded operation
  naming the endpoint it went to.

  Options:

    * `:endpoint_kinds` — override the endpoint kinds resolved for this
      operation. Used by a create path that DID make a provider call before the
      row existed (the novelty gate — see `endpoint_kinds/1`).

  Returns `{:ok, %PostureEntry{}}`, `{:ok, :not_applicable}` when the row is not
  eligible for recording (AC-41.7.8(a) — no sequence is ever assigned, which is
  what makes "no claim recorded" legible rather than ambiguous), or
  `{:error, reason}`.
  """
  @spec assign(Ecto.Repo.t(), Scope.t(), String.t(), Ecto.UUID.t(), atom(), keyword()) ::
          {:ok, PostureEntry.t()} | {:ok, :not_applicable} | {:error, term()}
  def assign(repo, %Scope{} = scope, subject_type, subject_id, operation, opts \\ [])
      when is_binary(subject_type) and is_binary(subject_id) do
    case assign_many(repo, scope, [{subject_type, subject_id, operation}], opts) do
      [result] -> result
      [] -> {:ok, :not_applicable}
    end
  end

  @doc """
  `assign/6` for MANY subjects in ONE statement.

  The posture is resolved once per DISTINCT operation (it depends on the scope
  and the operation, never on the subject), and every entry is allocated and
  inserted by a single combined CTE — so the bulk embedding path costs a bounded
  number of `AdminRepo` round-trips instead of `3N` (AC-41.7.7's pool budget).

  Returns one result per input subject, IN ORDER.
  """
  @spec assign_many(Ecto.Repo.t(), Scope.t(), [{String.t(), Ecto.UUID.t(), atom()}], keyword()) ::
          [{:ok, PostureEntry.t()} | {:ok, :not_applicable} | {:error, term()}]
  def assign_many(repo, scope, subjects, opts \\ [])

  def assign_many(_repo, %Scope{}, [], _opts), do: []

  def assign_many(repo, %Scope{} = scope, subjects, opts) when is_list(subjects) do
    indexed = Enum.with_index(subjects)

    # An unreadable entry that still consumes a sequence number is strictly worse
    # than no entry: `claim/3` would reject the subject type while the consumed
    # number silently satisfied contiguity for a subject nobody can read. Refuse
    # before anything is allocated.
    {valid, invalid} =
      Enum.split_with(indexed, fn {{subject_type, _id, _op}, _index} ->
        subject_type in PostureEntry.subject_types()
      end)

    results =
      invalid
      |> Map.new(fn {_subject, index} -> {index, {:error, :invalid_subject_type}} end)
      |> Map.merge(assign_valid(repo, scope, valid, opts))

    Enum.map(0..(length(subjects) - 1)//1, &Map.fetch!(results, &1))
  end

  @doc """
  `assign/6` on `Loopctl.AdminRepo`, then enqueue the debounced batch flush.

  This is the entry point for a worker that is NOT already inside a content
  transaction (an embedding job, a re-embed, a classification pass). It never
  raises and never fails its caller: a posture-recording fault must not fail the
  operation it describes, and the resulting gap is surfaced as `incomplete` by
  `claim/3` rather than passing as a satisfied claim. The fault IS logged — a
  silently discarded `{:error, _}` would make the gap unattributable.
  """
  @spec record(Scope.t(), String.t(), Ecto.UUID.t(), atom()) ::
          {:ok, PostureEntry.t()} | {:ok, :not_applicable} | {:error, term()}
  def record(%Scope{} = scope, subject_type, subject_id, operation) do
    case assign_logged(scope, subject_type, subject_id, operation) do
      {:ok, %PostureEntry{}} = ok ->
        enqueue_flush(scope.tenant_id)
        ok

      other ->
        other
    end
  end

  @doc """
  `record/4` for a whole batch of subjects with ONE flush enqueue.

  The bulk embedding path ships many rows' bodies in a single provider array call,
  so each row needs its own entry — but N `Oban.insert/1` calls for a job that is
  unique per tenant anyway would be N pointless round-trips on the hot path.
  Returns the per-subject results in order, for `record_outcome/2`.
  """
  @spec record_all(Scope.t(), [{String.t(), Ecto.UUID.t(), atom()}]) :: [term()]
  def record_all(%Scope{} = scope, subjects) when is_list(subjects) do
    results = assign_logged(scope, subjects)

    if Enum.any?(results, &match?({:ok, %PostureEntry{}}, &1)) do
      enqueue_flush(scope.tenant_id)
    end

    results
  end

  defp assign_logged(scope, subject_type, subject_id, operation) do
    case assign_logged(scope, [{subject_type, subject_id, operation}]) do
      [result] -> result
      [] -> {:ok, :not_applicable}
    end
  end

  defp assign_logged(scope, subjects) do
    results = assign_many(AdminRepo, scope, subjects)

    Enum.zip(subjects, results)
    |> Enum.each(fn
      {{subject_type, subject_id, operation}, {:error, reason}} ->
        Logger.error(
          "Loopctl.Custody: posture assignment failed for #{subject_type}=#{subject_id} " <>
            "operation=#{operation}: #{inspect(reason)}"
        )

      {_subject, _other} ->
        :ok
    end)

    results
  rescue
    e ->
      Logger.error("Loopctl.Custody: posture recording failed: #{Exception.message(e)}")
      Enum.map(subjects, fn _ -> {:error, :recording_failed} end)
  end

  @doc """
  Patches the OUTCOME of the provider call an entry describes.

  Accepts the return value of `record/4`/`assign/5` directly, so a caller does not
  branch on whether a claim applies. The outcome is bookkeeping — the posture and
  the endpoints stay immutable — and the database enforces that it is MONOTONIC:
  once terminal it can never be rewritten.

  Failure is not exclusion: an operation whose provider call failed AFTER the
  request body left the process still egressed, so the entry remains part of the
  sequence and keeps naming the endpoint it went to.
  """
  @spec record_outcome(term(), :succeeded | :failed) :: :ok
  def record_outcome({:ok, %PostureEntry{} = entry}, outcome), do: record_outcome(entry, outcome)

  def record_outcome(%PostureEntry{} = entry, outcome) when outcome in [:succeeded, :failed] do
    from(e in PostureEntry, where: e.id == ^entry.id and e.outcome == "in_flight")
    |> AdminRepo.update_all(set: [outcome: to_string(outcome), updated_at: DateTime.utc_now()])

    :ok
  rescue
    e ->
      Logger.error("Loopctl.Custody: outcome patch failed: #{Exception.message(e)}")
      :ok
  end

  def record_outcome(_other, _outcome), do: :ok

  @doc """
  Adds the sequence assignment to an existing `Ecto.Multi` so it commits with the
  content write.

  The Multi step never fails the enclosing transaction: an assignment error is
  returned as `{:ok, {:error, reason}}` so the content write still lands. Because
  the sequence number is allocated from a SEPARATE statement that commits with
  the transaction, a failed ENTRY insert leaves the number consumed — so the
  missing entry shows up as a GAP (`incomplete`), never as a satisfied claim.
  """
  @spec assign_in_multi(
          Multi.t(),
          atom(),
          (map() -> Scope.t()),
          String.t(),
          (map() -> Ecto.UUID.t()),
          atom(),
          keyword()
        ) :: Multi.t()
  def assign_in_multi(multi, name, scope_fun, subject_type, subject_id_fun, operation, opts \\ [])
      when is_binary(subject_type) and is_function(scope_fun, 1) and
             is_function(subject_id_fun, 1) do
    Multi.run(multi, name, fn repo, changes ->
      case assign(
             repo,
             scope_fun.(changes),
             subject_type,
             subject_id_fun.(changes),
             operation,
             opts
           ) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          Logger.error(
            "Loopctl.Custody: in-transaction posture assignment failed " <>
              "(#{subject_type}, #{operation}): #{inspect(reason)}"
          )

          {:ok, {:error, reason}}
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

  @doc """
  Seconds after which a `pending` entry still stamped with an unflushed batch id
  is considered STRANDED and re-claimed by the next flush.

  `claim_pending/2` stamps its batch id as its first action, so a flush that dies
  ANYWHERE other than its own final-attempt error branch (an exception inside the
  flush, a node death, a cancelled or pruned job) would otherwise leave those rows
  stamped and pending FOREVER — never re-claimable by another flush, never marked
  failed, and never on the failure surface. AC-41.7.7 requires a failure to record
  to be surfaced; AC-41.7.8 reserves `pending` for a claim genuinely in flight.
  """
  @spec stale_pending_seconds() :: pos_integer()
  def stale_pending_seconds do
    Application.get_env(:loopctl, :custody_stale_pending_seconds, 900)
  end

  @doc "The maximum number of posture entries one chain append carries."
  @spec batch_limit() :: pos_integer()
  def batch_limit, do: @batch_limit

  # A row's FIRST posture entry is only assigned for a scope the tenant has
  # actually marked `local_only`. Recording for every unmarked tenant would bloat
  # the chain with entries nobody asked for, and AC-41.7.8(a) explicitly wants "a
  # scope with no local_only marking" to read as NO CLAIM RECORDED rather than as
  # a claim.
  #
  # This is only HALF the eligibility test — see the `eligible` CTE in
  # `@assign_sql`: a row that ALREADY has a persisted sequence keeps recording
  # even after the marking is cleared, because dropping out mid-life would
  # truncate the sequence and leave the all-local prefix reading `complete`.
  defp claimable_scope?(%Scope{} = scope) do
    Egress.effective_local_only?(scope)
  rescue
    _ -> false
  end

  # TWO batched statements, deliberately not one.
  #
  # `@allocate_sql` decides eligibility and hands out the per-row HIGH-WATER MARK;
  # `@insert_sql` writes the entries. They must stay SEPARATE statements (each under
  # its own savepoint) because a failed ENTRY insert must still leave the number
  # CONSUMED: the missing entry then shows up as a GAP (`incomplete`), never as a
  # satisfied claim. Folding them into one CTE would roll the allocation back with
  # the insert, so an operation that ran and could not be recorded would silently
  # restore a contiguous, complete-looking sequence.
  #
  # Both are MULTI-ROW: a bulk-embedding batch of N subjects costs 2 statements, not
  # 3N (AC-41.7.7's pool budget). Every array parameter is `text[]`/`int[]` and cast
  # in SQL rather than typed at the driver, so no jsonb[]/uuid[] driver encoding is
  # relied on.
  #
  # `eligible` is the OTHER half of the recording gate: a row is recorded when the
  # SCOPE is marked `local_only` ($5) OR the row already has a persisted sequence.
  # The second disjunct is what stops a mid-life `local_only` CLEAR from silently
  # truncating a sequence (see the moduledoc). Evaluating it inside the allocating
  # statement rather than in Elixir also means the check and the allocation cannot
  # race.
  #
  # `allocated` persists the mark INDEPENDENTLY of the entries: `next_sequence - 1`
  # is the highest number ever handed out for the row, which is what AC-41.7.2's
  # contiguity requirement is measured against — it must survive the deletion of
  # every entry it counted, and it must never hand the same number out twice.
  @allocate_sql """
  WITH input AS (
    SELECT * FROM unnest($2::text[], $3::text[]) AS t(subject_id, subject_type)
  ),
  eligible AS (
    SELECT i.*
    FROM input i
    WHERE $5::boolean
       OR EXISTS (
         SELECT 1
         FROM custody_row_sequences s
         WHERE s.tenant_id = $1::uuid
           AND s.subject_type = i.subject_type
           AND s.subject_id = i.subject_id::uuid
       )
  ),
  allocated AS (
    INSERT INTO custody_row_sequences AS s
      (tenant_id, subject_type, subject_id, next_sequence, inserted_at, updated_at)
    SELECT $1::uuid, e.subject_type, e.subject_id::uuid, 1, $4::timestamptz, $4::timestamptz
    FROM eligible e
    ON CONFLICT (tenant_id, subject_type, subject_id)
    DO UPDATE SET next_sequence = s.next_sequence + 1,
                  updated_at = EXCLUDED.updated_at
    RETURNING s.subject_type AS subject_type,
              s.subject_id AS subject_id,
              s.next_sequence - 1 AS operation_sequence
  )
  SELECT subject_type, subject_id::text, operation_sequence FROM allocated
  """

  @insert_sql """
  INSERT INTO custody_posture_entries
    (id, tenant_id, subject_type, subject_id, operation_sequence, operation,
     posture, local_endpoints_only, occurred_at, state, outcome, inserted_at, updated_at)
  SELECT t.entry_id::uuid, $1::uuid, t.subject_type, t.subject_id::uuid, t.operation_sequence,
         t.operation, t.posture::jsonb, t.local_only, $9::timestamptz, 'pending', 'in_flight',
         $9::timestamptz, $9::timestamptz
  FROM unnest($2::text[], $3::text[], $4::int[], $5::text[], $6::text[], $7::boolean[], $8::text[])
       AS t(subject_id, subject_type, operation_sequence, operation, posture, local_only, entry_id)
  RETURNING id
  """

  defp assign_valid(_repo, _scope, [], _opts), do: %{}

  defp assign_valid(repo, scope, valid, opts) do
    case resolve_postures(scope, valid, opts) do
      {:error, reason} ->
        Map.new(valid, fn {_subject, index} -> {index, {:error, reason}} end)

      {:ok, postures} ->
        claimable? = claimable_scope?(scope)
        now = DateTime.utc_now()

        rows =
          Enum.map(valid, fn {{subject_type, subject_id, operation}, index} ->
            %{
              index: index,
              entry_id: Ecto.UUID.generate(),
              subject_type: subject_type,
              subject_id: subject_id,
              operation: operation,
              posture: Map.fetch!(postures, operation)
            }
          end)

        rows
        |> unique_subject_groups()
        |> Enum.map(&assign_group(repo, scope, &1, claimable?, now))
        |> Enum.reduce(%{}, &Map.merge/2)
    end
  end

  # `ON CONFLICT ... DO UPDATE` cannot affect the same row twice in one statement,
  # so a batch that names the same subject more than once is split into successive
  # statements. Distinct subjects (the bulk-embedding case) always yield ONE group.
  defp unique_subject_groups([]), do: []

  defp unique_subject_groups(rows) do
    {group, rest} =
      Enum.reduce(rows, {[], []}, fn row, {group, rest} ->
        seen? =
          Enum.any?(
            group,
            &(&1.subject_type == row.subject_type and &1.subject_id == row.subject_id)
          )

        if seen?, do: {group, [row | rest]}, else: {[row | group], rest}
      end)

    [Enum.reverse(group) | unique_subject_groups(Enum.reverse(rest))]
  end

  defp assign_group(repo, scope, rows, claimable?, now) do
    allocate_params = [
      dump_uuid!(scope.tenant_id),
      Enum.map(rows, & &1.subject_id),
      Enum.map(rows, & &1.subject_type),
      now,
      claimable?
    ]

    case guarded_query(repo, @allocate_sql, allocate_params) do
      {:ok, %{rows: allocated}} ->
        sequences =
          Map.new(allocated, fn [subject_type, subject_id, sequence] ->
            {{subject_type, subject_id}, sequence}
          end)

        {eligible, skipped} =
          Enum.split_with(rows, &Map.has_key?(sequences, {&1.subject_type, &1.subject_id}))

        # Not eligible: the scope carries no `local_only` marking and the row has no
        # sequence yet. No number was consumed — the ABSENCE of a claim.
        skipped_results = Map.new(skipped, &{&1.index, {:ok, :not_applicable}})

        Map.merge(skipped_results, insert_group(repo, scope, eligible, sequences, now))

      {:error, reason} ->
        Map.new(rows, &{&1.index, {:error, reason}})
    end
  end

  defp insert_group(_repo, _scope, [], _sequences, _now), do: %{}

  defp insert_group(repo, scope, rows, sequences, now) do
    params = [
      dump_uuid!(scope.tenant_id),
      Enum.map(rows, & &1.subject_id),
      Enum.map(rows, & &1.subject_type),
      Enum.map(rows, &Map.fetch!(sequences, {&1.subject_type, &1.subject_id})),
      Enum.map(rows, &to_string(&1.operation)),
      Enum.map(rows, &Jason.encode!(&1.posture)),
      Enum.map(rows, & &1.posture.local_endpoints_only),
      Enum.map(rows, & &1.entry_id),
      now
    ]

    case guarded_query(repo, @insert_sql, params) do
      {:ok, _result} ->
        Map.new(rows, fn row ->
          sequence = Map.fetch!(sequences, {row.subject_type, row.subject_id})
          {row.index, {:ok, entry_struct(scope, row, sequence, now)}}
        end)

      {:error, reason} ->
        # The sequence numbers stay CONSUMED. That is the point: the operation
        # happened and could not be recorded, so it must read as a GAP.
        Map.new(rows, &{&1.index, {:error, reason}})
    end
  end

  defp entry_struct(scope, row, sequence, now) do
    %PostureEntry{
      id: row.entry_id,
      tenant_id: scope.tenant_id,
      subject_type: row.subject_type,
      subject_id: row.subject_id,
      operation_sequence: sequence,
      operation: to_string(row.operation),
      posture: row.posture,
      local_endpoints_only: row.posture.local_endpoints_only,
      occurred_at: now,
      state: "pending",
      outcome: "in_flight"
    }
  end

  # Posture resolution reads settings and classifies endpoints; a fault there must
  # become an error tuple, never an exception that aborts the CONTENT transaction
  # this may be running inside.
  #
  # Resolved ONCE per DISTINCT operation: the posture depends on the scope and the
  # operation's endpoint kinds, never on the subject, so a 100-row embedding batch
  # resolves it once rather than 100 times.
  defp resolve_postures(scope, valid, opts) do
    override = Keyword.get(opts, :endpoint_kinds)

    postures =
      valid
      |> Enum.map(fn {{_subject_type, _subject_id, operation}, _index} -> operation end)
      |> Enum.uniq()
      |> Map.new(fn operation ->
        {operation, Egress.operation_posture(scope, override || endpoint_kinds(operation))}
      end)

    {:ok, postures}
  rescue
    e -> {:error, {:posture_resolution_failed, Exception.message(e)}}
  end

  # Runs the statement behind a SAVEPOINT when the caller is already inside a
  # transaction, so a failed statement rolls back only ITSELF. Without this, any
  # error here would abort the enclosing CONTENT transaction — i.e. a
  # posture-recording fault would destroy the article write it merely describes,
  # exactly inverting the priority.
  #
  # `mode: :savepoint` is Ecto's supported form, so DBConnection's own transaction
  # status tracking stays in sync. The first cut issued raw `SAVEPOINT` /
  # `ROLLBACK TO SAVEPOINT` statements, which depends on Postgrex recovering the
  # aborted transaction from the ReadyForQuery status behind DBConnection's back.
  defp guarded_query(repo, sql, params) do
    opts = if repo.in_transaction?(), do: [mode: :savepoint], else: []
    SQL.query(repo, sql, params, opts)
  rescue
    e -> {:error, e}
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

  Deterministic so a retry of the same job looks up the SAME chain entry — which
  is what makes the replay a no-op instead of a second append into an append-only,
  later-signed structure.
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

  ## Ordering is load-bearing

  The chain-entry lookup happens FIRST. If a leaf for this batch already exists,
  the ONLY thing left to do is finish the bookkeeping for the rows that leaf
  already contains — claiming first (as the first cut did) would sweep every
  posture entry inserted since the previous attempt into the batch and mark them
  `recorded` against a leaf that does not contain them, handing the reader a
  `chain_position` whose inclusion proof proves nothing about their operations.
  """
  @spec flush_batch(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def flush_batch(tenant_id, batch_id) do
    case existing_batch_entry(tenant_id, batch_id) do
      nil -> flush_new_batch(tenant_id, batch_id)
      chain_entry -> finish_appended_batch(tenant_id, batch_id, chain_entry)
    end
  end

  defp flush_new_batch(tenant_id, batch_id) do
    claim_pending(tenant_id, batch_id)

    case batch_entries(tenant_id, batch_id) do
      [] -> {:ok, 0}
      entries -> append_batch(tenant_id, batch_id, entries)
    end
  end

  # The append already committed on a previous attempt; only the bookkeeping
  # update was lost. Finish it for THIS BATCH'S rows only — do NOT append a second
  # entry, and do NOT claim anything new.
  defp finish_appended_batch(tenant_id, batch_id, chain_entry) do
    {count, _} = mark_recorded(tenant_id, batch_id, chain_entry)
    maybe_reenqueue(tenant_id)
    {:ok, count}
  end

  # Claims at most `@batch_limit` rows: the tenant's UNCLAIMED pending entries
  # first, then any STRANDED ones (stamped with a batch that never produced a
  # chain entry and has since gone stale).
  defp claim_pending(tenant_id, batch_id) do
    fresh = unclaimed_pending_ids(tenant_id, batch_id, @batch_limit)
    remaining = @batch_limit - length(fresh)
    stranded = if remaining > 0, do: stranded_pending_ids(tenant_id, remaining), else: []
    ids = fresh ++ stranded

    if ids == [] do
      {0, nil}
    else
      from(e in PostureEntry, where: e.id in ^ids)
      |> AdminRepo.update_all(set: [batch_id: batch_id, updated_at: DateTime.utc_now()])
    end
  end

  defp unclaimed_pending_ids(tenant_id, batch_id, limit) do
    from(e in PostureEntry,
      where:
        e.tenant_id == ^tenant_id and e.state == "pending" and
          (is_nil(e.batch_id) or e.batch_id == ^batch_id),
      order_by: [asc: e.inserted_at, asc: e.id],
      limit: ^limit,
      select: e.id
    )
    |> AdminRepo.all()
  end

  # Rows stamped by a flush that died outside its own final-attempt error branch.
  # A stranded row is only re-claimable once its batch is BOTH stale and provably
  # unappended — re-claiming a row whose leaf already exists would put it in two
  # leaves.
  defp stranded_pending_ids(tenant_id, limit) do
    cutoff = DateTime.add(DateTime.utc_now(), -stale_pending_seconds(), :second)

    rows =
      from(e in PostureEntry,
        where:
          e.tenant_id == ^tenant_id and e.state == "pending" and not is_nil(e.batch_id) and
            e.updated_at < ^cutoff,
        order_by: [asc: e.inserted_at, asc: e.id],
        limit: ^limit,
        select: {e.id, e.batch_id}
      )
      |> AdminRepo.all()

    appended = appended_batch_ids(tenant_id, rows |> Enum.map(&elem(&1, 1)) |> Enum.uniq())

    rows
    |> Enum.reject(fn {_id, batch} -> batch in appended end)
    |> Enum.map(&elem(&1, 0))
  end

  defp appended_batch_ids(_tenant_id, []), do: []

  defp appended_batch_ids(tenant_id, batch_ids) do
    from(e in AuditChain.Entry,
      where:
        e.tenant_id == ^tenant_id and e.entity_type == ^@chain_entity_type and
          e.entity_id in ^batch_ids,
      select: e.entity_id
    )
    |> AdminRepo.all()
  end

  defp batch_entries(tenant_id, batch_id) do
    from(e in PostureEntry,
      where: e.tenant_id == ^tenant_id and e.batch_id == ^batch_id and e.state == "pending",
      order_by: [asc: e.subject_id, asc: e.operation_sequence]
    )
    |> AdminRepo.all()
  end

  defp append_batch(tenant_id, batch_id, entries) do
    payload = %{
      "batch_id" => batch_id,
      "entry_count" => length(entries),
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
        maybe_reenqueue(tenant_id)
        {:ok, length(entries)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A capped batch may leave a remainder. The flush job is unique across the
  # SCHEDULABLE states only (not `:executing`), so this insert always lands.
  defp maybe_reenqueue(tenant_id) do
    pending? =
      from(e in PostureEntry, where: e.tenant_id == ^tenant_id and e.state == "pending")
      |> AdminRepo.exists?()

    if pending?, do: enqueue_flush(tenant_id), else: :ok
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

  # A DIGEST of the posture rather than the whole map: the chain payload must not
  # grow with the size of each recorded posture, and the digest binds just as
  # tightly — the claim returns both the posture and this digest, so a verifier
  # recomputes it, finds it in the leaf's payload, recomputes the leaf hash, and
  # matches it against the inclusion proof's `leaf_hash`.
  defp chain_payload_entry(%PostureEntry{} = entry) do
    %{
      "subject_type" => entry.subject_type,
      "subject_id" => entry.subject_id,
      "operation_sequence" => entry.operation_sequence,
      "operation" => entry.operation,
      "local_endpoints_only" => entry.local_endpoints_only,
      "network_local_endpoints_only" => network_local_only?(entry),
      "occurred_at" => DateTime.to_iso8601(entry.occurred_at),
      "posture_digest" => posture_digest(entry.posture)
    }
  end

  @doc """
  The canonical digest of a recorded posture, as embedded in the audit-chain
  payload.

  Canonical means: every map is rendered as a key-SORTED JSON array of
  `[key, value]` pairs, so the digest does not depend on map iteration order.
  Published as a public function because an external verifier has to be able to
  recompute it from the posture the claim returns.
  """
  @spec posture_digest(map()) :: String.t()
  def posture_digest(posture) do
    :sha256
    |> :crypto.hash(Jason.encode!(canonical(posture)))
    |> Base.url_encode64(padding: false)
  end

  defp canonical(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp canonical(term) when is_map(term) do
    term
    |> Enum.map(fn {k, v} -> [to_string(k), canonical(v)] end)
    |> Enum.sort_by(&hd/1)
  end

  defp canonical(term) when is_list(term), do: Enum.map(term, &canonical/1)

  defp canonical(term) when is_atom(term) and not is_boolean(term) and not is_nil(term),
    do: to_string(term)

  defp canonical(term), do: term

  defp mark_recorded(tenant_id, batch_id, chain_entry) do
    now = DateTime.utc_now()

    from(e in PostureEntry,
      where: e.tenant_id == ^tenant_id and e.batch_id == ^batch_id and e.state == "pending"
    )
    |> AdminRepo.update_all(
      set: [
        state: "recorded",
        chain_entry_id: chain_entry.id,
        chain_position: chain_entry.chain_position,
        chain_entry_hash: chain_entry.entry_hash,
        recorded_at: now,
        updated_at: now
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

  @doc """
  Entries that have been `pending` longer than `stale_pending_seconds/0`.

  The second half of the failure surface. A flush that dies outside its own
  final-attempt error branch never marks anything `failed`, so without this a
  stranded row would read as an in-flight claim indefinitely and never appear
  anywhere an operator looks.
  """
  @spec list_stale_pending(Ecto.UUID.t(), keyword()) :: [PostureEntry.t()]
  def list_stale_pending(tenant_id, opts \\ []) do
    cutoff = DateTime.add(DateTime.utc_now(), -stale_pending_seconds(), :second)

    from(e in PostureEntry,
      where: e.tenant_id == ^tenant_id and e.state == "pending" and e.updated_at < ^cutoff,
      order_by: [asc: e.occurred_at],
      limit: ^Keyword.get(opts, :limit, 100)
    )
    |> AdminRepo.all()
  end

  @doc """
  Enqueues a flush for every tenant carrying `pending` entries older than
  `stale_pending_seconds/0`. The periodic backstop behind
  `Loopctl.Workers.CustodyPostureSweepWorker`.

  `enqueue_flush/1` runs AFTER the content transaction commits and deliberately
  never fails its caller, so a process that dies in that window leaves a committed
  `pending` outbox row with `batch_id` NULL and NOTHING scheduled to flush it.
  `stranded_pending_ids/2` only runs inside a flush that some OTHER write for the
  same tenant happens to enqueue — for a quiet tenant, that never comes. The row
  is correctly non-positive (`claim_pending`, never an attestation), but it stays
  that way forever. This closes it with machinery that already exists.

  Returns the number of tenants swept.
  """
  @spec enqueue_stale_flushes(keyword()) :: non_neg_integer()
  def enqueue_stale_flushes(opts \\ []) do
    cutoff = DateTime.add(DateTime.utc_now(), -stale_pending_seconds(), :second)

    tenant_ids =
      from(e in PostureEntry,
        where: e.state == "pending" and e.updated_at < ^cutoff,
        distinct: true,
        select: e.tenant_id,
        limit: ^Keyword.get(opts, :limit, 200)
      )
      |> AdminRepo.all()

    Enum.each(tenant_ids, &enqueue_flush/1)
    length(tenant_ids)
  end

  @doc """
  A STABLE, non-leaking failure code for a chain-append failure, plus a
  correlation id an operator can grep the logs for.

  The raw term is a `%Postgrex.Error{}` (whose `inspect/1` renders the postgres
  message, detail, hint, constraint — and for some classes the offending
  statement) or an `%Ecto.Changeset{}` carrying rejected values. That is served
  verbatim to `:agent`-role callers through `GET /custody/failures` and through an
  incomplete claim's `failure_reason`. An agent needs to know THAT recording
  failed and how to correlate it; internal schema and statement fragments are not
  part of that. The raw term stays in the worker's `Logger.error`.
  """
  @spec failure_reason(term(), term()) :: String.t()
  def failure_reason(reason, correlation) do
    "#{failure_code(reason)} (correlation=#{correlation})"
  end

  defp failure_code(%Postgrex.Error{}), do: "chain_append_database_error"
  defp failure_code(%Ecto.Changeset{}), do: "chain_append_invalid"
  defp failure_code({:error, inner}), do: failure_code(inner)
  defp failure_code(reason) when is_atom(reason), do: "chain_append_#{reason}"
  defp failure_code(_reason), do: "chain_append_failed"

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

  @doc """
  The HIGHEST `operation_sequence` ever assigned for a row, or `nil` if none was.

  Persisted independently of the entries, so it survives their loss — which is
  what makes tail truncation legible as a gap instead of restoring a satisfied
  attestation.
  """
  @spec highest_assigned_sequence(Ecto.UUID.t(), String.t(), Ecto.UUID.t()) ::
          non_neg_integer() | nil
  def highest_assigned_sequence(tenant_id, subject_type, subject_id) do
    from(s in "custody_row_sequences",
      where:
        s.tenant_id == type(^tenant_id, :binary_id) and s.subject_type == ^subject_type and
          s.subject_id == type(^subject_id, :binary_id),
      select: s.next_sequence
    )
    |> AdminRepo.one()
    |> case do
      nil -> nil
      0 -> nil
      next -> next - 1
    end
  end

  # ---------------------------------------------------------------------------
  # Read surface (AC-41.7.5)
  # ---------------------------------------------------------------------------

  @doc """
  The custody claim for one article or memory row.

  Returns one of the three AC-41.7.8 states. `third_party_egress_on_covered_paths`
  is reported `false` ONLY for a `claim_recorded` + `complete` sequence that
  starts at the row's creation and in which every recorded endpoint was
  NETWORK-local; it is always qualified by `coverage`, and by `attestation_scope`,
  which states exactly what the claim does and does not say.
  """
  @spec claim(Ecto.UUID.t(), String.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def claim(tenant_id, subject_type, subject_id) do
    cond do
      subject_type not in PostureEntry.subject_types() ->
        {:error, :invalid_subject_type}

      # `subject_id` is a raw path segment. Both `list_entries/3` and
      # `highest_assigned_sequence/3` compare it against a `:binary_id` column, so
      # a non-UUID would raise `Ecto.Query.CastError` — a 500 on a trivially
      # reachable request. Validate here as well as at the controller so no future
      # caller reintroduces it.
      match?(:error, Ecto.UUID.cast(subject_id)) ->
        {:error, :invalid_subject_id}

      true ->
        {:ok, build_claim(tenant_id, subject_type, subject_id)}
    end
  end

  @doc """
  The `no_claim_recorded` payload for a subject, built WITHOUT reading its entries.

  Returned for a subject the caller may not see, so an invisible row is
  byte-identical to a row that simply has no claim. A DISTINCT response (a 404, or
  a differently-worded summary) would be an existence oracle for another agent's
  private memory — which is most of what the visibility gate exists to withhold.
  """
  @spec absent_claim(Ecto.UUID.t(), String.t(), Ecto.UUID.t()) :: map()
  def absent_claim(tenant_id, subject_type, subject_id) do
    Map.merge(
      claim_base(tenant_id, subject_type, subject_id),
      claim_state(tenant_id, subject_type, subject_id, [], nil)
    )
  end

  defp build_claim(tenant_id, subject_type, subject_id) do
    entries = list_entries(tenant_id, subject_type, subject_id)
    assigned = highest_assigned_sequence(tenant_id, subject_type, subject_id)

    Map.merge(
      claim_base(tenant_id, subject_type, subject_id),
      claim_state(tenant_id, subject_type, subject_id, entries, assigned)
    )
  end

  defp claim_base(tenant_id, subject_type, subject_id) do
    %{
      tenant_id: tenant_id,
      subject_type: subject_type,
      subject_id: subject_id,
      coverage: coverage(),
      attestation_scope: @attestation_scope,
      tenant_declared_label: Egress.tenant_declared_label()
    }
  end

  defp claim_state(_tenant_id, _subject_type, _subject_id, [], nil) do
    %{
      claim_state: "no_claim_recorded",
      entries: [],
      summary:
        "No custody claim is available for this row: no operation sequence was ever " <>
          "assigned for it (the row predates custody recording, or its scope carries no " <>
          "local_only marking), or it is not one this caller may see. This is the ABSENCE " <>
          "of a claim: it asserts nothing about egress in either direction and must not be " <>
          "read as one."
    }
  end

  defp claim_state(tenant_id, subject_type, subject_id, entries, assigned) do
    # Contiguity is measured against the PERSISTED high-water mark, never against
    # the maximum of the surviving rows — otherwise losing the tail of a sequence
    # would silently restore a satisfied attestation.
    recorded_max =
      case entries do
        [] -> -1
        _ -> entries |> Enum.map(& &1.operation_sequence) |> Enum.max()
      end

    max_sequence = max(assigned || -1, recorded_max)
    sequences = MapSet.new(entries, & &1.operation_sequence)
    contiguous? = max_sequence >= 0 and Enum.all?(0..max_sequence, &MapSet.member?(sequences, &1))

    pending = Enum.filter(entries, &(&1.state == "pending"))
    failed = Enum.filter(entries, &(&1.state == "failed"))

    rendered = Enum.map(entries, &render_entry/1)
    endpoints = involved_endpoints(entries)
    chain_entries = chain_entries(tenant_id, subject_type, subject_id, entries)

    cond do
      not contiguous? or failed != [] ->
        incomplete_claim(rendered, endpoints, max_sequence, contiguous?, failed, chain_entries)

      pending != [] ->
        pending_claim(tenant_id, rendered, pending, endpoints, max_sequence)

      true ->
        complete_claim(entries, rendered, endpoints, max_sequence, chain_entries)
    end
  end

  defp incomplete_claim(rendered, endpoints, max_sequence, contiguous?, failed, chain_entries) do
    %{
      claim_state: "claim_recorded",
      completeness: "incomplete",
      third_party_egress_on_covered_paths: "unknown",
      highest_assigned_sequence: max_sequence,
      contiguous: contiguous?,
      failed_entries: Enum.map(failed, &render_entry/1),
      entries: rendered,
      endpoints_involved: endpoints,
      chain_entries: chain_entries,
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

  # A contiguous, fully-flushed sequence. Two further questions decide what may be
  # said about it: does it cover the row's own creation, and were the endpoints
  # network-local or merely tenant-DECLARED?
  defp complete_claim(entries, rendered, endpoints, max_sequence, chain_entries) do
    if covers_row_creation?(entries) do
      full_claim(entries, rendered, endpoints, max_sequence, chain_entries)
    else
      partial_history_claim(rendered, endpoints, max_sequence, chain_entries)
    end
  end

  # Sequence 0 must be the row's own `:create`. When it is not, recording started
  # MID-LIFE — the tenant marked `local_only` after the row already existed — and
  # loopctl has no record of how the row was produced. Reporting that as a
  # complete claim about "producing this row" would be a false statement about its
  # creation and its first embedding.
  defp covers_row_creation?(entries) do
    case entries do
      [%PostureEntry{operation_sequence: 0, operation: "create"} | _] -> true
      _ -> false
    end
  end

  defp partial_history_claim(rendered, endpoints, max_sequence, chain_entries) do
    %{
      claim_state: "claim_recorded",
      completeness: "partial_history",
      third_party_egress_on_covered_paths: "unknown",
      posture: "recording_started_mid_life",
      highest_assigned_sequence: max_sequence,
      contiguous: true,
      entries: rendered,
      endpoints_involved: endpoints,
      chain_entries: chain_entries,
      summary:
        "PARTIAL HISTORY. Every recorded operation is accounted for, but operation 0 is " <>
          "not this row's creation — custody recording began after the row already " <>
          "existed (typically because the scope was marked local_only later). loopctl " <>
          "therefore has NO record of how this row was produced, and this is not reported " <>
          "as no-third-party-egress. The recorded window is in `entries`."
    }
  end

  defp full_claim(entries, rendered, endpoints, max_sequence, chain_entries) do
    all_local? = Enum.all?(entries, & &1.local_endpoints_only)
    all_network_local? = Enum.all?(entries, &network_local_only?/1)

    {posture, egress, summary} =
      cond do
        all_network_local? ->
          {"all_network_local", false,
           "COMPLETE. Over a contiguous sequence of #{max_sequence + 1} recorded operations " <>
             "starting at this row's creation, every endpoint loopctl called on the covered " <>
             "egress paths was classified NETWORK-LOCAL for this scope, so loopctl made no " <>
             "third-party call on those paths while producing this row. See `coverage` for " <>
             "which paths that is and `attestation_scope` for what this does not say."}

        all_local? ->
          {"all_local_including_tenant_declared", "tenant_declared_unverified",
           "COMPLETE, TENANT-DECLARED. Over a contiguous sequence of #{max_sequence + 1} " <>
             "recorded operations starting at this row's creation, every endpoint loopctl " <>
             "called was classified local for this scope — but not all of them were " <>
             "network-local. " <> @tenant_declared_caveat}

        true ->
          {"mixed", true,
           "COMPLETE, MIXED. Over a contiguous sequence of #{max_sequence + 1} recorded " <>
             "operations, at least one endpoint loopctl called was NOT classified local for " <>
             "this scope. See `endpoints_involved` for the endpoints and their " <>
             "classifications."}
      end

    %{
      claim_state: "claim_recorded",
      completeness: "complete",
      third_party_egress_on_covered_paths: egress,
      posture: posture,
      highest_assigned_sequence: max_sequence,
      contiguous: true,
      entries: rendered,
      endpoints_involved: endpoints,
      chain_entries: chain_entries,
      summary: summary
    }
  end

  # An operation that resolved NO endpoint (a `:create`, which makes no provider
  # call) is vacuously network-local: no endpoint was called, so no non-local
  # endpoint was called. An operation that SHOULD have resolved endpoints but
  # recorded none is not — `Egress.operation_posture/2` already reports both
  # aggregates false in that case.
  defp network_local_only?(%PostureEntry{posture: posture}) do
    case fetch_any(posture, :network_local_endpoints_only) do
      nil -> false
      value -> value
    end
  end

  defp render_entry(%PostureEntry{} = entry) do
    %{
      operation_sequence: entry.operation_sequence,
      operation: entry.operation,
      state: entry.state,
      outcome: entry.outcome,
      local_endpoints_only: entry.local_endpoints_only,
      network_local_endpoints_only: network_local_only?(entry),
      occurred_at: entry.occurred_at,
      posture: entry.posture,
      posture_digest: posture_digest(entry.posture),
      chain_position: entry.chain_position,
      chain_entry_id: entry.chain_entry_id,
      chain_entry_hash: encode_hash(entry.chain_entry_hash),
      failure_reason: entry.failure_reason
    }
  end

  defp encode_hash(nil), do: nil
  defp encode_hash(binary), do: Base.url_encode64(binary, padding: false)

  # The audit-chain LEAVES carrying this row's postures, with the hashes that let a
  # reader tie the claim to `GET /audit/sth/:tenant_id/inclusion/:position`.
  # Without this, a reader could prove only that SOME leaf sits at position N —
  # not that that leaf is the batch containing this row.
  #
  # THE PAYLOAD IS REDACTED TO THE REQUESTED SUBJECT. A batch carries up to
  # `batch_limit/0` entries spanning EVERY subject the tenant flushed in that
  # window, and each carries `subject_type`, `subject_id`, `operation`,
  # `occurred_at` and both locality flags. Returning it verbatim turned one
  # authorised read of ONE row into an inventory of up to 499 unrelated rows —
  # including other agents' memory ids, which are never even named in the request.
  # The verification use case does not need it: `posture_digest/1` is public, so a
  # verifier recomputes its OWN entry's digest from the `entries` this claim
  # already returns and finds it inside the leaf. Recomputing the WHOLE leaf hash
  # requires the unredacted payload, which is what the audit-chain entry surface is
  # for; `redacted_entry_count` states plainly how much was withheld rather than
  # letting the reader mistake a filtered payload for a complete one.
  defp chain_entries(tenant_id, subject_type, subject_id, entries) do
    ids = entries |> Enum.map(& &1.chain_entry_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] do
      []
    else
      from(e in AuditChain.Entry,
        where: e.tenant_id == ^tenant_id and e.id in ^ids,
        order_by: [asc: e.chain_position]
      )
      |> AdminRepo.all()
      |> Enum.map(fn entry ->
        {payload, redacted} = redact_payload(entry.payload, subject_type, subject_id)

        %{
          chain_entry_id: entry.id,
          chain_position: entry.chain_position,
          entry_hash: encode_hash(entry.entry_hash),
          prev_entry_hash: encode_hash(entry.prev_entry_hash),
          # LCP-1 §8.4: the leaf-hash version identifying which construction wrote
          # this entry (v1 and v2 differ). NOTE: this surface is NOT a full §8.5
          # recompute surface — `payload` below is REDACTED to the requesting
          # subject (see payload_note), so the leaf hash cannot be reproduced from
          # it. hash_version is exposed for version-awareness/completeness; full
          # recompute uses the unredacted entry via `AuditChain.recompute_entry_hash/1`.
          hash_version: entry.hash_version,
          action: entry.action,
          actor_lineage: entry.actor_lineage,
          entity_type: entry.entity_type,
          entity_id: entry.entity_id,
          inserted_at: entry.inserted_at,
          payload: payload,
          redacted_entry_count: redacted,
          payload_note:
            "Only this row's own posture entries are shown. The leaf also carries the " <>
              "other subjects flushed in the same batch; they are withheld because a " <>
              "claim about one row must not enumerate unrelated rows."
        }
      end)
    end
  end

  defp redact_payload(payload, subject_type, subject_id) when is_map(payload) do
    all = payload |> Map.get("entries", []) |> List.wrap()

    mine =
      Enum.filter(all, fn entry ->
        is_map(entry) and fetch_any(entry, :subject_type) == subject_type and
          fetch_any(entry, :subject_id) == subject_id
      end)

    {Map.put(payload, "entries", mine), length(all) - length(mine)}
  end

  defp redact_payload(payload, _subject_type, _subject_id), do: {payload, 0}

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
      verdict_code: fetch_any(endpoint, :verdict_code),
      local: fetch_any(endpoint, :local),
      network_local: fetch_any(endpoint, :network_local)
    }
  end

  defp fetch_any(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  # Oban job ids of the flush batches currently scheduled for this tenant. The
  # pending payload names them so a reader between the content write and the flush
  # can point at the work it is waiting on (AC-41.7.8(b)).
  #
  # The `args->>'tenant_id'` predicate is supported by a PARTIAL expression index
  # scoped to this worker (`oban_jobs_custody_flush_tenant_idx`,
  # `20260721040000_custody_review_hardening`). Oban's stock indexes are on
  # (state, queue, priority, scheduled_at, id), so without it this was a sequential
  # scan with a per-row jsonb extraction on EVERY pending-state claim read —
  # exactly what an agent polling after a harvest hits repeatedly.
  #
  # A failure returns `:unavailable`, NEVER `[]`. An empty list is a positive
  # statement ("nothing is scheduled"), and emitting it for a row that demonstrably
  # HAS pending entries reintroduces precisely the ambiguity AC-41.7.8(b) exists to
  # remove.
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
    e ->
      Logger.warning("Loopctl.Custody: enqueued batch lookup failed: #{Exception.message(e)}")
      :unavailable
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
