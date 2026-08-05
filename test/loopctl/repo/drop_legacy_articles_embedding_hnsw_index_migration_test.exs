defmodule Loopctl.Repo.DropLegacyArticlesEmbeddingHnswIndexMigrationTest do
  @moduledoc """
  GH #578 — `DropLegacyArticlesEmbeddingHnswIndex` retires the pre-US-41.1 HNSW index
  on the LEGACY `articles.embedding` column (`articles_embedding_hnsw_idx`, 657 MB /
  26 scans on prod 2026-08-04) on installs whose reads have been cut over to the
  `article_embeddings` side table — and DELIBERATELY keeps it on installs that have
  not, because `embedding_side_table_reads` defaults to `0` (= the legacy column) in
  code and no migration seeds the row.

  That conditional is the load-bearing behaviour here, so it is tested in BOTH
  directions: an unconditional drop would leave the SHIPPED-DEFAULT read path with no
  index at all — a seq scan + top-N sort over the whole corpus, which under
  `HeavyRead`'s per-read `SET LOCAL statement_timeout` surfaces as
  `{:error, :heavy_read_overloaded}`.

  ## How the migration is driven — CONCURRENTLY, so OUTSIDE the sandbox

  `up/0` drops and `down/0` rebuilds with `DROP`/`CREATE INDEX CONCURRENTLY`, so the
  deploy takes no ACCESS EXCLUSIVE lock on `articles`. `CONCURRENTLY` is illegal
  inside a transaction block and the Ecto SQL sandbox wraps every test in one, so the
  shipped `up/0`/`down/0` CANNOT be driven inside the sandbox transaction.

  Instead they run verbatim through `Sandbox.unboxed_run/2`, which checks out a REAL
  (non-sandboxed) connection where statements auto-commit — the same committed
  connection the production migrator uses. `Ecto.Migration.Runner.run/8` (the entry
  point `Ecto.Migrator.attempt/7` uses for an explicit `up/0`/`down/0`) opens no
  transaction of its own; the DDL-transaction wrapper lives in `Ecto.Migrator`, which
  `@disable_ddl_transaction true` disables in production. So the SHIPPED code runs
  here exactly as it runs at deploy, and a defect edited into the migration file WILL
  fail these tests.

  Because these tests commit real index changes to the SHARED `articles` catalog — and
  briefly commit a `system_configs` row — an `on_exit` restores the canonical state
  after every test.

  ## The read flag is read from the ROW, never through `SystemConfig`

  The migration issues `SELECT value FROM system_configs WHERE key = ...` directly.
  That matters twice: a migrator process is exactly where the `:persistent_term` cache
  may be cold (it answers the in-code default `0` on a miss — GH #588), and it means
  these tests can commit and remove the row WITHOUT touching the VM-global cache that
  every other test's read path resolves through. Nothing here writes
  `Loopctl.SystemConfig`, and nothing here stubs `MockEmbeddingReadPath`.
  """
  # async: false (the documented global-state-coupling exception to async-everywhere):
  # these tests commit real CREATE/DROP INDEX against the SHARED `articles` catalog and
  # a real row into the global `system_configs` table via unboxed_run, bypassing the
  # per-test sandbox rollback. ExUnit's sync phase serializes that committed mutation
  # and keeps it off the timeline of the async siblings that read `articles.embedding`.
  use Loopctl.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migration.Runner
  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings
  alias Loopctl.Repo.HnswIndex

  @migration_version 20_260_805_120_000
  @migration_file Path.wildcard(
                    Path.join([
                      File.cwd!(),
                      "priv",
                      "repo",
                      "migrations",
                      "#{@migration_version}_*.exs"
                    ])
                  )
                  |> hd()

  Code.require_file(@migration_file)

  alias Loopctl.Repo.Migrations.DropLegacyArticlesEmbeddingHnswIndex

  @index "articles_embedding_hnsw_idx"

  # Restore the canonical state after every test. The applied-migration baseline in the
  # test DB is: read flag ABSENT (so the legacy column is the live read path) and the
  # legacy index PRESENT. Both directions of every test below can leave either off.
  setup do
    on_exit(fn ->
      Sandbox.unboxed_run(AdminRepo, fn ->
        AdminRepo.query!("DELETE FROM system_configs WHERE key = $1", [
          Embeddings.read_flag_key()
        ])

        AdminRepo.query!("""
        CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index}
        ON articles USING hnsw (embedding vector_cosine_ops) #{HnswIndex.with_params_clause()}
        """)
      end)
    end)

    :ok
  end

  defp with_unboxed(fun), do: Sandbox.unboxed_run(AdminRepo, fun)

  # Drive the real migration's up/0 in THIS process (mirrors Ecto.Migrator.attempt/7 for
  # an explicit up/0 running :forward). MUST be called inside with_unboxed/1 so the
  # CONCURRENTLY DDL runs on a committed, non-transactional connection.
  defp run_migration_up, do: run_migration(:up)
  defp run_migration_down, do: run_migration(:down)

  defp run_migration(direction) do
    Runner.run(
      AdminRepo,
      AdminRepo.config(),
      @migration_version,
      DropLegacyArticlesEmbeddingHnswIndex,
      :forward,
      direction,
      direction,
      log: false
    )
  end

  # Commit the cutover flag exactly as an operator's `SystemConfig.put/2` would leave the
  # ROW — without touching the `:persistent_term` cache (see the moduledoc).
  defp set_read_flag(value) do
    AdminRepo.query!(
      """
      INSERT INTO system_configs (id, key, value, description, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, $2, 'test', now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC')
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
      """,
      [Embeddings.read_flag_key(), value]
    )
  end

  defp clear_read_flag do
    AdminRepo.query!("DELETE FROM system_configs WHERE key = $1", [Embeddings.read_flag_key()])
  end

  defp index_present?(name) do
    %{rows: rows} =
      AdminRepo.query!(
        "SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'articles' AND indexname = $1",
        [name]
      )

    rows != []
  end

  # `pg_indexes` also lists INVALID indexes (wiki 753fbf69), so presence alone is not
  # health — the rebuilt index must be usable.
  defp index_valid?(name) do
    %{rows: rows} =
      AdminRepo.query!(
        """
        SELECT i.indisvalid
        FROM pg_class c
        JOIN pg_index i ON i.indexrelid = c.oid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = $1 AND n.nspname = 'public'
        """,
        [name]
      )

    rows == [[true]]
  end

  describe "up/0 on a cut-over install (embedding_side_table_reads = 1)" do
    test "drops the legacy articles HNSW index" do
      with_unboxed(fn ->
        set_read_flag(1)
        assert index_present?(@index)

        assert :ok = run_migration_up()

        refute index_present?(@index)
      end)
    end

    test "is idempotent-safe when the index is already absent (DROP ... IF EXISTS)" do
      with_unboxed(fn ->
        set_read_flag(1)

        assert :ok = run_migration_up()
        refute index_present?(@index)

        # Second run: nothing to drop, must still succeed rather than raise.
        assert :ok = run_migration_up()
        refute index_present?(@index)
      end)
    end

    test "leaves the LIVE side-table index — and the legacy COLUMN — untouched" do
      with_unboxed(fn ->
        set_read_flag(1)
        assert :ok = run_migration_up()

        # The index this retirement exists to protect (it lost cache residency to the
        # legacy one) must still be present AND valid.
        live = HnswIndex.dimension_index_name("article_embeddings", 1536)
        assert index_valid?(live)

        # #578 open question 4 / scope: the COLUMN is still dual-written and is both the
        # backfill source and the documented revert target. Dropping it is a separate,
        # far riskier decision that this migration must never make.
        %{rows: rows} =
          AdminRepo.query!("""
          SELECT 1 FROM pg_attribute a
          JOIN pg_class c ON c.oid = a.attrelid
          WHERE c.relname = 'articles' AND a.attname = 'embedding' AND NOT a.attisdropped
          """)

        assert rows == [[1]]
      end)
    end
  end

  describe "up/0 on an install that still reads the legacy column" do
    # This is the guard that keeps GH #588 closed. `embedding_side_table_reads` defaults
    # to 0 IN CODE and no migration seeds the row, so a fresh self-hosted install (and
    # the test DB) still READS `articles.embedding`. Dropping its index there would make
    # the shipped-default read path a full seq scan + top-N sort.
    test "KEEPS the index when the flag row is absent (the shipped default)" do
      with_unboxed(fn ->
        clear_read_flag()
        assert index_present?(@index)

        assert :ok = run_migration_up()

        assert index_present?(@index)
        assert index_valid?(@index)
      end)
    end

    test "KEEPS the index when the flag row is explicitly 0 (an operator revert)" do
      with_unboxed(fn ->
        set_read_flag(0)

        assert :ok = run_migration_up()

        assert index_present?(@index)
        assert index_valid?(@index)
      end)
    end
  end

  describe "down/0" do
    test "rebuilds the legacy index, valid, regardless of the read flag" do
      with_unboxed(fn ->
        set_read_flag(1)
        assert :ok = run_migration_up()
        refute index_present?(@index)

        # down/0 is deliberately UNCONDITIONAL: a rollback that skipped on a cut-over
        # install would leave it without the index it is rolling back TO.
        assert :ok = run_migration_down()

        assert index_valid?(@index)
      end)
    end

    test "is idempotent-safe when a VALID index is already present, and does not rebuild it" do
      with_unboxed(fn ->
        clear_read_flag()
        assert index_valid?(@index)

        # The relfilenode identifies the physical index file. An unconditional
        # drop-then-create would destroy and rebuild a perfectly good 657 MB index on
        # every rollback; the defensive DROP fires ONLY for an INVALID leftover, so the
        # file must be the SAME one afterwards.
        before = relfilenode(@index)

        assert :ok = run_migration_down()

        assert index_valid?(@index)
        assert relfilenode(@index) == before
      end)
    end

    # Wiki ed00911b: a FAILED `CREATE INDEX CONCURRENTLY` leaves an INVALID index behind
    # under the same name, which `CREATE INDEX ... IF NOT EXISTS` then treats as present
    # and skips FOREVER — a permanently unusable index that every `pg_indexes` name check
    # reports as fine. down/0 must clear that leftover before rebuilding.
    test "clears an INVALID leftover and rebuilds a valid index" do
      with_unboxed(fn ->
        clear_read_flag()

        AdminRepo.query!("DROP INDEX CONCURRENTLY IF EXISTS #{@index}")

        # Forge the exact leftover a failed CONCURRENTLY build produces: present in the
        # catalog, marked NOT valid.
        AdminRepo.query!("""
        CREATE INDEX #{@index}
        ON articles USING hnsw (embedding vector_cosine_ops) #{HnswIndex.with_params_clause()}
        """)

        AdminRepo.query!(
          "UPDATE pg_index SET indisvalid = false WHERE indexrelid = $1::text::regclass",
          [@index]
        )

        refute index_valid?(@index)

        assert :ok = run_migration_down()

        assert index_valid?(@index)
      end)
    end
  end

  defp relfilenode(name) do
    %{rows: [[node]]} =
      AdminRepo.query!("SELECT relfilenode FROM pg_class WHERE relname = $1", [name])

    node
  end
end
