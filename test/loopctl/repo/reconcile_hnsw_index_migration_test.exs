defmodule Loopctl.Repo.ReconcileHnswIndexMigrationTest do
  @moduledoc """
  US-27.14 / TC-27.14.1 — integration test for the HNSW index-name reconcile.

  Exercises the REAL migration modules (`AddEmbeddingHnswIndex` and
  `ReconcileHnswIndexName`) against the live AdminRepo connection, proving:

    * the OLD migration's fixed `down/0` drops WHICHEVER hnsw index is present
      (by `amname='hnsw'`, not a hard-coded name) — so a rollback against a DB
      where the index lives under a non-migration name (prod's
      `articles_embedding_hnsw_idx`, or any out-of-band name) actually drops it
      instead of silently no-opping; and
    * the reconcile migration is idempotent and renames any non-canonical hnsw
      index up to the canonical `articles_embedding_hnsw_idx`.

  Runs inside the SQL sandbox transaction so the index DDL it performs is
  fully rolled back at the end of each test, leaving the shared test DB's
  canonical index intact for every other test (the index DDL here is
  non-concurrent, so it runs happily inside a transaction). It does NOT touch
  `schema_migrations`; it invokes the migration modules' `up/0` / `down/0`
  directly via `Ecto.Migration.Runner.run/8`.

  Scope of what this exercises: `Runner.run/8` starts the runner Agent and
  calls `perform_operation/3` — it executes the migrations' SQL and detection
  logic, which is what this test validates. It does NOT manage transactions or
  consult `@disable_ddl_transaction` / `@disable_migration_lock`; that logic
  lives one layer up in `Ecto.Migrator.run_maybe_in_transaction/4`, which this
  test deliberately bypasses. Consequently the old `AddEmbeddingHnswIndex`
  migration's `@disable_ddl_transaction true` is NOT honored here: its DDL runs
  on the sandbox connection INSIDE the test transaction (which is exactly what
  makes the test safe and self-cleaning), rather than outside a transaction as
  it would under the real migrator. This test therefore proves the SQL /
  detection behavior, not the disable-ddl-transaction behavior.

  `async: false` because it mutates a shared, table-level index whose name
  other (async) tests assert on — the sandbox isolates the data, but the
  index rename must not race those assertions.
  """
  use ExUnit.Case, async: false

  # Building a real HNSW index (CREATE INDEX ... USING hnsw) over the test corpus
  # legitimately takes ~60-70s on a loaded machine — over ExUnit's 60s default — which
  # intermittently RED-flaked `mix precommit` and the CI Test job. Give the index DDL
  # ample headroom so this is a deterministic pass, not a timing race. (Test-infra only.)
  @moduletag timeout: :timer.minutes(5)

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migration.Runner
  alias Loopctl.AdminRepo

  # Migration files in priv/repo/migrations are not compiled into the app, so
  # load the two we exercise by path (idempotent — guarded against re-loading
  # when the test module is recompiled).
  @migrations_path "priv/repo/migrations"
  unless Code.ensure_loaded?(Loopctl.Repo.Migrations.AddEmbeddingHnswIndex) do
    Code.require_file("#{@migrations_path}/20260410022906_add_embedding_hnsw_index.exs")
  end

  unless Code.ensure_loaded?(Loopctl.Repo.Migrations.ReconcileHnswIndexName) do
    Code.require_file("#{@migrations_path}/20260624120000_reconcile_hnsw_index_name.exs")
  end

  alias Loopctl.Repo.Migrations.AddEmbeddingHnswIndex
  alias Loopctl.Repo.Migrations.ReconcileHnswIndexName

  @canonical "articles_embedding_hnsw_idx"
  @noncanonical "articles_embedding_idx"

  setup do
    pid = Sandbox.start_owner!(AdminRepo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  defp hnsw_index_names do
    AdminRepo.query!("""
    SELECT i.relname
    FROM pg_index x
    JOIN pg_class i ON i.oid = x.indexrelid
    JOIN pg_class t ON t.oid = x.indrelid
    JOIN pg_am    am ON am.oid = i.relam
    WHERE t.relname = 'articles' AND am.amname = 'hnsw'
    """).rows
    |> List.flatten()
  end

  defp run_migration(module, op) do
    Runner.run(AdminRepo, [], 0, module, :forward, op, op, log: false)
  end

  test "down-migration drops the actually-present HNSW index (non-migration name)" do
    # Precondition: a DB where the hnsw index exists under a NON-migration
    # name — i.e. exactly prod's situation. Rename the canonical test index
    # to a foreign name so the only hnsw index is not what the old migration
    # hard-coded.
    AdminRepo.query!("ALTER INDEX #{@canonical} RENAME TO articles_embedding_out_of_band_idx")

    assert hnsw_index_names() == ["articles_embedding_out_of_band_idx"]

    # The FIXED down-step must drop it by amname, not silently no-op on a
    # hard-coded `articles_embedding_idx`.
    run_migration(AddEmbeddingHnswIndex, :down)

    assert hnsw_index_names() == [],
           "down-migration must drop the present hnsw index, not no-op against a foreign name"

    # And the up-step recreates it (under the old migration's name), which the
    # reconcile migration then renames to the canonical name.
    run_migration(AddEmbeddingHnswIndex, :up)
    assert hnsw_index_names() == [@noncanonical]

    run_migration(ReconcileHnswIndexName, :up)
    assert hnsw_index_names() == [@canonical]
  end

  test "old up-step does not create a duplicate hnsw index from the prod drift state (AC-27.14.2)" do
    # Reproduce prod's drift: the single hnsw index lives under the out-of-band
    # name `articles_embedding_hnsw_idx`, NOT the migration's `articles_embedding_idx`.
    assert hnsw_index_names() == [@canonical]

    # The amname-aware up-guard must see the existing hnsw index and SKIP, so
    # no second redundant hnsw index is created. (The old name-based guard
    # `indexname = 'articles_embedding_idx'` would have created a duplicate.)
    run_migration(AddEmbeddingHnswIndex, :up)

    assert hnsw_index_names() == [@canonical],
           "up-step must not create a duplicate hnsw index when one already exists under a different name"
  end

  test "down-step drops ALL hnsw indexes, leaving none orphaned (AC-27.14.2)" do
    # Force the (normally unreachable) two-index state to prove the down-step
    # iterates over every hnsw index rather than dropping only one (LIMIT 1).
    AdminRepo.query!(
      "CREATE INDEX articles_embedding_idx ON articles USING hnsw (embedding vector_cosine_ops)"
    )

    assert Enum.sort(hnsw_index_names()) == Enum.sort([@canonical, @noncanonical])

    run_migration(AddEmbeddingHnswIndex, :down)

    assert hnsw_index_names() == [],
           "down-step must drop every hnsw index, leaving none orphaned"
  end

  test "reconcile migration renames a non-canonical hnsw index to the canonical name" do
    # Simulate a fresh test DB: only the old migration's name is present.
    AdminRepo.query!("ALTER INDEX #{@canonical} RENAME TO #{@noncanonical}")
    assert hnsw_index_names() == [@noncanonical]

    run_migration(ReconcileHnswIndexName, :up)
    assert hnsw_index_names() == [@canonical]
  end

  test "reconcile migration is idempotent — re-running it is a no-op" do
    assert hnsw_index_names() == [@canonical]

    # Already canonical: first run is a no-op...
    run_migration(ReconcileHnswIndexName, :up)
    assert hnsw_index_names() == [@canonical]

    # ...and a second run is also a no-op (the guard short-circuits).
    run_migration(ReconcileHnswIndexName, :up)
    assert hnsw_index_names() == [@canonical]
  end

  test "guard does not treat a non-hnsw object squatting the canonical name as 'already reconciled'" do
    # Failure mode the tightened idempotency guard fixes: a bare
    # `pg_class.relname = 'articles_embedding_hnsw_idx'` check matches ANY
    # relation of that name (table, view, sequence, or an index of another AM)
    # and RETURNs early, silently reporting success while the real hnsw index
    # still sits under a non-canonical name — leaving the very drift this
    # migration exists to remove.
    #
    # Set up exactly that: the real hnsw index lives under the non-canonical
    # name, and an UNRELATED table squats the canonical name. Postgres puts
    # tables and indexes in the same relation namespace, so reconciliation
    # legitimately cannot complete (the RENAME target is occupied). The CORRECT
    # behavior is to surface that conflict by raising — NOT to short-circuit at
    # the guard and report a false success. The old bare-relname guard would
    # have hidden the drift by returning early; the amname='hnsw' guard does
    # not, so the migration proceeds to the RENAME and raises on the collision.
    AdminRepo.query!("ALTER INDEX #{@canonical} RENAME TO #{@noncanonical}")
    AdminRepo.query!("CREATE TABLE #{@canonical} (id int)")

    assert hnsw_index_names() == [@noncanonical]

    assert_raise Postgrex.Error, fn ->
      run_migration(ReconcileHnswIndexName, :up)
    end
  end
end
