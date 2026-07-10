defmodule Loopctl.ContextRetriever.EntityDefinitionsRollbackTest do
  @moduledoc """
  US-30.1 / AC-30.1.7 / TC-30.1.5 — exercises the DOWN path of the
  `entity_definitions` migration, asserting the reversibility invariant the AC
  pins:

    > The migration creates entity_definitions AND calls
    > enable_rls(:entity_definitions); the down migration cleanly drops it.
    > Migrations run green on a fresh DB and pass the rollback test.

  The forward-migrated state is exercised by the schema/registry tests; this test
  complements them by proving the reverse: after rolling the migration down the
  `entity_definitions` table is gone, its `tenant_isolation` RLS policy is not
  left orphaned, and re-applying `up` restores the forward state (table present,
  RLS policy present again).

  ## How the migration is driven

  The migration files under `priv/repo/migrations` are not compiled into the app,
  so the file is loaded here at runtime and driven with
  `Ecto.Migration.Runner.run/9` DIRECTLY (the same entry point
  `Ecto.Migrator.attempt/7` uses) rather than via `Ecto.Migrator.up/down`. The
  latter runs each migration in a spawned `Task` under its own transaction/lock,
  which cannot check out the single sandbox-owned connection; `Runner.run/9`
  performs the operation in THIS process, so the DDL executes inside the sandbox
  transaction and is rolled back on exit — leaving the real `entity_definitions`
  table (and the suite DB) untouched.

  The migration is a `change/0` migration: up runs `:forward`/`:change` and down
  runs `:backward`/`:change` (reversed commands). `create table` auto-reverses to
  a `DROP TABLE`, and `enable_rls/1` uses the two-arg `Ecto.Migration.execute/2`
  with explicit DISABLE RLS / DROP POLICY / REVOKE down SQL, so the whole
  migration is cleanly reversible.

  ## Isolation

  Runs `async: false` inside a manual sandbox owner so the whole down → assert →
  up sequence lives in one transaction that is rolled back on exit; the
  DROP/CREATE TABLE ACCESS EXCLUSIVE locks are released on rollback and never
  escape this test.

  `no orphaned enum type` is structurally guaranteed — `backing_source` is stored
  as a `:string` column (`Ecto.Enum` values live in app code, not a Postgres enum
  type), so the migration creates no enum type to drop or assert-absent.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migration.Runner
  alias Loopctl.AdminRepo

  @version 20_260_711_120_000

  @migrations_dir Path.join([File.cwd!(), "priv", "repo", "migrations"])
  migration_file = Path.wildcard(Path.join(@migrations_dir, "#{@version}_*.exs")) |> hd()
  Code.require_file(migration_file)

  alias Loopctl.Repo.Migrations.CreateEntityDefinitions

  setup do
    pid = Sandbox.start_owner!(AdminRepo)
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  # Drive the change/0 migration up/down in THIS process, mirroring
  # Ecto.Migrator.attempt/7: :forward for up, :backward (reversed commands) for
  # down.
  defp migrate(:up) do
    Runner.run(
      AdminRepo,
      AdminRepo.config(),
      @version,
      CreateEntityDefinitions,
      :forward,
      :change,
      :up,
      log: false
    )
  end

  defp migrate(:down) do
    Runner.run(
      AdminRepo,
      AdminRepo.config(),
      @version,
      CreateEntityDefinitions,
      :backward,
      :change,
      :down,
      log: false
    )
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

  test "down drops entity_definitions and its RLS policy with no orphans; up restores them" do
    # Baseline: the forward-migrated table exists with its tenant_isolation policy.
    assert relation_exists?("entity_definitions")
    assert policy_present?("entity_definitions")

    # Roll the migration back.
    migrate(:down)

    # The table (and its indexes, which drop with the table) is gone, and no
    # orphaned tenant_isolation policy remains.
    refute relation_exists?("entity_definitions")
    refute policy_present?("entity_definitions")

    # Re-applying up restores the full forward-migrated state.
    migrate(:up)

    assert relation_exists?("entity_definitions")
    assert policy_present?("entity_definitions")
  end
end
