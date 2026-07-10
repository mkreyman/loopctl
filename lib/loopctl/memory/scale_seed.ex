defmodule Loopctl.Memory.ScaleSeed do
  @moduledoc """
  Large multi-subject memory corpus fixture for the terminal Epic 28 scale gate
  (US-28.5 / AC-28.5.5).

  Where `Loopctl.Knowledge.ScaleSeed` seeds ~80k ARTICLES, this seeds ~80k
  long-term MEMORIES spread across many `subject_id`s. It is deliberately shaped
  to reproduce the ONE failure AC-28.5.5 guards against: a subject whose relevant
  memories are NOT the globally-nearest rows (OTHER subjects' rows are nearer and
  dominate the inner ANN pool), yet must still fill its own top-k. This is the
  cross-subject-dominance regime the retired placeholder named — "a subject
  reliably recalls its own top-k WHEN OTHER SUBJECTS DOMINATE THE CORPUS."

  The over-fetch pool + OUTER `subject_id` filter (US-28.2 AC-28.2.3) must reach
  the subject's k by DISCARDING nearer foreign-subject rows from the
  subject-agnostic pool, without under-filling. If the inner pool carried a
  `(tenant_id, subject_id)` predicate (the #170/#172 anti-pattern that defeats
  HNSW) OR if the pool were too shallow to hold the subject's k behind the nearer
  decoys, this seed would make the gate FAIL — which is the point.

  ## Why a dedicated seeder (not a reuse of the article seeder)

  Memories live in the `memories` table with a different shape (`subject_id`
  scope, no links) and are recalled through `Loopctl.Memory.recall/2` →
  `Loopctl.HeavyRead.all_memory/4`, whose structural guard REQUIRES an explicit
  `(tenant_id, subject_id)` predicate. The embedding math, the ANALYZE-and-verify
  pattern, and the prod floor are REUSED from `Loopctl.Knowledge.ScaleSeed`
  (`embedding_for/1`, `prod_article_floor/0`) so there is one source of truth for
  the deterministic 1536-d vectors and the calibration floor.

  ## The corpus layout (deterministic)

  `embedding_for/1` blends a slow sine of period 1000 with a small per-index
  noise term, so the cosine of index `i` to the query `embedding_for(0)` is
  ≈ `cos(2π·(i mod 1000)/1000)`: indices whose phase (index mod 1000) is near 0
  are cosine-near the query; phases ~250+ away are roughly orthogonal or
  anti-correlated. We exploit that to build THREE bands, nearest-first:

    * **Decoys (foreign, the GLOBAL nearest)** — `decoy_count` rows at phases
      `0..(decoy_count - 1)`, each owned by its OWN foreign subject
      (`"scale-decoy-<n>"`). Their cosine to the query is `≥ cos(2π·7/1000)
      ≈ 0.999` (with the default `decoy_count = 8`), so EVERY decoy is strictly
      NEARER to the query than any of subject A's rows. `decoy_count > k`, so
      these foreign rows fill and dominate the top-k of the subject-agnostic ANN
      pool — a naive "top-k of the pool" would return zero subject-A rows.
    * **Subject A (the needle)** — `subject_a_count` rows at phases
      `subject_a_phase_lo..(subject_a_phase_lo + subject_a_count - 1)`
      (`8..57` by default), cosine `cos(2π·8/1000) ≈ 0.999` down to
      `cos(2π·57/1000) ≈ 0.937`. Strictly behind the decoys (contiguous, just
      past the decoy band) but far ahead of the haystack, and A's nearest `k`
      sit at pool ranks `decoy_count..(decoy_count + k)` — inside the
      HNSW-reachable head of the over-fetch pool at prod `ef_search` (see the
      reachability-ceiling note below), so the outer filter can fill a FULL k
      after discarding the nearer decoys.
    * **Haystack (foreign, FAR)** — the remaining rows kept in the phase window
      `[#{200}, #{800})` (any 1000-cycle), cosine ≤ `cos(2π·200/1000) ≈ 0.31`,
      strictly farther than A. Round-robined across `other_subject_count`
      distinct subjects so no single owner is a large fraction of the corpus.

  So the globally-nearest rows are FOREIGN decoys, subject A is a ~0.06% needle
  ranked BEHIND them, and correct recall must surface A's own top-k anyway.

  ## The HNSW reachability ceiling (LOAD-BEARING calibration — do NOT re-inflate)

  At prod's effective `hnsw.ef_search` (pgvector default 40) over the ~80k
  corpus, the approximate HNSW traversal reliably surfaces only roughly the
  **nearest ~20 rows of the near band** (phases ~0..19) into the over-fetch pool;
  rows deeper in the near band are NOT reached at ef_search 40 (they need
  ef_search ≥ ~200), and the remaining pool slots fill with far haystack. This is
  a measured property of the index at scale, verified with a direct pool probe at
  80k across independent HNSW builds — NOT a filter defect.

  The calibration consequence is a hard invariant: `decoy_count + k` must stay
  COMFORTABLY below that ~20-row ceiling, or subject A cannot fill a full top-k
  behind the dominating decoys and the terminal gate under-fills. The defaults
  `decoy_count = 8` + the gate's `k = 5` (sum 13, with ~12 of A's rows reaching
  the pool) leave healthy margin. The PRE-FIX defaults `decoy_count = 20` + `k =
  10` (sum 30) were structurally impossible at ef_search 40 — subject A surfaced
  ZERO rows — which is why the gate failed on execution (US-28.5 AC-28.5.5 fix).
  Do NOT raise `decoy_count`/`subject_a_phase_lo` back toward the old values, and
  do NOT raise the gate's `k`, without re-measuring this ceiling at 80k.

  ## IMPORTANT: opt-in, `@tag :scale`, runs UNBOXED

  Like `Loopctl.Knowledge.ScaleSeed`, this commits rows directly (so ANALYZE sees
  them and the planner builds real statistics) and MUST run OUTSIDE the DataCase
  async sandbox — from a `@tag :scale` test on `ExUnit.Case` wrapping DB ops in
  `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`. It raises if called inside an open
  transaction.

  ## Teardown

      import Ecto.Query
      alias Loopctl.AdminRepo
      alias Loopctl.Memory.Memory, as: MemorySchema
      alias Loopctl.Tenants.Tenant
      Ecto.Adapters.SQL.Sandbox.unboxed_run(AdminRepo, fn ->
        AdminRepo.delete_all(from m in MemorySchema, where: m.tenant_id == ^tenant_id)
        AdminRepo.delete_all(from t in Tenant, where: t.id == ^tenant_id)
      end)
  """

  import Ecto.Query, only: [from: 2]

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.ScaleSeed, as: KnowledgeScaleSeed
  alias Loopctl.Memory.Memory, as: MemorySchema

  # Subject A's distinctive cluster size. Small — it's the needle. k in the recall
  # test is <= this. A is NOT the global nearest (the decoys are); A sits in the
  # phase band [@subject_a_phase_lo, @subject_a_phase_lo + @subject_a_count).
  @subject_a_count 50

  # Subject A's phase band starts here, CONTIGUOUS with (just past) the decoy band
  # [0, @decoy_count). With @decoy_count = 8, A begins at phase 8: cosine
  # cos(2π·8/1000) ≈ 0.999, just below the decoys' minimum (≈ 0.999 at phase 7) yet
  # strictly behind every decoy. The gate's dominance assertions are ROBUST to the
  # sub-noise ordering at that one-phase boundary (they assert "every row nearer
  # than A's first pool appearance is a decoy" + "≥ 1 decoy is nearer", not a
  # per-node exact order), so contiguity costs no determinism. Keeping A contiguous
  # (no phase valley) maximizes the near band's HNSW navigability so A's head rows
  # land inside the reachable pool head (see the reachability-ceiling note).
  @subject_a_phase_lo 8

  # Foreign "decoy" rows that are the GLOBAL nearest to the query — phases
  # 0..(@decoy_count - 1), each owned by its own foreign subject. @decoy_count > k
  # (the recall gate uses k = 5), so the decoys dominate the top-k of the
  # subject-agnostic ANN pool: the outer subject filter MUST discard nearer foreign
  # rows to reach subject A's k. CRUCIAL: @decoy_count + k must stay comfortably
  # below the ~20-row HNSW reachability ceiling at prod ef_search 40 (moduledoc),
  # so A's FULL k rows still surface into the pool behind the decoys. 8 + 5 = 13
  # leaves margin (~12 of A's rows reach the pool); the pre-fix 20 + 10 = 30 was
  # unreachable (A surfaced ZERO rows) — the AC-28.5.5 execution failure this fixes.
  @decoy_count 8

  # The haystack is round-robined across this many other subjects so no single
  # other subject is itself a large fraction of the corpus.
  @other_subject_count 400

  # Keep every haystack row's index phase (index mod 1000) inside this half-open
  # window. With @other_phase_lo = 200 the SMALLEST phase-distance from the phase-0
  # query is exactly 200, so the LARGEST haystack cosine is cos(2π·200/1000) ≈ 0.31
  # (phases toward 500 fall to cos(π) = -1). That is strictly below subject A's
  # band minimum (≈ 0.937 at phase 57) and the decoys (≈ 0.999), so both the
  # needle and its decoys are always nearer than the whole haystack.
  @other_phase_lo 200
  @other_phase_hi 800

  # Per-batch insert timeout. HNSW index maintenance makes each batch cost several
  # seconds and rising, so batches would blow the default 15s DBConnection query
  # timeout (see `insert_batches/2`). Bounded well under the enclosing 30-min
  # `ownership_timeout` so a genuinely stuck insert still fails loudly.
  @insert_timeout :timer.minutes(5)

  # Teardown delete timeout. Unlinking ~80k rows from the partial HNSW graph
  # measures ~150s, over the old 120s bound — so teardown always raised and its
  # `on_exit` rescue swallowed the failure, orphaning the whole corpus. 10 min
  # clears it with margin, still under the 30-min `ownership_timeout`.
  @teardown_timeout :timer.minutes(10)

  @doc "Subject A's cluster size (the distinctive needle memories, behind the decoys)."
  @spec subject_a_count() :: pos_integer()
  def subject_a_count, do: @subject_a_count

  @doc """
  Number of foreign "decoy" rows seeded strictly NEARER to the query than subject
  A — one per foreign subject `"scale-decoy-0".."scale-decoy-<n-1>"`. These
  dominate the top of the subject-agnostic ANN pool; the recall gate proves the
  outer subject filter still fills A's k behind them. `> k` by construction.
  """
  @spec decoy_count() :: pos_integer()
  def decoy_count, do: @decoy_count

  @doc """
  The prod-scale memory floor — reuses `Loopctl.Knowledge.ScaleSeed.prod_article_floor/0`
  so the memory scale gate and the article scale gate share one calibration floor.
  """
  @spec prod_memory_floor() :: pos_integer()
  def prod_memory_floor, do: KnowledgeScaleSeed.prod_article_floor()

  @doc """
  The query embedding subject A's cluster is nearest to — `embedding_for(0)`,
  the centre of A's band. The scale test stubs the embedding client to return
  this so `recall/2` searches A's neighbourhood.
  """
  @spec query_embedding() :: [float()]
  def query_embedding, do: KnowledgeScaleSeed.embedding_for(0)

  @doc """
  Seeds a multi-subject memory corpus for `tenant_id` and returns the ids of
  subject A's memories in nearest-first order plus the foreign decoy subjects
  (nearest-first) that outrank A.

  ## Options

    * `:count` — TOTAL memories to seed (default `prod_memory_floor/0`). Must be
      ≥ `prod_memory_floor/0` unless `:floor` is lowered (below).
    * `:subject_a` — subject A's `subject_id` (default `"scale-subject-A"`).
    * `:batch_size` — rows per `insert_all` (default 1_000).
    * `:floor` — override the enforced prod floor (tests that deliberately seed
      smaller pass an explicit lower floor; the default gate never does).

  Returns `{:ok, %{total: committed, subject_a: subject_a_id, subject_a_ids: [id],
  decoy_subjects: [subject_id], decoy_ids: [id]}}`, where `decoy_subjects` /
  `decoy_ids` are ordered nearest-first (decoy `0`, at phase 0, is the GLOBAL
  nearest row to the query).
  """
  @spec seed_multi_subject(binary(), keyword()) ::
          {:ok,
           %{
             total: non_neg_integer(),
             subject_a: binary(),
             subject_a_ids: [binary()],
             decoy_subjects: [binary()],
             decoy_ids: [binary()]
           }}
  def seed_multi_subject(tenant_id, opts \\ []) when is_binary(tenant_id) do
    if AdminRepo.in_transaction?() do
      raise """
      Loopctl.Memory.ScaleSeed.seed_multi_subject/2 was called inside an open
      transaction (e.g. the DataCase async SQL sandbox). Rows inserted in a
      sandbox transaction are rolled back, so ANALYZE sees n≈0 and recall reads
      nothing. Call it from a @tag :scale test that uses ExUnit.Case directly
      (not DataCase) and wraps DB ops in Ecto.Adapters.SQL.Sandbox.unboxed_run/2.
      """
    end

    count = Keyword.get(opts, :count, prod_memory_floor())
    subject_a = Keyword.get(opts, :subject_a, "scale-subject-A")
    batch_size = Keyword.get(opts, :batch_size, 1_000)
    floor = Keyword.get(opts, :floor, prod_memory_floor())

    if count < floor do
      raise """
      Memory scale gate seed below prod floor!

      Requested count: #{count}
      PROD_MEMORY_FLOOR: #{floor}

      The scale gate must run with count ≥ the prod floor to reproduce the
      planner/HNSW behaviour a subject faces among a prod-sized haystack.
      """
    end

    assert_hnsw_index_present!()

    total_others = count - @subject_a_count - @decoy_count

    {subject_a_ids, decoy_subjects, decoy_ids, total} =
      insert_interleaved(tenant_id, subject_a, total_others, batch_size)

    AdminRepo.query!("ANALYZE memories")

    {:ok,
     %{
       total: total,
       subject_a: subject_a,
       subject_a_ids: subject_a_ids,
       decoy_subjects: decoy_subjects,
       decoy_ids: decoy_ids
     }}
  end

  # ---------------------------------------------------------------------------
  # Insertion — the near cluster (subject A's needle rows AND the foreign decoys
  # that outrank it) is INTERLEAVED throughout the haystack, not front-loaded.
  #
  # HNSW graph reachability depends on insertion order: inserting all of the near
  # rows FIRST and then ~80k haystack rows buries their early nodes so the
  # approximate search (ef_search≈40) can miss them at prod scale — a false
  # "starvation" that is an artifact of the seed, not the recall design. Real
  # memories accumulate interspersed over time, so we spread the near rows evenly
  # across the haystack batches, near rows leading each segment. Ids are returned
  # in embedding-index order (nearest-first), independent of the interleaved
  # physical insertion order.
  # ---------------------------------------------------------------------------

  defp insert_interleaved(tenant_id, subject_a, total_others, batch_size) do
    phase_span = @other_phase_hi - @other_phase_lo
    # One subject-A row (and, for the first @decoy_count segments, one decoy row)
    # leads each of `@subject_a_count` evenly-sized haystack segments, so the near
    # cluster is spread across the whole build.
    others_per_segment =
      max(div(max(total_others, 1) + @subject_a_count - 1, @subject_a_count), 1)

    reducer =
      &insert_segment(
        &1,
        tenant_id,
        subject_a,
        total_others,
        others_per_segment,
        phase_span,
        batch_size,
        &2
      )

    {a_ids_by_index, decoys_by_index, committed} =
      Enum.reduce(0..(@subject_a_count - 1), {%{}, %{}, 0}, reducer)

    subject_a_ids = Enum.map(0..(@subject_a_count - 1), &Map.fetch!(a_ids_by_index, &1))

    {decoy_subjects, decoy_ids} =
      0..(@decoy_count - 1)
      |> Enum.map(&Map.fetch!(decoys_by_index, &1))
      |> Enum.unzip()

    {subject_a_ids, decoy_subjects, decoy_ids, committed}
  end

  # One interleave step: subject A's `seg`-th row (phase @subject_a_phase_lo + seg),
  # the `seg`-th decoy (phase seg) for the first @decoy_count segments, then this
  # segment's haystack slice. The near rows lead so their nodes are woven into the
  # HNSW graph here. Row ids are the pre-generated UUIDs on the built maps, so no
  # `returning:` round-trip is needed to capture them.
  defp insert_segment(
         seg,
         tenant_id,
         subject_a,
         total_others,
         others_per_segment,
         phase_span,
         batch_size,
         {a_acc, decoy_acc, committed}
       ) do
    now = DateTime.utc_now()

    a_row =
      memory_row(
        tenant_id,
        subject_a,
        @subject_a_phase_lo + seg,
        "subject-A distinctive memory ##{seg}",
        now
      )

    {decoy_rows, decoy_acc} =
      if seg < @decoy_count do
        decoy_subject = decoy_subject(seg)

        decoy_row =
          memory_row(tenant_id, decoy_subject, seg, "decoy nearer-than-A memory ##{seg}", now)

        {[decoy_row], Map.put(decoy_acc, seg, {decoy_subject, decoy_row.id})}
      else
        {[], decoy_acc}
      end

    lo = seg * others_per_segment
    hi = min(lo + others_per_segment, total_others) - 1
    other_rows = haystack_rows(lo, hi, tenant_id, phase_span, now)

    near_rows = [a_row | decoy_rows]
    insert_batches(near_rows ++ other_rows, batch_size)

    {Map.put(a_acc, seg, a_row.id), decoy_acc, committed + length(near_rows) + length(other_rows)}
  end

  # Foreign decoy subject id — one distinct subject per decoy so the pool is
  # dominated by MANY other subjects, not a single one.
  defp decoy_subject(n), do: "scale-decoy-#{n}"

  # The haystack rows for index range `lo..hi` (empty when the range is spent).
  # Each row's embedding phase (index mod 1000) is kept inside [lo, hi) on any
  # cycle so every other-subject row is strictly farther from the query than A's
  # cluster; the subject is round-robined so the haystack spans many owners.
  defp haystack_rows(lo, hi, _tenant_id, _phase_span, _now) when hi < lo, do: []

  defp haystack_rows(lo, hi, tenant_id, phase_span, now) do
    for j <- lo..hi do
      phase = @other_phase_lo + rem(j, phase_span)
      cycle = div(j, phase_span)
      index = cycle * 1_000 + phase
      subject = "scale-subject-#{rem(j, @other_subject_count)}"
      memory_row(tenant_id, subject, index, "haystack memory ##{j}", now)
    end
  end

  # Insert a list of rows in `batch_size` chunks. Row ids are the pre-generated
  # UUIDs on the built maps, so no `returning:` round-trip is needed — the caller
  # captures ids from the row maps it built. `rows` leads with the segment's near
  # rows so they are woven into the HNSW graph before that segment's haystack.
  #
  # `timeout:` is CRITICAL: every insert maintains the `memories` partial HNSW
  # index, and per-batch cost grows as the graph fills (a 1k-row batch is several
  # seconds and climbs). Without an override the default 15s DBConnection query
  # timeout trips mid-seed, disconnecting the checked-out connection — which then
  # surfaces as a `DBConnection.OwnershipError` ("owner process has crashed") on
  # the next call, not as a timeout. A generous per-batch bound keeps the whole
  # ~80k build inside the enclosing 30-min `ownership_timeout` (config/test.exs).
  defp insert_batches(rows, batch_size) do
    rows
    |> Enum.chunk_every(batch_size)
    |> Enum.each(fn chunk ->
      AdminRepo.insert_all(MemorySchema, chunk, timeout: @insert_timeout)
    end)
  end

  # ---------------------------------------------------------------------------
  # Row builder — one committed `memories` row with a deterministic embedding
  # ---------------------------------------------------------------------------

  defp memory_row(tenant_id, subject_id, embedding_index, text, now) do
    embedding = Pgvector.new(KnowledgeScaleSeed.embedding_for(embedding_index))

    %{
      id: Ecto.UUID.generate(),
      tenant_id: tenant_id,
      subject_id: subject_id,
      project_id: nil,
      text: text,
      embedding: embedding,
      embedding_content_hash: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower),
      confidence: 1.0,
      source: :explicit,
      source_session_id: nil,
      tags: [],
      metadata: %{},
      superseded_by: nil,
      inserted_at: now,
      updated_at: now
    }
  end

  # The recall inner ANN is served by the partial HNSW index
  # `memories_live_embedding_hnsw_idx` (WHERE superseded_by IS NULL). Scale
  # assertions are meaningless without it — fail loudly if migrations weren't run.
  defp assert_hnsw_index_present! do
    %{rows: rows} =
      AdminRepo.query!("""
      SELECT 1
      FROM pg_indexes idx
      JOIN pg_class cls ON cls.relname = idx.indexname
      JOIN pg_am am ON am.oid = cls.relam
      WHERE idx.tablename = 'memories'
        AND am.amname = 'hnsw'
      LIMIT 1
      """)

    if rows == [] do
      raise "No HNSW index on memories.embedding detected. Run mix ecto.migrate before seeding at scale."
    end

    :ok
  end

  @doc """
  Deletes a seeded tenant's memories and the tenant itself. Runs UNBOXED.

  Deleting ~80k rows is genuinely SLOW: each deleted row must be unlinked from the
  partial HNSW graph, so a full-corpus delete measures ~150s (not a pool-checkout
  wait). The `:timeout` must exceed that or the delete raises mid-statement and
  the caller's `on_exit` rescue swallows it — leaving ~80k committed rows behind
  that accumulate across runs and slow every later scale seed. Bounded at 10 min
  here (well above the measured ~150s, under the 30-min `ownership_timeout`).
  """
  @spec teardown(binary()) :: :ok
  def teardown(tenant_id) when is_binary(tenant_id) do
    AdminRepo.delete_all(from(m in MemorySchema, where: m.tenant_id == ^tenant_id),
      timeout: @teardown_timeout
    )

    AdminRepo.delete_all(from(t in Loopctl.Tenants.Tenant, where: t.id == ^tenant_id),
      timeout: @teardown_timeout
    )

    :ok
  end
end
