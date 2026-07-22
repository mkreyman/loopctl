defmodule Loopctl.Repo.HnswIndex do
  @moduledoc """
  Single source of truth for the capability-based (`amname = 'hnsw'`) SQL used to
  detect, create, drop, and reconcile the HNSW index on a pgvector table's
  `embedding` column.

  ## Why this module exists

  The HNSW index migrations (`AddEmbeddingHnswIndex`, `ReconcileHnswIndexName`)
  originally inlined this SQL, hard-coded to `public.articles`. That made the
  migration behaviour untestable in isolation: the only way to exercise it was
  to drop / rename / recreate the *shared, live* `articles_embedding_hnsw_idx`
  — a table-level schema object that the Ecto SQL sandbox does **not** isolate
  the way it isolates row data. Manipulating it from a test is manipulating
  global state every other embedding test depends on.

  Parameterising the SQL by table name removes that coupling. The production
  migrations call these functions with the default `"articles"` (emitting the
  same SQL, targeting the same object, producing the same schema — a pure
  refactor). The migration-behaviour test calls them with a per-test,
  uniquely-named THROWAWAY table it creates and drops inside its own sandbox
  transaction, so it exercises the exact same detection / rename / drop logic
  against an ISOLATED object and never touches the shared canonical index.

  Detection is by access method (`am.amname = 'hnsw'`), schema-qualified to
  `public`, NOT by a hard-coded index name — so the logic catches whatever name
  the index actually lives under (prod's `articles_embedding_hnsw_idx`, the old
  migration's `articles_embedding_idx`, or any out-of-band name).

  Index names are derived from the table: `\#{table}_embedding_idx` (the old
  migration's create name) and `\#{table}_embedding_hnsw_idx` (the canonical
  reconciled name).

  ## Build-time HNSW parameters (`m` / `ef_construction`) — US-38.4

  Every `CREATE INDEX ... USING hnsw` this module emits now carries an EXPLICIT
  `WITH (m = .., ef_construction = ..)` storage clause instead of relying on
  pgvector's implicit defaults. The chosen values EQUAL pgvector's defaults
  (`m = 16`, `ef_construction = 64`) — a deliberate, documented "keep the
  defaults" outcome (see `docs/hnsw-tuning-evaluation.md`) — but making them
  explicit means they are now an intentional, single-sourced, operator-tunable
  decision rather than an implicit accident. Because the values are unchanged, no
  reindex of the live `articles` / `memories` indexes is needed: they were built
  with these exact defaults, so re-emitting them here only affects indexes created
  FROM NOW ON (a fresh `mix ecto.reset`, or a future table). To change them, set
  `config :loopctl, :hnsw_m` / `:hnsw_ef_construction` AND ship an ONLINE reindex
  migration (`CREATE INDEX CONCURRENTLY` a new index with the new params, then drop
  the old) — `m`/`ef_construction` are BUILD-time and cannot be `ALTER`ed in place.

  `ef_search` (the per-QUERY recall breadth) is a separate, query-time knob and
  lives on the read path (`Loopctl.HeavyRead`), NOT here.
  """

  # pgvector's own defaults. Kept explicit + configurable (US-38.4) — see the
  # moduledoc and docs/hnsw-tuning-evaluation.md for the keep-the-defaults rationale.
  @default_hnsw_m 16
  @default_hnsw_ef_construction 64

  @doc """
  The configured HNSW `m` build parameter (config `:hnsw_m`, default
  #{@default_hnsw_m} = pgvector's default). Integer-validated.
  """
  @spec hnsw_m() :: pos_integer()
  def hnsw_m,
    do: validate_build_param!(:m, Application.get_env(:loopctl, :hnsw_m, @default_hnsw_m))

  @doc """
  The configured HNSW `ef_construction` build parameter (config
  `:hnsw_ef_construction`, default #{@default_hnsw_ef_construction} = pgvector's
  default). Integer-validated.
  """
  @spec hnsw_ef_construction() :: pos_integer()
  def hnsw_ef_construction do
    validate_build_param!(
      :ef_construction,
      Application.get_env(:loopctl, :hnsw_ef_construction, @default_hnsw_ef_construction)
    )
  end

  @doc """
  The `WITH (m = .., ef_construction = ..)` storage-parameter clause appended to
  every `CREATE INDEX ... USING hnsw` this module (and the partial-index migration)
  emits.

  Both values are integer-validated (`validate_build_param!/2`) before
  interpolation — mirroring the `validate!/1` SQL-identifier guard, they can NEVER
  carry anything but a positive integer, so this is not an injection surface even
  though the values flow from application config.
  """
  @spec with_params_clause() :: String.t()
  def with_params_clause,
    do: "WITH (m = #{hnsw_m()}, ef_construction = #{hnsw_ef_construction()})"

  @doc "The canonical (reconciled) HNSW index name for `table`."
  @spec canonical_index_name(String.t()) :: String.t()
  def canonical_index_name(table), do: "#{validate!(table)}_embedding_hnsw_idx"

  @doc "The name the old create-migration uses for `table`'s HNSW index."
  @spec migration_index_name(String.t()) :: String.t()
  def migration_index_name(table), do: "#{validate!(table)}_embedding_idx"

  @doc """
  SQL that creates the HNSW index (named `\#{table}_embedding_idx`) only when the
  `embedding` column exists AND no HNSW index (by access method) is already
  present on the table — so from a drifted state where the index lives under a
  different name, this does NOT create a second, redundant HNSW index.
  """
  @spec create_if_absent_sql(String.t()) :: String.t()
  def create_if_absent_sql(table \\ "articles") do
    table = validate!(table)

    """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = '#{table}' AND column_name = 'embedding') THEN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_index x
          JOIN pg_class i ON i.oid = x.indexrelid
          JOIN pg_class t ON t.oid = x.indrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          JOIN pg_am    am ON am.oid = i.relam
          WHERE t.relname = '#{table}' AND n.nspname = 'public' AND am.amname = 'hnsw'
        ) THEN
          CREATE INDEX #{table}_embedding_idx ON #{table} USING hnsw (embedding vector_cosine_ops) #{with_params_clause()};
        END IF;
      END IF;
    END $$;
    """
  end

  @doc """
  SQL that drops EVERY HNSW index (by access method, not by name) present on
  `table`, so a rollback leaves none orphaned regardless of the name the index
  lives under.
  """
  @spec drop_all_sql(String.t()) :: String.t()
  def drop_all_sql(table \\ "articles") do
    table = validate!(table)

    """
    DO $$
    DECLARE idx text;
    BEGIN
      FOR idx IN
        SELECT i.relname
        FROM pg_index x
        JOIN pg_class i ON i.oid = x.indexrelid
        JOIN pg_class t ON t.oid = x.indrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_am    am ON am.oid = i.relam
        WHERE t.relname = '#{table}' AND n.nspname = 'public' AND am.amname = 'hnsw'
      LOOP
        EXECUTE format('DROP INDEX IF EXISTS %I', idx);
      END LOOP;
    END $$;
    """
  end

  @doc """
  Idempotent reconcile SQL: if the canonical `\#{table}_embedding_hnsw_idx`
  HNSW index already exists, no-op; otherwise rename whichever HNSW index is
  present (detected by access method, schema-qualified to `public`) up to the
  canonical name. If a non-HNSW relation squats the canonical name the RENAME
  target is occupied and Postgres raises — surfacing the conflict rather than
  silently reporting success.
  """
  @spec reconcile_sql(String.t()) :: String.t()
  def reconcile_sql(table \\ "articles") do
    table = validate!(table)

    """
    DO $$
    DECLARE idx text;
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM pg_index x
        JOIN pg_class i ON i.oid = x.indexrelid
        JOIN pg_class t ON t.oid = x.indrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_am    am ON am.oid = i.relam
        WHERE t.relname = '#{table}'
          AND n.nspname = 'public'
          AND am.amname = 'hnsw'
          AND i.relname = '#{table}_embedding_hnsw_idx'
      ) THEN
        RETURN;
      END IF;

      SELECT i.relname INTO idx
      FROM pg_index x
      JOIN pg_class i ON i.oid = x.indexrelid
      JOIN pg_class t ON t.oid = x.indrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      JOIN pg_am    am ON am.oid = i.relam
      WHERE t.relname = '#{table}' AND n.nspname = 'public' AND am.amname = 'hnsw'
      LIMIT 1;

      IF idx IS NOT NULL THEN
        EXECUTE format('ALTER INDEX %I RENAME TO #{table}_embedding_hnsw_idx', idx);
      END IF;
    END $$;
    """
  end

  # ---------------------------------------------------------------------------
  # US-41.1 AC-41.1.2 — PER-DIMENSION expression indexes on the embedding side
  # tables (`article_embeddings` / `memory_embeddings`).
  # ---------------------------------------------------------------------------

  @doc """
  The canonical per-dimension HNSW index name for `table` at `dim`
  (e.g. `article_embeddings_hnsw_dim_768_idx`).
  """
  @spec dimension_index_name(String.t(), pos_integer()) :: String.t()
  def dimension_index_name(table, dim),
    do: "#{validate!(table)}_hnsw_dim_#{validate_dimension!(dim)}_idx"

  @doc """
  SQL creating the per-dimension partial HNSW expression index for `table` at
  `dim`, CONCURRENTLY, detected by EXACT NAME.

  ## Why an expression index over an explicit cast (AC-41.1.2)

  pgvector refuses to build an `hnsw`/`ivfflat` index on a `vector` column with no
  dimension modifier, and a `WHERE dim = N` partial predicate does NOT supply a
  typmod. The side tables therefore carry an UNCONSTRAINED `vector` column and the
  index is built over the explicit cast `(embedding::vector(N))`. Verified against
  pgvector 0.8.2: the index builds, and — on a corpus large enough for the index to
  be the cheaper path — the planner CHOOSES it for a query whose `ORDER BY` uses the
  IDENTICAL cast expression, with no `enable_seqscan = off`. The query side lives in
  `Loopctl.Knowledge.VectorSearch.index_safe_dimension_knn_base/6`; the cast there
  and the cast here must stay character-identical or the planner cannot match them.

  Each index also carries the AC-41.1.1 live-row predicate (`AND live_denorm`), the
  side-table analogue of US-28.2's `WHERE superseded_by IS NULL`, so superseded rows
  are simply NOT IN the index and can never occupy an ANN pool slot.

  ## Detection is BY NAME, never by access method

  `create_if_absent_sql/1`'s `am.amname = 'hnsw'` capability check would see the
  FIRST per-dimension index and skip every subsequent one (the same trap migration
  `20260709000300` already had to avoid). There are intentionally N HNSW indexes per
  side table — one per supported dimension.
  """
  @spec create_dimension_index_sql(String.t(), pos_integer()) :: String.t()
  def create_dimension_index_sql(table, dim) do
    table = validate!(table)
    dim = validate_dimension!(dim)
    index = dimension_index_name(table, dim)

    """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{index}
      ON #{table}
      USING hnsw ((embedding::vector(#{dim})) vector_cosine_ops)
      #{with_params_clause()}
      WHERE dim = #{dim} AND live_denorm;
    """
  end

  @doc "SQL dropping the per-dimension HNSW index for `table` at `dim`."
  @spec drop_dimension_index_sql(String.t(), pos_integer()) :: String.t()
  def drop_dimension_index_sql(table, dim),
    do: "DROP INDEX CONCURRENTLY IF EXISTS #{dimension_index_name(table, dim)};"

  # The two embedding side tables that carry a per-dimension HNSW index per supported
  # dimension.
  @side_tables ["article_embeddings", "memory_embeddings"]

  @doc """
  Every per-dimension HNSW index the CURRENT published supported-dimension set
  requires across both embedding side tables, as `{table, dim, index_name}` triples.

  The dimension set is read from `:supported_embedding_dimensions` config — the SAME
  set `.well-known` advertises and `Loopctl.Embeddings.supported_dimensions/0`
  delegates to — so this is exactly "what the instance PUBLISHES must be indexed".
  """
  @spec required_dimension_indexes() :: [{String.t(), pos_integer(), String.t()}]
  def required_dimension_indexes do
    dims = Application.get_env(:loopctl, :supported_embedding_dimensions, [768, 1024, 1536])

    for table <- @side_tables, dim <- dims do
      {table, dim, dimension_index_name(table, dim)}
    end
  end

  @doc """
  The `required_dimension_indexes/0` that are ABSENT from `repo`'s catalog — the
  mechanical drift guard for finding 6: "a dimension was PUBLISHED (config +
  `.well-known`) without its per-dimension HNSW index built by a migration".

  That misconfiguration is invisible to the compile-time supported-set guard (the
  cast/where clauses generate fine) yet makes every read at that dimension emit an
  unindexable `(embedding::vector(N))` cast that sequential-scans the whole corpus —
  the #170/#172 planner-incident class. An EMPTY list means every published dimension
  is indexed on BOTH side tables; a non-empty list is a deploy that advertised a
  dimension whose migration has not run. Asserted by a fast (non-scale) drift test so
  it fails on the PR that introduces the config/index mismatch, not in production.
  """
  @spec missing_dimension_indexes(Ecto.Repo.t()) ::
          [{String.t(), pos_integer(), String.t()}]
  def missing_dimension_indexes(repo) do
    Enum.reject(required_dimension_indexes(), fn {_table, _dim, name} ->
      %{rows: [[count]]} =
        repo.query!("SELECT count(*) FROM pg_class WHERE relname = $1", [name])

      count > 0
    end)
  end

  # A dimension is interpolated into DDL, so it is validated to be a plain positive
  # integer. Dimensions come ONLY from the deployment's supported-dimension config
  # (`Loopctl.Embeddings.supported_dimensions/0`), never from a request — index DDL
  # is operator/migration plane only (AC-41.1.3).
  defp validate_dimension!(dim) when is_integer(dim) and dim > 0, do: dim

  defp validate_dimension!(dim) do
    raise ArgumentError, "embedding dimension must be a positive integer, got: #{inspect(dim)}"
  end

  # Table names are internal constants ("articles") or test-generated with
  # System.unique_integer — never user input — but validate defensively so the
  # interpolated identifier can never carry anything but a plain lowercase SQL
  # identifier.
  defp validate!(table) when is_binary(table) do
    if Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, table) do
      table
    else
      raise ArgumentError, "invalid table identifier: #{inspect(table)}"
    end
  end

  # HNSW build params (`m` / `ef_construction`) are interpolated into a CREATE INDEX
  # storage clause, so — like the table identifier — they are validated to be a plain
  # positive integer before ever reaching SQL. They come from application config (an
  # operator knob), never user input, but a mistyped config value fails LOUDLY here
  # rather than emitting malformed DDL. (pgvector further bounds them at build time:
  # m ∈ [2,100], ef_construction ∈ [4,1000] with ef_construction ≥ 2*m; an out-of-range
  # positive integer surfaces as a clear CREATE INDEX error, not an injection.)
  defp validate_build_param!(_name, value) when is_integer(value) and value > 0, do: value

  defp validate_build_param!(name, value) do
    raise ArgumentError,
          "HNSW #{name} must be a positive integer (config), got: #{inspect(value)}"
  end
end
