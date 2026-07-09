defmodule Loopctl.Repo.MemoryStoresRollbackTest do
  @moduledoc """
  US-28.1 / AC-28.1.7 — exercises the DOWN path of the two memory-store
  migrations, asserting the rollback invariant the AC pins:

    > the down migrations drop both tables, the HNSW index, and the btree
    > indexes with no orphaned index or enum type.

  The forward-migrated catalog state is asserted by
  `Loopctl.Repo.MemoryStoresMigrationTest`; this test complements it by proving
  the reverse: after rolling both migrations down, NEITHER table exists, the
  HNSW index is gone (dropped with its table), and no `tenant_isolation` RLS
  policy is left orphaned — then re-applying `up` restores the forward state.

  ## How the migrations are driven

  The migration files under `priv/repo/migrations` are not compiled into the app,
  so they are loaded here at runtime. They are then driven with
  `Ecto.Migration.Runner.run/9` DIRECTLY (the same entry point
  `Ecto.Migrator.attempt/7` uses) rather than via `Ecto.Migrator.up/down`. The
  latter runs each migration in a spawned `Task` under its own transaction/lock,
  which cannot check out the single sandbox-owned connection; `Runner.run/9`
  performs the operation in THIS process, so the DDL executes inside the sandbox
  transaction and is rolled back on exit — leaving the real `memories` /
  `session_memories` tables (and the suite DB) untouched.

  ## Isolation

  Runs `async: false` inside a manual sandbox owner so the whole down → assert →
  up sequence lives in one transaction that is rolled back on exit; the
  DROP/CREATE TABLE ACCESS EXCLUSIVE locks are released on rollback and never
  escape this test. `async: false` keeps the sync module from overlapping the
  async memory tests.

  The `no orphaned enum type` clause of the AC is structurally guaranteed — both
  Ecto.Enum columns (`role`, `source`) are stored as `:string` and the migration
  creates no Postgres enum type — so there is nothing to drop or assert-absent.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migration.Runner
  alias Loopctl.AdminRepo

  @create_version 20_260_709_000_000
  @hnsw_version 20_260_709_000_100

  @migrations_dir Path.join([File.cwd!(), "priv", "repo", "migrations"])
  create_file = Path.wildcard(Path.join(@migrations_dir, "#{@create_version}_*.exs")) |> hd()
  hnsw_file = Path.wildcard(Path.join(@migrations_dir, "#{@hnsw_version}_*.exs")) |> hd()
  Code.require_file(create_file)
  Code.require_file(hnsw_file)

  alias Loopctl.Repo.Migrations.AddMemoriesEmbeddingHnswIndex
  alias Loopctl.Repo.Migrations.CreateMemoryStores

  setup do
    pid = Sandbox.start_owner!(AdminRepo)
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  # Drive a migration up/down in THIS process, mirroring Ecto.Migrator.attempt/7:
  # an explicit up/0 or down/0 runs :forward; a change/0 migration runs :forward
  # for up and :backward (reversed commands) for down.
  defp migrate(module, version, :up) do
    if function_exported?(module, :up, 0) do
      Runner.run(AdminRepo, AdminRepo.config(), version, module, :forward, :up, :up, log: false)
    else
      Runner.run(AdminRepo, AdminRepo.config(), version, module, :forward, :change, :up,
        log: false
      )
    end
  end

  defp migrate(module, version, :down) do
    if function_exported?(module, :down, 0) do
      Runner.run(AdminRepo, AdminRepo.config(), version, module, :forward, :down, :down,
        log: false
      )
    else
      Runner.run(AdminRepo, AdminRepo.config(), version, module, :backward, :change, :down,
        log: false
      )
    end
  end

  defp relation_exists?(name) do
    %{rows: [[exists]]} =
      AdminRepo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE c.relname = $1 AND n.nspname = 'public'
        )
        """,
        [name]
      )

    exists
  end

  defp policy_present?(table) do
    %{rows: [[count]]} =
      AdminRepo.query!(
        "SELECT count(*) FROM pg_policies WHERE tablename = $1 AND policyname = 'tenant_isolation'",
        [table]
      )

    count > 0
  end

  # Count of hnsw-access-method indexes on `table` (0 once the table is dropped).
  defp hnsw_count(table) do
    %{rows: [[count]]} =
      AdminRepo.query!(
        """
        SELECT count(*)
        FROM pg_index x
        JOIN pg_class i ON i.oid = x.indexrelid
        JOIN pg_class t ON t.oid = x.indrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_am am ON am.oid = i.relam
        WHERE t.relname = $1 AND n.nspname = 'public' AND am.amname = 'hnsw'
        """,
        [table]
      )

    count
  end

  test "down drops both tables, the HNSW + btree indexes, and the RLS policy with no orphans; up restores them" do
    # Baseline: the forward-migrated state.
    assert relation_exists?("memories")
    assert relation_exists?("session_memories")
    assert hnsw_count("memories") == 1
    assert policy_present?("memories")
    assert policy_present?("session_memories")

    # Roll both migrations back, newest first.
    migrate(AddMemoriesEmbeddingHnswIndex, @hnsw_version, :down)
    migrate(CreateMemoryStores, @create_version, :down)

    # Both tables (and their btree indexes, which drop with the table) are gone.
    refute relation_exists?("memories")
    refute relation_exists?("session_memories")

    # No orphaned HNSW index and no orphaned tenant_isolation policy.
    assert hnsw_count("memories") == 0
    refute policy_present?("memories")
    refute policy_present?("session_memories")

    # Re-applying up restores the forward-migrated state.
    migrate(CreateMemoryStores, @create_version, :up)
    migrate(AddMemoriesEmbeddingHnswIndex, @hnsw_version, :up)

    assert relation_exists?("memories")
    assert relation_exists?("session_memories")
    assert hnsw_count("memories") == 1
    assert policy_present?("memories")
    assert policy_present?("session_memories")
  end
end
