defmodule Loopctl.Memory.ScaleSeed do
  @moduledoc """
  Large multi-subject memory corpus fixture for the terminal Epic 28 scale gate
  (US-28.5 / AC-28.5.5).

  Where `Loopctl.Knowledge.ScaleSeed` seeds ~80k ARTICLES, this seeds ~80k
  long-term MEMORIES spread across many `subject_id`s, with ONE distinguished
  subject (subject A) holding a small, distinctive cluster of memories that are
  the genuine nearest neighbours to a known query embedding. The scale test then
  proves subject A reliably recalls its OWN top-k out of the 80k-row haystack —
  i.e. the over-fetch pool + OUTER `subject_id` filter (US-28.2 AC-28.2.3) does
  not starve a subject whose memories are a needle among many other subjects'.

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
  noise term, so two indices whose position mod 1000 are close are cosine-near,
  and indices ~250+ apart (mod 1000) are roughly orthogonal or anti-correlated.
  We exploit that:

    * **Subject A** owns indices `0..(subject_a_count - 1)` (phase `0..49` by
      default) — a tight cluster with cosine ≈ 0.99 to the query
      `embedding_for(0)`.
    * **Every other subject** owns rows whose index is kept in the phase window
      `[#{200}, #{800})` (any 1000-cycle), so its cosine to the query is
      ≤ ~0.31 — strictly farther than ANY of subject A's rows. The haystack is
      round-robined across `other_subject_count` distinct subjects.

  So the globally-nearest rows to the query are exactly subject A's cluster, and
  the recall must surface A's own top-k despite A being ~0.06% of the corpus.

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

  # Subject A's distinctive cluster size (also the count of its distinct indices,
  # phase 0..N-1). Small — it's the needle. k in the recall test is <= this.
  @subject_a_count 50

  # The haystack is round-robined across this many other subjects so no single
  # other subject is itself a large fraction of the corpus.
  @other_subject_count 400

  # Keep every other-subject row's index phase (index mod 1000) inside this
  # half-open window, at least ~150 away from subject A's [0, 50) band on both
  # sides (49→200 and 800→1000). At mod-distance ≥ 150 the cosine to the query is
  # ≤ cos(2π·150/1000) ≈ 0.59 — strictly below A's cluster (≈ 0.99), so A's rows
  # are always the nearest. #{@subject_a_count} < 200 keeps the gap.
  @other_phase_lo 200
  @other_phase_hi 800

  @doc "Subject A's cluster size (the distinctive nearest-neighbour memories)."
  @spec subject_a_count() :: pos_integer()
  def subject_a_count, do: @subject_a_count

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
  subject A's memories in nearest-first order (index `0` first).

  ## Options

    * `:count` — TOTAL memories to seed (default `prod_memory_floor/0`). Must be
      ≥ `prod_memory_floor/0` unless `:floor` is lowered (below).
    * `:subject_a` — subject A's `subject_id` (default `"scale-subject-A"`).
    * `:batch_size` — rows per `insert_all` (default 1_000).
    * `:floor` — override the enforced prod floor (tests that deliberately seed
      smaller pass an explicit lower floor; the default gate never does).

  Returns `{:ok, %{total: committed, subject_a: subject_a_id, subject_a_ids: [id]}}`.
  """
  @spec seed_multi_subject(binary(), keyword()) ::
          {:ok, %{total: non_neg_integer(), subject_a: binary(), subject_a_ids: [binary()]}}
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

    {subject_a_ids, total} =
      insert_interleaved(tenant_id, subject_a, count - @subject_a_count, batch_size)

    AdminRepo.query!("ANALYZE memories")

    {:ok, %{total: total, subject_a: subject_a, subject_a_ids: subject_a_ids}}
  end

  # ---------------------------------------------------------------------------
  # Insertion — subject A's cluster is INTERLEAVED throughout the haystack, not
  # front-loaded.
  #
  # HNSW graph reachability depends on insertion order: inserting all 50 of subject
  # A's needle rows FIRST and then ~80k haystack rows buries A's early nodes so the
  # approximate search (ef_search=40) can miss the whole cluster at prod scale — a
  # false "starvation" that is an artifact of the seed, not the recall design. Real
  # memories accumulate interspersed over time, so we spread subject A's rows evenly
  # across the haystack batches. A's ids are returned in embedding-index order
  # (nearest-first), independent of the interleaved physical insertion order.
  # ---------------------------------------------------------------------------

  defp insert_interleaved(tenant_id, subject_a, total_others, batch_size) do
    phase_span = @other_phase_hi - @other_phase_lo
    # One subject-A row is dropped in front of each of `@subject_a_count` evenly-sized
    # haystack segments, so A's cluster is spread across the whole build.
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

    {a_ids_by_index, committed} = Enum.reduce(0..(@subject_a_count - 1), {%{}, 0}, reducer)

    subject_a_ids = Enum.map(0..(@subject_a_count - 1), &Map.fetch!(a_ids_by_index, &1))
    {subject_a_ids, committed}
  end

  # One interleave step: subject A's `seg`-th row followed by its slice of the
  # haystack, inserted with A first so A's node is woven into the HNSW graph here.
  defp insert_segment(
         seg,
         tenant_id,
         subject_a,
         total_others,
         others_per_segment,
         phase_span,
         batch_size,
         {a_acc, committed}
       ) do
    now = DateTime.utc_now()
    a_row = memory_row(tenant_id, subject_a, seg, "subject-A distinctive memory ##{seg}", now)

    lo = seg * others_per_segment
    hi = min(lo + others_per_segment, total_others) - 1
    other_rows = haystack_rows(lo, hi, tenant_id, phase_span, now)

    {_n, [%{id: a_id}]} = insert_batches([a_row | other_rows], batch_size)
    {Map.put(a_acc, seg, a_id), committed + 1 + length(other_rows)}
  end

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

  # Insert a list of rows in `batch_size` chunks, returning {total, returned_ids}.
  # The FIRST chunk's first row is subject A's (returned first) — insert it in its
  # own leading chunk so its id is unambiguously the head of `returned`.
  defp insert_batches([a_row | others], batch_size) do
    {_n, [%{id: _} = a_returned]} =
      AdminRepo.insert_all(MemorySchema, [a_row], returning: [:id])

    others
    |> Enum.chunk_every(batch_size)
    |> Enum.each(fn chunk -> AdminRepo.insert_all(MemorySchema, chunk) end)

    {1 + length(others), [a_returned]}
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

  Deleting ~80k rows in one statement can outrun the default query timeout, so
  pass a generous `:timeout` (a tenant-scoped delete on the indexed `tenant_id`
  is still fast — the timeout just bounds the pool-checkout wait).
  """
  @spec teardown(binary()) :: :ok
  def teardown(tenant_id) when is_binary(tenant_id) do
    timeout = :timer.seconds(120)

    AdminRepo.delete_all(from(m in MemorySchema, where: m.tenant_id == ^tenant_id),
      timeout: timeout
    )

    AdminRepo.delete_all(from(t in Loopctl.Tenants.Tenant, where: t.id == ^tenant_id),
      timeout: timeout
    )

    :ok
  end
end
