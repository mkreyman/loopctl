defmodule Loopctl.Repo.Migrations.AddSearchVectorsToBackingTables do
  @moduledoc """
  US-30.3 / AC-30.3.4 — adds INDEXED full-text search columns to the phase-1
  Context-Retriever backing tables (`stories`, `projects`, `epics`).

  Each table gets a `search_vector` `tsvector` column covering ONLY that source's
  allowlisted TEXT columns (US-30.1 `@column_allowlist`), plus a GIN index over
  it. `Loopctl.ContextRetriever.Executor` runs
  `search_vector @@ websearch_to_tsquery('english', ?)` against this column so
  full-text search hits the GIN index instead of an on-the-fly `to_tsvector`
  sequential scan (and never `ILIKE`).

  Column weights mirror the `articles.search_vector` precedent
  (`20260410021836_add_search_vector_to_articles.exs`): the primary title/name
  field is weight `A`, secondary description/mission text `B`/`C`.

  ## Online strategy (repo `CONCURRENTLY` convention)

  `stories` / `projects` / `epics` are the core, most-trafficked work-breakdown
  tables, so this migration MUST NOT take a deploy-time write outage on them.
  A STORED generated column (`ADD COLUMN ... GENERATED ALWAYS AS (...) STORED`)
  would force a full `ACCESS EXCLUSIVE` table REWRITE of every row, and a plain
  (non-`CONCURRENTLY`) `CREATE INDEX` would block writes for the build — a write
  outage on the three hottest tables. Instead, following the repo's established
  `@disable_ddl_transaction` + `CREATE INDEX CONCURRENTLY` convention
  (`20260625120000_add_articles_source_keyset_index.exs`,
  `20260709000100_add_memories_embedding_hnsw_index.exs`), we:

    1. ADD a PLAIN nullable `tsvector` column — a metadata-only catalog change
       (momentary lock, NO table rewrite);
    2. install a `BEFORE INSERT OR UPDATE` trigger that maintains the column,
       giving the same self-maintaining behavior a generated column would have,
       WITHOUT the up-front rewrite;
    3. backfill existing rows in bounded batches, committing between batches (the
       migration runs OUTSIDE a transaction) so no single long-held lock;
    4. build each GIN index `CONCURRENTLY` (no write block).

  `Loopctl.ContextRetriever.Entity.search_vector_columns/0` mirrors the COLUMN
  SET each vector covers; the weighted expressions in `@configs` below MUST stay
  in lockstep with it (stories/epics: title + description; projects: name +
  description + mission).

  These tables already have RLS enabled — this migration only adds a column, a
  trigger, and an index, so it does NOT touch RLS.
  """

  use Ecto.Migration

  # Backfill + CONCURRENTLY index builds cannot run inside a transaction, and the
  # batched backfill needs each batch to commit independently.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Rows updated per backfill batch. Bounded so each UPDATE holds row locks only
  # briefly before committing.
  @backfill_batch_size 5_000

  # table => weighted `{column, weight}` set the search_vector covers. MUST mirror
  # `Entity.search_vector_columns/0`. The weighted tsvector expression is built
  # from this both for the trigger (columns qualified `NEW.`) and the backfill /
  # would-be-generated form (bare column names).
  @configs [
    %{table: "stories", columns: [{"title", "A"}, {"description", "B"}]},
    %{table: "projects", columns: [{"name", "A"}, {"description", "B"}, {"mission", "C"}]},
    %{table: "epics", columns: [{"title", "A"}, {"description", "B"}]}
  ]

  def up do
    for %{table: table, columns: columns} <- @configs do
      # 1. Plain nullable column — metadata-only, no table rewrite.
      execute "ALTER TABLE #{table} ADD COLUMN search_vector tsvector"

      # 2. Self-maintaining trigger (same effect as a generated column, no
      #    rewrite). In a plpgsql assignment the tsvector expression is evaluated
      #    with NO table in scope, so each column MUST be qualified `NEW.<col>`.
      execute """
      CREATE OR REPLACE FUNCTION #{table}_search_vector_update() RETURNS trigger AS $$
      BEGIN
        NEW.search_vector := #{tsvector_expr(columns, "NEW.")};
        RETURN NEW;
      END
      $$ LANGUAGE plpgsql
      """

      execute """
      CREATE TRIGGER #{table}_search_vector_trg
      BEFORE INSERT OR UPDATE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION #{table}_search_vector_update()
      """

      # Ensure column + trigger exist before the raw backfill queries run.
      flush()

      # 3. Batched backfill — bounded UPDATEs, each auto-committing. The UPDATE
      #    evaluates the expression against the row being updated, so columns are
      #    referenced bare (no `NEW.` prefix).
      backfill(table, tsvector_expr(columns, ""))

      # 4. GIN index built CONCURRENTLY so the build does not block writes.
      execute """
      CREATE INDEX CONCURRENTLY IF NOT EXISTS #{table}_search_vector_idx
      ON #{table} USING GIN (search_vector)
      """
    end
  end

  def down do
    for %{table: table} <- Enum.reverse(@configs) do
      execute "DROP INDEX CONCURRENTLY IF EXISTS #{table}_search_vector_idx"
      execute "DROP TRIGGER IF EXISTS #{table}_search_vector_trg ON #{table}"
      execute "DROP FUNCTION IF EXISTS #{table}_search_vector_update()"
      execute "ALTER TABLE #{table} DROP COLUMN IF EXISTS search_vector"
    end
  end

  # Populate `search_vector` for pre-existing rows in bounded batches. Each batch
  # is a self-contained UPDATE that commits before the next (the migration runs
  # outside a transaction), so no long-held lock. New rows inserted during the
  # backfill already have `search_vector` set by the trigger, so the
  # `search_vector IS NULL` predicate converges to zero.
  defp backfill(table, expr) do
    Stream.repeatedly(fn ->
      %{num_rows: num_rows} =
        repo().query!("""
        UPDATE #{table} SET search_vector = #{expr}
        WHERE id IN (
          SELECT id FROM #{table} WHERE search_vector IS NULL LIMIT #{@backfill_batch_size}
        )
        """)

      num_rows
    end)
    |> Enum.take_while(fn num_rows -> num_rows > 0 end)
  end

  # Weighted tsvector expression over `{column, weight}` pairs. `prefix` is
  # `"NEW."` for the trigger body (no table in scope) and `""` for the backfill
  # UPDATE (columns resolve against the updated row).
  defp tsvector_expr(columns, prefix) do
    columns
    |> Enum.map(fn {col, weight} ->
      "setweight(to_tsvector('english', coalesce(#{prefix}#{col}, '')), '#{weight}')"
    end)
    |> Enum.join(" || ")
  end
end
