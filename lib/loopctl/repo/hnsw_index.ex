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
