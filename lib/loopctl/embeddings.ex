defmodule Loopctl.Embeddings do
  @moduledoc """
  US-41.1 — the per-tenant embedding DIMENSION context.

  Owns four things that used to be implicit in a `vector(1536)` column type:

    1. **The supported set** (`supported_dimensions/0`) — the FIXED set of
       dimensions this instance has pre-created ANN indexes for. Published on
       `.well-known/loopctl` as `supported_embedding_dimensions` and used by the
       index migration, so the published set and the migrated indexes cannot
       drift (AC-41.1.3).
    2. **The tenant's ACTIVE dimension** (`active_dimension/1`) — resolved ONCE
       per operation or batch and threaded into the changesets, never read from
       inside a validator (AC-41.1.11).
    3. **The write path** (`upsert_article_embedding/4`, `upsert_memory_embedding/5`)
       — dual-writing the legacy column and the side table in ONE transaction
       while `dim == 1536` (AC-41.1.8).
    4. **The cutover levers** (`side_table_reads_enabled?/0`, `backfill_articles/2`,
       `reconcile_articles/1`) — an explicit, reversible flag plus a resumable
       batched backfill and a reconciliation pass (AC-41.1.8/.9).

  ## Cutover, in order (AC-41.1.8)

      1. deploy this code           -> every node dual-writes dim 1536
      2. run the backfill           -> `backfill_articles/2` / `backfill_memories/2`
      3. run the reconciliation     -> `reconcile_articles/1` / `reconcile_memories/1`
      4. flip the read flag         -> SystemConfig "embedding_side_table_reads" = 1

  Step 4 may only happen after step 1 has reached EVERY node: during a Fly rolling
  deploy an old node writes the legacy column only, so a node reading the side
  table would miss its writes. The flag is a `SystemConfig` integer precisely so
  reverting it is a single `UPDATE system_configs` with no redeploy — reverting is
  a SUPPORTED operation for the whole dual-write window (AC-41.1.8(iii)).

  ## Dual-write is dim-1536-ONLY, and why

  The legacy columns are `vector(1536)`. pgvector HARD-ERRORS on storing a
  768/1024/3072-length value in them, so a dual-write mandate for non-default
  dimensions is physically unexecutable. Non-default dimensions are therefore
  side-table-ONLY and are not recallable until the read flag flips;
  `recall_availability/1` is the tenant-facing surface that SAYS so rather than
  failing opaquely.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings.Dimensions
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleEmbedding
  alias Loopctl.Knowledge.VectorSearch
  alias Loopctl.Llm
  alias Loopctl.Memory.Memory
  alias Loopctl.Memory.MemoryEmbedding
  alias Loopctl.SystemConfig
  alias Loopctl.Tenants.Tenant
  alias Loopctl.Workers.ReembedWorker
  alias Loopctl.Workers.SystemCorpusEmbeddingWorker

  @read_flag_key "embedding_side_table_reads"
  @default_batch_size 500

  # ---------------------------------------------------------------------------
  # The supported set (AC-41.1.3)
  # ---------------------------------------------------------------------------

  @doc """
  The dimensions this instance supports, ascending and deduplicated.

  Every value here has a pre-created per-dimension HNSW index on BOTH side tables
  (migration `CreatePerDimensionEmbeddingHnswIndexes`) and is published on
  `.well-known/loopctl`. Changing this config alone is NOT enough — a new
  dimension needs a migration that builds its indexes CONCURRENTLY. Index DDL is
  operator/migration plane only; nothing on the request path may issue it.
  """
  @spec supported_dimensions() :: [pos_integer()]
  def supported_dimensions do
    # SINGLE-SOURCED with the read path: `VectorSearch` can only emit a
    # per-dimension cast for a dimension in its COMPILE-TIME set, so publishing (or
    # index-building for) any other value would advertise recall the query builder
    # physically cannot produce.
    VectorSearch.supported_dimensions()
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "True when `dim` is in the published supported set."
  @spec supported_dimension?(term()) :: boolean()
  def supported_dimension?(dim), do: dim in supported_dimensions()

  @doc """
  The deployment default dimension (`:embedding_dimensions`, 1536) — the value a
  tenant with no explicit model gets, preserving the pre-41.1 config semantics.
  """
  @spec default_dimension() :: pos_integer()
  def default_dimension, do: Application.get_env(:loopctl, :embedding_dimensions, 1536)

  @doc "The dimension the LEGACY `articles.embedding` / `memories.embedding` columns are typed at."
  @spec legacy_dimension() :: pos_integer()
  def legacy_dimension, do: 1536

  # ---------------------------------------------------------------------------
  # The tenant's active dimension (AC-41.1.4 / AC-41.1.11)
  # ---------------------------------------------------------------------------

  @doc """
  The tenant's ACTIVE embedding dimension.

  Precedence:

    1. `tenants.tenant_embedding_dimension` — the explicitly recorded value
       (written by an operator, or by the US-41.2 endpoint probe, which is
       authoritative because it reflects what the real endpoint returned).
    2. the static model table applied to `tenant_llm_settings.embedding_model`.
    3. `default_dimension/0`.

  Call this ONCE per operation or batch and thread the result into the
  changesets — never per item (AC-41.1.11). Both lookups are served from caches
  (`Llm.get_settings/1` is ETS-backed), but the contract is the call site's:
  `upsert_article_embeddings/3` resolves once for the whole batch.
  """
  @spec active_dimension(Ecto.UUID.t()) :: pos_integer()
  def active_dimension(tenant_id) when is_binary(tenant_id) do
    recorded_dimension(tenant_id) || model_dimension(tenant_id) || default_dimension()
  end

  defp recorded_dimension(tenant_id) do
    AdminRepo.one(
      from(t in Tenant,
        where: t.id == ^tenant_id,
        select: t.tenant_embedding_dimension
      )
    )
  end

  defp model_dimension(tenant_id) do
    case Llm.get_settings(tenant_id) do
      %{embedding_model: model} -> Dimensions.for_model(model)
      _ -> nil
    end
  end

  @doc """
  Records `dimension` on the tenant.

  Rejects a dimension outside the published supported set: an unsupported
  dimension has no ANN index, so accepting it would silently degrade that tenant
  to a sequential scan of the whole corpus. (The CONFIG-TIME rejection an agent
  sees when it names an unsupported model is US-41.2's probe; this is the
  data-layer backstop.)
  """
  @spec set_tenant_dimension(Ecto.UUID.t(), pos_integer()) ::
          {:ok, Tenant.t()} | {:error, :unsupported_dimension | Ecto.Changeset.t()}
  def set_tenant_dimension(tenant_id, dimension)
      when is_binary(tenant_id) and is_integer(dimension) do
    if supported_dimension?(dimension) do
      case AdminRepo.get(Tenant, tenant_id) do
        nil ->
          {:error, :not_found}

        tenant ->
          tenant
          |> Ecto.Changeset.change(tenant_embedding_dimension: dimension)
          |> AdminRepo.update()
      end
    else
      {:error, :unsupported_dimension}
    end
  end

  # ---------------------------------------------------------------------------
  # The cutover flag (AC-41.1.8)
  # ---------------------------------------------------------------------------

  @doc """
  Whether recall reads the SIDE TABLE (`true`) or the legacy column (`false`).

  A `SystemConfig` integer (`0` = legacy, `1` = side table) so the flip and — just
  as importantly — the REVERT are a single operator UPDATE with no redeploy.
  """
  @spec side_table_reads_enabled?() :: boolean()
  def side_table_reads_enabled?, do: SystemConfig.get_int(@read_flag_key, 0) == 1

  @doc "The `SystemConfig` key backing `side_table_reads_enabled?/0`."
  @spec read_flag_key() :: String.t()
  def read_flag_key, do: @read_flag_key

  @doc """
  What recall a tenant can currently get, as a `meta`-ready map.

  A non-default dimension is side-table-only, so before the read flag flips that
  tenant has NO semantic recall — a fact the surface must state rather than return
  an unexplained empty result (AC-41.1.8, AC-41.1.10).
  """
  @spec recall_availability(Ecto.UUID.t()) :: %{
          dimension: pos_integer(),
          reads_side_table: boolean(),
          semantic_available: boolean(),
          reason: String.t() | nil
        }
  def recall_availability(tenant_id) when is_binary(tenant_id) do
    dimension = active_dimension(tenant_id)
    side_table? = side_table_reads_enabled?()

    cond do
      side_table? ->
        %{
          dimension: dimension,
          reads_side_table: true,
          semantic_available: true,
          reason: nil
        }

      dimension == legacy_dimension() ->
        %{
          dimension: dimension,
          reads_side_table: false,
          semantic_available: true,
          reason: nil
        }

      true ->
        %{
          dimension: dimension,
          reads_side_table: false,
          semantic_available: false,
          reason:
            "this tenant embeds at #{dimension} dimensions, which is stored only in the " <>
              "embedding side table; semantic recall becomes available for it once the " <>
              "operator flips the #{@read_flag_key} read flag. Search is keyword-only until then."
        }
    end
  end

  # ---------------------------------------------------------------------------
  # The write path (AC-41.1.4 / AC-41.1.8)
  # ---------------------------------------------------------------------------

  @doc """
  Writes `embedding` for `article` at the tenant's active dimension.

  Resolves the dimension ONCE and delegates to `upsert_article_embedding/5`. Use
  `upsert_article_embeddings/3` for a batch — it resolves once for the WHOLE batch
  (AC-41.1.11).
  """
  @spec upsert_article_embedding(Ecto.UUID.t(), Article.t(), [float()] | nil, String.t() | nil) ::
          {:ok, ArticleEmbedding.t()} | {:error, term()}
  def upsert_article_embedding(tenant_id, %Article{} = article, embedding, content_hash \\ nil) do
    upsert_article_embedding(
      tenant_id,
      article,
      embedding,
      content_hash,
      active_dimension(tenant_id)
    )
  end

  @doc """
  Writes `embedding` at an EXPLICIT `dimension` (resolved by the caller).

  ## One transaction, both locations (AC-41.1.8(i))

  When `dimension == 1536` the legacy `articles.embedding` column and the side-table
  row are written inside a SINGLE `Ecto.Multi`. Two separate writes would leave a
  crash window in which the legacy row exists but the side-table row does not — and
  the resumable backfill of AC-41.1.9 would SKIP that article forever, because the
  backfill's cursor only knows "does a legacy embedding exist", not "was it
  mirrored". That gap is what `reconcile_articles/1` exists to catch.
  """
  @spec upsert_article_embedding(
          Ecto.UUID.t(),
          Article.t(),
          [float()] | nil,
          String.t() | nil,
          pos_integer()
        ) :: {:ok, ArticleEmbedding.t()} | {:error, term()}
  def upsert_article_embedding(
        tenant_id,
        %Article{} = article,
        embedding,
        content_hash,
        dimension
      )
      when is_binary(tenant_id) and is_integer(dimension) do
    Multi.new()
    |> article_embedding_multi(tenant_id, article, embedding, content_hash, dimension)
    |> AdminRepo.transaction()
    |> case do
      {:ok, %{side_table: row}} -> {:ok, row}
      {:error, _step, reason, _done} -> {:error, reason}
    end
  end

  @doc """
  Adds the AC-41.1.8(i) dual-write steps (`:legacy` when `dimension == 1536`, plus
  `:side_table`) to an EXISTING `Ecto.Multi`.

  This is the composition seam the real request/worker write paths use
  (`Loopctl.Knowledge.update_embedding/4`, `Loopctl.Memory.update_memory_embedding/4`)
  so the legacy column, the side-table row AND their audit entry all commit in ONE
  transaction. Two separate transactions would leave the exact crash window
  `reconcile_articles/1` has to sweep up; one transaction makes that window
  unreachable on the happy path.
  """
  @spec article_embedding_multi(
          Multi.t(),
          Ecto.UUID.t(),
          Article.t(),
          [float()] | nil,
          String.t() | nil,
          pos_integer()
        ) :: Multi.t()
  def article_embedding_multi(multi, tenant_id, %Article{} = article, embedding, hash, dimension) do
    multi
    |> maybe_write_legacy_article(article, embedding, hash, dimension)
    |> Multi.run(:side_table, fn repo, _changes ->
      upsert_article_embedding_row(repo, tenant_id, article, embedding, hash, dimension)
    end)
  end

  @doc "The memories twin of `article_embedding_multi/6`."
  @spec memory_embedding_multi(
          Multi.t(),
          Ecto.UUID.t(),
          Memory.t(),
          [float()] | nil,
          String.t() | nil,
          pos_integer()
        ) :: Multi.t()
  def memory_embedding_multi(multi, tenant_id, %Memory{} = memory, embedding, hash, dimension) do
    multi
    |> maybe_write_legacy_memory(memory, embedding, hash, dimension)
    |> Multi.run(:side_table, fn repo, _changes ->
      upsert_memory_embedding_row(repo, tenant_id, memory, embedding, hash, dimension)
    end)
  end

  @doc """
  Deletes every side-table row for `article_id` — the side-table half of
  "clear this article's embedding".
  """
  @spec delete_article_embeddings(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, non_neg_integer()}
  def delete_article_embeddings(tenant_id, article_id) do
    {n, _} =
      AdminRepo.delete_all(
        from(ae in ArticleEmbedding,
          where: ae.tenant_id == ^tenant_id and ae.article_id == ^article_id
        )
      )

    {:ok, n}
  end

  @doc """
  Batch form: resolves the tenant's dimension ONCE and writes every
  `{article, embedding, content_hash}` triple at that dimension.

  This is the US-37.4 ~100-article batch path. It performs NO per-item tenant or
  settings query (TC-41.1.9) — the dimension is resolved before the loop and
  threaded into every changeset.
  """
  @spec upsert_article_embeddings(
          Ecto.UUID.t(),
          [{Article.t(), [float()], String.t() | nil}],
          keyword()
        ) :: {:ok, [ArticleEmbedding.t()]} | {:error, term()}
  def upsert_article_embeddings(tenant_id, entries, opts \\ []) when is_binary(tenant_id) do
    dimension = Keyword.get(opts, :dimension) || active_dimension(tenant_id)

    Enum.reduce_while(entries, {:ok, []}, fn {article, embedding, hash}, {:ok, acc} ->
      case upsert_article_embedding(tenant_id, article, embedding, hash, dimension) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      other -> other
    end
  end

  @doc """
  Writes `embedding` for `memory` at an explicit `dimension`.

  Mirrors `upsert_article_embedding/5`. `subject_id` is denormalized onto the row
  so recall can satisfy `HeavyRead.guard_memory!/3`'s outermost subject equality
  without joining `memories` inside the index-ordered ANN.
  """
  @spec upsert_memory_embedding(
          Ecto.UUID.t(),
          Memory.t(),
          [float()] | nil,
          String.t() | nil,
          pos_integer()
        ) :: {:ok, MemoryEmbedding.t()} | {:error, term()}
  def upsert_memory_embedding(tenant_id, %Memory{} = memory, embedding, content_hash, dimension)
      when is_binary(tenant_id) and is_integer(dimension) do
    Multi.new()
    |> memory_embedding_multi(tenant_id, memory, embedding, content_hash, dimension)
    |> AdminRepo.transaction()
    |> case do
      {:ok, %{side_table: row}} -> {:ok, row}
      {:error, _step, reason, _done} -> {:error, reason}
    end
  end

  # Dual-write is dim-1536-only: pgvector hard-errors on a non-1536 value in a
  # vector(1536) column, so for any other dimension the side table is the only
  # location and this step is skipped entirely.
  defp maybe_write_legacy_article(multi, article, embedding, content_hash, dimension) do
    if dimension == legacy_dimension() do
      Multi.update(
        multi,
        :legacy,
        Article.embedding_changeset(article, embedding, content_hash, dimension)
      )
    else
      multi
    end
  end

  defp maybe_write_legacy_memory(multi, memory, embedding, content_hash, dimension) do
    if dimension == legacy_dimension() do
      Multi.update(
        multi,
        :legacy,
        Memory.embedding_changeset(memory, embedding, content_hash, dimension)
      )
    else
      multi
    end
  end

  @doc """
  Upserts ONE article side-table row using the CALLER's repo/transaction.

  Public so a caller that already owns a transaction (`Loopctl.Knowledge.update_embedding/4`,
  which also writes the legacy column and the audit entry) can write the side-table
  row INSIDE it — AC-41.1.8(i)'s "one transaction, both locations".
  """
  @spec upsert_article_embedding_row(
          module(),
          Ecto.UUID.t(),
          Article.t(),
          [float()] | nil,
          String.t() | nil,
          pos_integer()
        ) :: {:ok, ArticleEmbedding.t()} | {:error, Ecto.Changeset.t()}
  def upsert_article_embedding_row(repo, tenant_id, article, embedding, content_hash, dimension) do
    existing =
      repo.one(
        from(ae in ArticleEmbedding,
          where:
            ae.tenant_id == ^tenant_id and ae.article_id == ^article.id and ae.dim == ^dimension
        )
      )

    (existing || %ArticleEmbedding{tenant_id: tenant_id})
    |> ArticleEmbedding.changeset(
      %{article_id: article.id, embedding: embedding, embedding_content_hash: content_hash},
      dimension
    )
    |> repo.insert_or_update()
  end

  @doc """
  Upserts ONE memory side-table row using the CALLER's repo/transaction.

  Public so a caller that already owns a transaction (the promotion path) can write
  the side-table row inside it rather than opening a second one.
  """
  @spec upsert_memory_embedding_row(
          module(),
          Ecto.UUID.t(),
          Memory.t(),
          [float()] | nil,
          String.t() | nil,
          pos_integer()
        ) :: {:ok, MemoryEmbedding.t()} | {:error, Ecto.Changeset.t()}
  def upsert_memory_embedding_row(repo, tenant_id, memory, embedding, content_hash, dimension) do
    existing =
      repo.one(
        from(me in MemoryEmbedding,
          where:
            me.tenant_id == ^tenant_id and me.memory_id == ^memory.id and me.dim == ^dimension
        )
      )

    (existing || %MemoryEmbedding{tenant_id: tenant_id})
    |> MemoryEmbedding.changeset(
      %{
        memory_id: memory.id,
        subject_id: memory.subject_id,
        embedding: embedding,
        embedding_content_hash: content_hash
      },
      dimension
    )
    |> repo.insert_or_update()
  end

  # ---------------------------------------------------------------------------
  # Backfill (AC-41.1.9) + reconciliation (AC-41.1.8(i))
  # ---------------------------------------------------------------------------

  @doc """
  Copies every legacy `articles.embedding` into the side table at dim 1536.

  RESUMABLE and BATCHED: the cursor is the article `id` (a UUID, totally ordered),
  and the batch is an anti-join against rows already present at dim 1536, so an
  interrupted run resumes with no double work and a completed run re-run is a
  no-op (no duplicates — TC-41.1.3). The legacy column is LEFT IN PLACE and
  unused; dropping it is a deliberate follow-up so rollback stays trivial.

  Returns `{:ok, %{copied: n, batches: b}}`.
  """
  @spec backfill_articles(keyword()) ::
          {:ok, %{copied: non_neg_integer(), batches: non_neg_integer()}}
  def backfill_articles(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    max_batches = Keyword.get(opts, :max_batches, :infinity)
    run_backfill(&article_backfill_batch/1, batch_size, max_batches)
  end

  @doc "The memories twin of `backfill_articles/1`."
  @spec backfill_memories(keyword()) ::
          {:ok, %{copied: non_neg_integer(), batches: non_neg_integer()}}
  def backfill_memories(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    max_batches = Keyword.get(opts, :max_batches, :infinity)
    run_backfill(&memory_backfill_batch/1, batch_size, max_batches)
  end

  defp run_backfill(batch_fun, batch_size, max_batches) do
    Enum.reduce_while(Stream.iterate(0, &(&1 + 1)), %{copied: 0, batches: 0}, fn _i, acc ->
      if batch_budget_exhausted?(acc, max_batches) do
        {:halt, acc}
      else
        run_backfill_batch(batch_fun, batch_size, acc)
      end
    end)
    |> then(&{:ok, &1})
  end

  defp batch_budget_exhausted?(_acc, :infinity), do: false
  defp batch_budget_exhausted?(acc, max_batches), do: acc.batches >= max_batches

  defp run_backfill_batch(batch_fun, batch_size, acc) do
    case batch_fun.(batch_size) do
      0 -> {:halt, acc}
      n -> {:cont, %{copied: acc.copied + n, batches: acc.batches + 1}}
    end
  end

  # One batch, as a single INSERT ... SELECT so the vector never round-trips
  # through the BEAM. `ON CONFLICT DO NOTHING` makes a re-run idempotent; the
  # BEFORE-INSERT trigger sets `live_denorm` from the parent's status, so the
  # backfill cannot desynchronize the marker either.
  defp article_backfill_batch(batch_size) do
    {count, _} =
      AdminRepo.query!(
        """
        INSERT INTO article_embeddings
          (id, tenant_id, article_id, dim, embedding, live_denorm, embedding_content_hash,
           inserted_at, updated_at)
        SELECT gen_random_uuid(), a.tenant_id, a.id, $1, a.embedding, true,
               a.embedding_content_hash, NOW(), NOW()
        FROM articles a
        WHERE a.embedding IS NOT NULL
          AND a.tenant_id IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM article_embeddings ae
            WHERE ae.article_id = a.id AND ae.tenant_id = a.tenant_id AND ae.dim = $1
          )
        LIMIT $2
        ON CONFLICT DO NOTHING
        """,
        [legacy_dimension(), batch_size]
      )
      |> then(&{&1.num_rows, &1})

    count
  end

  defp memory_backfill_batch(batch_size) do
    {count, _} =
      AdminRepo.query!(
        """
        INSERT INTO memory_embeddings
          (id, tenant_id, memory_id, subject_id, dim, embedding, live_denorm,
           embedding_content_hash, inserted_at, updated_at)
        SELECT gen_random_uuid(), m.tenant_id, m.id, m.subject_id, $1, m.embedding, true,
               m.embedding_content_hash, NOW(), NOW()
        FROM memories m
        WHERE m.embedding IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM memory_embeddings me
            WHERE me.memory_id = m.id AND me.tenant_id = m.tenant_id AND me.dim = $1
          )
        LIMIT $2
        ON CONFLICT DO NOTHING
        """,
        [legacy_dimension(), batch_size]
      )
      |> then(&{&1.num_rows, &1})

    count
  end

  @doc """
  Finds articles whose LEGACY embedding has no matching side-table row at dim 1536
  — the crash-between-the-two-writes gap (AC-41.1.8(i)).

  The resumable backfill of AC-41.1.9 alone does NOT catch this class once it has
  completed: the operator considers the corpus migrated and stops running it. The
  reconciliation pass is a standing, cheap anti-join that any half-write shows up
  in, and `reconcile_articles/1` repairs them by re-running the same idempotent
  copy.
  """
  @spec article_reconciliation_gaps(keyword()) :: [Ecto.UUID.t()]
  def article_reconciliation_gaps(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_batch_size)

    AdminRepo.all(
      from(a in Article,
        as: :article,
        where: not is_nil(a.embedding) and not is_nil(a.tenant_id),
        where:
          not exists(
            from(ae in ArticleEmbedding,
              where:
                ae.article_id == parent_as(:article).id and
                  ae.tenant_id == parent_as(:article).tenant_id and
                  ae.dim == ^legacy_dimension(),
              select: 1
            )
          ),
        select: a.id,
        limit: ^limit
      )
    )
  end

  @doc "The memories twin of `article_reconciliation_gaps/1`."
  @spec memory_reconciliation_gaps(keyword()) :: [Ecto.UUID.t()]
  def memory_reconciliation_gaps(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_batch_size)

    AdminRepo.all(
      from(m in Memory,
        as: :memory,
        where: not is_nil(m.embedding),
        where:
          not exists(
            from(me in MemoryEmbedding,
              where:
                me.memory_id == parent_as(:memory).id and
                  me.tenant_id == parent_as(:memory).tenant_id and
                  me.dim == ^legacy_dimension(),
              select: 1
            )
          ),
        select: m.id,
        limit: ^limit
      )
    )
  end

  @doc """
  Repairs every gap `article_reconciliation_gaps/1` reports, returning
  `{:ok, %{repaired: n}}`.
  """
  @spec reconcile_articles(keyword()) :: {:ok, %{repaired: non_neg_integer()}}
  def reconcile_articles(opts \\ []) do
    {:ok, %{copied: copied}} = backfill_articles(opts)
    {:ok, %{repaired: copied}}
  end

  @doc "The memories twin of `reconcile_articles/1`."
  @spec reconcile_memories(keyword()) :: {:ok, %{repaired: non_neg_integer()}}
  def reconcile_memories(opts \\ []) do
    {:ok, %{copied: copied}} = backfill_memories(opts)
    {:ok, %{repaired: copied}}
  end

  # ---------------------------------------------------------------------------
  # System-scoped corpus materialization (AC-41.1.7)
  # ---------------------------------------------------------------------------

  @doc """
  System-scoped articles (`scope: :system`, `tenant_id IS NULL`) that `tenant_id`
  has NOT yet materialized an embedding row for at `dimension`.

  System articles cannot be embedded once for everyone: embeddings are BYO and
  mandatory (`EmbeddingClient` returns `{:error, :no_api_key}` with no operator
  fallback, and the global operator key was deliberately removed), and a NULL
  `tenant_id` row could never satisfy `HeavyRead.guard!/2`'s conjunctive tenant
  predicate. They are therefore embedded ON DEMAND PER TENANT with the requesting
  tenant's own credential and stored as ordinary rows carrying THAT tenant_id.
  """
  @spec unmaterialized_system_articles(Ecto.UUID.t(), pos_integer(), keyword()) :: [Article.t()]
  def unmaterialized_system_articles(tenant_id, dimension, opts \\ [])
      when is_binary(tenant_id) and is_integer(dimension) do
    limit = Keyword.get(opts, :limit, @default_batch_size)

    AdminRepo.all(
      from(a in Article,
        as: :article,
        where: a.scope == :system and is_nil(a.tenant_id),
        where:
          not exists(
            from(ae in ArticleEmbedding,
              where:
                ae.article_id == parent_as(:article).id and
                  ae.tenant_id == ^tenant_id and
                  ae.dim == ^dimension,
              select: 1
            )
          ),
        limit: ^limit
      )
    )
  end

  @doc """
  Writes ONE system-scoped article's vector as a per-tenant `article_embeddings`
  row (AC-41.1.7).

  Deliberately NOT a dual-write: the legacy `articles.embedding` column is a single
  GLOBAL slot on a row shared by every tenant, so writing tenant A's vector there
  would overwrite tenant B's — and for a non-1536 tenant it is physically
  impossible anyway. System-article vectors are side-table-ONLY, always.
  """
  @spec materialize_system_article_embedding(
          Ecto.UUID.t(),
          Article.t(),
          [float()],
          String.t() | nil,
          pos_integer()
        ) :: {:ok, ArticleEmbedding.t()} | {:error, term()}
  def materialize_system_article_embedding(tenant_id, %Article{} = article, embedding, hash, dim)
      when is_binary(tenant_id) and is_integer(dim) do
    upsert_article_embedding_row(AdminRepo, tenant_id, article, embedding, hash, dim)
  end

  @doc """
  Enqueues the on-demand per-tenant materialization of the system corpus at the
  tenant's ACTIVE dimension (AC-41.1.7).

  Idempotent: the worker is `unique` per `(tenant_id, dim)` and its batch query is
  an anti-join, so re-enqueuing while a run is in flight is a no-op and a completed
  corpus makes the job an immediate `:ok`.
  """
  @spec enqueue_system_corpus_materialization(Ecto.UUID.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_system_corpus_materialization(tenant_id, opts \\ []) when is_binary(tenant_id) do
    dimension = Keyword.get(opts, :dimension) || active_dimension(tenant_id)

    %{tenant_id: tenant_id, dim: dimension}
    |> SystemCorpusEmbeddingWorker.new()
    |> Oban.insert()
  end

  @doc """
  Enqueues the agent-triggerable RE-EMBED backfill onto `target_dimension`
  (AC-41.1.10).

  The tenant's ACTIVE dimension is deliberately NOT changed here. Old and new
  dimension rows COEXIST (uniqueness is `(id, dim)`) and recall keeps serving at the
  ACTIVE dimension for the whole window — the query vector is always generated at
  the active dimension, never the pending one. Only when the backfill reports
  completion does the worker flip `tenants.tenant_embedding_dimension` and drop the
  stale-dimension rows. Without that ordering the endpoint PATCH alone would make
  every query vector disagree with the whole corpus: a total recall blackout.
  """
  @spec enqueue_reembed(Ecto.UUID.t(), pos_integer()) ::
          {:ok, Oban.Job.t()} | {:error, :unsupported_dimension | term()}
  def enqueue_reembed(tenant_id, target_dimension)
      when is_binary(tenant_id) and is_integer(target_dimension) do
    if supported_dimension?(target_dimension) do
      %{tenant_id: tenant_id, target_dim: target_dimension}
      |> ReembedWorker.new()
      |> Oban.insert()
    else
      {:error, :unsupported_dimension}
    end
  end

  @doc """
  Re-embed progress for `tenant_id` onto `target_dimension`: how many of the
  tenant's ACTIVE-dimension rows already have a `target_dimension` twin.

  This is the AC-41.1.10 progress surface AND the source of the "rows excluded from
  PENDING-dimension recall" number the search `meta` reports.
  """
  @spec reembed_progress(Ecto.UUID.t(), pos_integer()) :: %{
          active_dimension: pos_integer(),
          target_dimension: pos_integer(),
          total: non_neg_integer(),
          done: non_neg_integer(),
          pending: non_neg_integer(),
          complete: boolean()
        }
  def reembed_progress(tenant_id, target_dimension)
      when is_binary(tenant_id) and is_integer(target_dimension) do
    active = active_dimension(tenant_id)
    counts = dimension_counts(tenant_id)
    total = Map.get(counts, active, 0)
    done = Map.get(counts, target_dimension, 0)

    %{
      active_dimension: active,
      target_dimension: target_dimension,
      total: total,
      done: min(done, total),
      pending: max(total - done, 0),
      complete: total > 0 and done >= total
    }
  end

  @doc """
  The AC-41.1.10 search-`meta` disclosure for an IN-FLIGHT re-embed.

  When a tenant has rows at more than one dimension, recall is served at the ACTIVE
  dimension and every row not yet re-embedded at the pending dimension is EXCLUDED
  from pending-dimension recall rather than compared incorrectly (pgvector would
  error on a cross-dimension comparison). The exclusion is reported so an agent can
  see WHY recall shrank instead of inferring it from a short result set.

  Returns `%{}` when nothing is in flight, so the caller can `Map.merge/2` it
  unconditionally.
  """
  @spec reembed_meta(Ecto.UUID.t(), pos_integer() | nil) :: map()
  def reembed_meta(tenant_id, active \\ nil) when is_binary(tenant_id) do
    active = active || active_dimension(tenant_id)

    # HOT PATH: this runs on EVERY semantic search, so the common case (no re-embed
    # in flight) must not pay for a grouped count over the tenant's whole embedding
    # corpus. A `LIMIT 1` existence probe on the `(tenant_id, dim)` btree stops at
    # the first off-dimension row — index-only and O(1) — and only a tenant that is
    # actually mid-re-embed pays for the counts below.
    if reembed_in_flight?(tenant_id, active) do
      build_reembed_meta(tenant_id, active)
    else
      %{}
    end
  end

  defp reembed_in_flight?(tenant_id, active) do
    AdminRepo.exists?(
      from(ae in ArticleEmbedding,
        where: ae.tenant_id == ^tenant_id and ae.dim != ^active,
        limit: 1
      )
    )
  end

  defp build_reembed_meta(tenant_id, active) do
    counts = dimension_counts(tenant_id)

    case counts |> Map.keys() |> Enum.reject(&(&1 == active)) do
      [] ->
        %{}

      [pending_dim | _] = pending_dims ->
        progress = reembed_progress(tenant_id, pending_dim)

        %{
          reembed_in_progress: true,
          reembed_active_dimension: active,
          reembed_pending_dimensions: Enum.sort(pending_dims),
          reembed_pending_rows: progress.pending,
          reembed_excluded_reason:
            "a re-embed onto #{pending_dim} dimensions is in flight. Recall is served at " <>
              "the ACTIVE #{active}-dimension corpus; #{progress.pending} row(s) are not yet " <>
              "re-embedded at #{pending_dim} and are excluded from pending-dimension recall " <>
              "rather than compared across dimensions."
        }
    end
  end

  @doc """
  Drops every side-table row for `tenant_id` at a dimension OTHER than `keep_dim`
  — the AC-41.1.10 stale-dimension cleanup, run only AFTER the re-embed reports
  completion.
  """
  @spec drop_stale_dimensions(Ecto.UUID.t(), pos_integer()) :: {:ok, non_neg_integer()}
  def drop_stale_dimensions(tenant_id, keep_dim)
      when is_binary(tenant_id) and is_integer(keep_dim) do
    {articles, _} =
      AdminRepo.delete_all(
        from(ae in ArticleEmbedding, where: ae.tenant_id == ^tenant_id and ae.dim != ^keep_dim)
      )

    {memories, _} =
      AdminRepo.delete_all(
        from(me in MemoryEmbedding, where: me.tenant_id == ^tenant_id and me.dim != ^keep_dim)
      )

    {:ok, articles + memories}
  end

  @doc """
  The AC-41.1.7 disclosure for the search response `meta`.

  Until a tenant has materialized the system corpus at its active dimension, those
  articles are KEYWORD-ONLY for it. That MUST be stated explicitly — a silent
  absence looks identical to "the system corpus has nothing relevant", which is
  exactly the failure mode this AC exists to prevent.
  """
  @spec system_corpus_meta(Ecto.UUID.t(), pos_integer() | nil) :: map()
  def system_corpus_meta(tenant_id, dimension \\ nil) when is_binary(tenant_id) do
    dimension = dimension || active_dimension(tenant_id)
    pending = length(unmaterialized_system_articles(tenant_id, dimension, limit: 1))

    if pending == 0 do
      %{system_corpus_recall: "semantic", system_corpus_dimension: dimension}
    else
      %{
        system_corpus_recall: "keyword_only",
        system_corpus_dimension: dimension,
        system_corpus_reason:
          "the shared system-scoped corpus has not been embedded for this tenant at " <>
            "#{dimension} dimensions yet. System articles are embedded on demand with THIS " <>
            "tenant's own embedding credential; until that materialization runs they are " <>
            "matched by keyword only."
      }
    end
  end

  @doc """
  Counts a tenant's side-table rows per dimension — the AC-41.1.10 re-embed
  progress surface and the source of the "rows excluded from PENDING-dimension
  recall" number the search `meta` reports.
  """
  @spec dimension_counts(Ecto.UUID.t()) :: %{pos_integer() => non_neg_integer()}
  def dimension_counts(tenant_id) when is_binary(tenant_id) do
    from(ae in ArticleEmbedding,
      where: ae.tenant_id == ^tenant_id,
      group_by: ae.dim,
      select: {ae.dim, count(ae.id)}
    )
    |> AdminRepo.all()
    |> Map.new()
  end
end
