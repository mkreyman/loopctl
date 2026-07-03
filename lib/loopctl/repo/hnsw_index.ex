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
  """

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
          CREATE INDEX #{table}_embedding_idx ON #{table} USING hnsw (embedding vector_cosine_ops);
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
end
