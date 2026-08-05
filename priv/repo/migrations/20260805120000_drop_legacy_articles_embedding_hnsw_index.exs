defmodule Loopctl.Repo.Migrations.DropLegacyArticlesEmbeddingHnswIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  require Logger

  alias Loopctl.Repo.HnswIndex

  # GH #578 — retire the PRE-US-41.1 HNSW index on the LEGACY `articles.embedding`
  # column on installs that have cut their reads over to the side table.
  #
  # WHY (measured on prod 2026-08-04, source `pg_stat_user_indexes` +
  # `pg_stat_statements`; dated observation, not a standing fact):
  #   * `articles_embedding_hnsw_idx` (legacy column)          657 MB /    26 scans
  #   * `article_embeddings_hnsw_dim_1536_idx` (live path)     658 MB / 1,695 scans
  # `shared_buffers` is 1536 MB, so the two ~657 MB indexes evict each other. A cold
  # vector search measured 8,044 ms, of which 7,926 ms (98.5%) was `blk_read_time`;
  # the same statement warm was 0 ms. The read path was cut over to the side table
  # (`article_embeddings`) on 2026-07-22, so the legacy index buys nothing on a
  # cut-over install and costs the live index its cache residency.
  #
  # The 26 scans were NOT a stray consumer: they were the boot window GH #588 narrowed,
  # in which the `SystemConfig` cache had not been primed before the Endpoint started
  # and `embedding_side_table_reads` read its in-code default `0` (= legacy column).
  # `Loopctl.SystemConfig.CachePrimer` is now a supervised one-shot child ordered after
  # `AdminRepo` and before `Oban`/`Endpoint` — which closed the ORDERING window, but NOT
  # the PRIME-FAILURE one, deliberately: `CachePrimer.start_link/1` returns `:ignore` on
  # failure rather than aborting boot, and such a node serves the in-code default (= the
  # LEGACY column) until a `SystemConfigRefreshWorker` tick lands ON IT — unbounded on a
  # multi-node deploy, since the per-minute cron enqueues one job per tick cluster-wide
  # (`Loopctl.Telemetry.ScaleMetrics` already documents that residual as UNBOUNDED).
  #
  # This drop changes the COST of that residual window on a CUT-OVER install: before it,
  # a node that missed its prime served slow-but-correct results off this index; after
  # it, the same node seq-scans an unindexed column past the heavy-read statement
  # timeout — a semantic-search OUTAGE on that node (504 `db_statement_timeout`, see
  # below), not a slowdown. That makes `loopctl.system_config.prime_failed.count`
  # (scale metric 25) page-worthy on a cut-over install rather than informational.
  #
  # SCOPE: the INDEX only. `articles.embedding` is still dual-WRITTEN and is read as
  # the backfill/reconciliation source AND as the documented revert target, so
  # dropping the COLUMN is a different, far riskier decision (issue #578 open
  # question 4). Do not extend this migration to the column.
  #
  # `memories` deliberately keeps BOTH of its legacy-column indexes
  # (`memories_embedding_idx`, `memories_live_embedding_hnsw_idx`). That is a
  # documented keep-both decision — the FULL index serves
  # `Memory.recall(include_superseded: true)` and the PARTIAL one serves default live
  # recall (US-38.4 / TC-38.4.3, `test/loopctl/memory/dual_index_recall_test.exs`).
  # Their 0 prod scans reflect prod's read flag, not deadness (#578 open question 3).
  #
  # ---------------------------------------------------------------------------
  # Why the drop is GUARDED BY THE READ FLAG, not unconditional
  # ---------------------------------------------------------------------------
  #
  # `embedding_side_table_reads` defaults to `0` IN CODE, and no migration seeds the
  # row. So on a FRESH self-hosted install — and in the test DB — the shipped read
  # path is still the legacy `articles.embedding` column. An UNCONDITIONAL drop would
  # leave that shipped-default path with no index at all: a seq scan + top-N sort over
  # the whole corpus, which trips `HeavyRead`'s per-read `SET LOCAL statement_timeout`.
  # That CANCEL is a raised `Postgrex.Error` (SQLSTATE 57014) propagating to the
  # `DBErrorBackstop`, which renders `504 db_statement_timeout` — it is NOT
  # `{:error, :heavy_read_overloaded}`, a tuple only the `TenantGate` concurrency shed
  # produces, and it therefore does NOT reach `KnowledgeSearchController`'s labelled
  # keyword degrade (that clause matches the shed tuple only). There is no graceful
  # fall-back on this path today: semantic search returns no results at all. That is the
  # GH #588 failure re-introduced through configuration instead of ordering.
  #
  # So this migration retires the index for the read path an install no longer uses,
  # and leaves it in place for one that still does. The condition is read straight
  # from `system_configs` (NOT `SystemConfig.get_int/2`): the `:persistent_term` cache
  # answers its in-code default on a miss, and a migrator process is exactly where
  # that cache may be cold.
  #
  # An install that flips the flag to 1 AFTER this migration has run keeps the index
  # (a migration does not re-run). That is not silent: `Loopctl.Embeddings.LegacyRetirement`
  # discovers legacy indexes BY COLUMN, so the index reappears in its scan map and its
  # evidence/deadline verdict names it.
  #
  # ---------------------------------------------------------------------------
  # Mechanics
  # ---------------------------------------------------------------------------
  #
  # Explicit `up/0`/`down/0` (not `change/0`) because both directions are raw
  # CONCURRENTLY `execute/1` and the down is differently shaped.
  # `@disable_ddl_transaction` + `@disable_migration_lock` are BOTH mandatory:
  # CONCURRENTLY is illegal inside a transaction block and Ecto's migration advisory
  # lock is itself transaction-scoped. Ecto's `create index(..., concurrently: true)`
  # helper emits no `IF NOT EXISTS`, hence raw `execute/1`.
  #
  # On prod the DROP is run OUT-OF-BAND (`fly ssh console`) ahead of the deploy, so
  # `IF EXISTS` makes this migration a no-op there — that is the intended shape, not
  # an accident.
  #
  # ROLLBACK COST: `down/0` rebuilds a ~657 MB HNSW index. At prod scale that needs
  # `maintenance_work_mem` well above the 64 MB default or the build silently falls
  # back to the slow on-disk path (wiki `753fbf69`). Raise it on the session first.
  #
  # ROLLBACK ORDER: a rollback DELETES this version from `schema_migrations`, so the
  # migration is PENDING again. Flip `embedding_side_table_reads` back to `0` BEFORE the
  # next `Loopctl.Release.migrate()` runs — otherwise that deploy re-executes `up/0`, the
  # guard still reads `1`, and the index just rebuilt at the `maintenance_work_mem` cost
  # above is dropped again. Once the flag is `0`, the pending migration is a no-op.
  # (Note `Loopctl.Release.rollback/1` passes `to: version`, which Ecto treats as
  # INCLUSIVE — it rolls back every migration at or after this one. Once anything newer
  # has shipped, rebuild with an explicit `CREATE INDEX CONCURRENTLY` instead.)

  @index "articles_embedding_hnsw_idx"
  @read_flag_key "embedding_side_table_reads"

  def up do
    if side_table_reads_live?() do
      execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index}")
    else
      # Not a failure: this install still READS the legacy column, so its index stays.
      # Logged rather than silent — an operator reading the migration output should be
      # able to tell "skipped, still the live read path" from "dropped".
      Logger.info(
        "#{inspect(__MODULE__)}: #{@read_flag_key} is not 1 — the legacy " <>
          "articles.embedding column is still the live read path on this install, so " <>
          "#{@index} is KEPT. Re-run this drop after cutting reads over to the side table."
      )
    end
  end

  # Restore the pre-migration state on ANY install, cut over or not, so a rollback is
  # not itself conditional (a `down` that skipped would leave a rolled-back install
  # without the index it is rolling back TO).
  #
  # The defensive DROP handles a leftover from a FAILED `CREATE INDEX CONCURRENTLY`:
  # Postgres leaves an INVALID index behind under the same name, which `IF NOT EXISTS`
  # then treats as present and skips forever (wiki `ed00911b`). It drops ONLY when the
  # index is invalid — an unconditional drop-then-create would destroy and rebuild a
  # perfectly good 657 MB index on every rollback.
  #
  # The validity test is done HERE in Elixir, not in a `DO $$` block, so the drop can be
  # CONCURRENTLY: a DO block IS a transaction and `DROP INDEX CONCURRENTLY` is illegal
  # inside one, which leaves only a plain `DROP INDEX` — and that takes ACCESS EXCLUSIVE
  # on `articles` ITSELF, not just the index. Behind one long-running `SELECT ... FROM
  # articles` the lock request queues, and every subsequent read and write on `articles`
  # (the whole wiki read path, not just vector search) queues behind it. This branch runs
  # on the documented revert path — i.e. during an incident — so that is not affordable.
  def down do
    if invalid_index_leftover?() do
      execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index}")
    end

    # The WITH (m, ef_construction) clause is single-sourced from Loopctl.Repo.HnswIndex
    # so a rebuild can never drift from the params every other HNSW index is built with.
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index}
    ON articles USING hnsw (embedding vector_cosine_ops) #{HnswIndex.with_params_clause()}
    """)
  end

  # A leftover from a FAILED `CREATE INDEX CONCURRENTLY`: present in the catalog under
  # this name and marked NOT valid. Read directly, the same shape as
  # `side_table_reads_live?/0` below.
  defp invalid_index_leftover? do
    %{rows: rows} =
      repo().query!(
        """
        SELECT 1
        FROM pg_class c
        JOIN pg_index i ON i.indexrelid = c.oid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = $1 AND n.nspname = 'public' AND NOT i.indisvalid
        """,
        [@index]
      )

    rows != []
  end

  # The install's OWN cutover state, read from the row rather than the cache. A missing
  # row means the in-code default (`0` = legacy column) — so absent reads as "still the
  # live read path" and the index is kept.
  defp side_table_reads_live? do
    %{rows: rows} =
      repo().query!("SELECT value FROM system_configs WHERE key = $1", [@read_flag_key])

    match?([[1]], rows)
  end
end
