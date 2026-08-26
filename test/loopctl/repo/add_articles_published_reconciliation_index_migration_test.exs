defmodule Loopctl.Repo.AddArticlesPublishedReconciliationIndexMigrationTest do
  @moduledoc """
  `AddArticlesPublishedReconciliationIndex` builds the partial index that keeps the hourly
  embedding reconciler off the `articles` heap, and it carries a SHAPE guard: `IF NOT EXISTS`
  matches on NAME only, so a same-named index with a different predicate would be kept and
  the planner could not prove the query's predicate from it — the whole measured win lost,
  silently, with the migration reporting success.

  The guard's `@shape` regex is matched against `pg_get_indexdef` output, which the SERVER
  renders. Nothing in the migration binds those two, so these tests do: one drives the
  shipped `up/0` against a deliberately mis-trimmed catalog entry (it must be replaced), the
  other drives it against the canonical one (it must be LEFT ALONE — a regex that stopped
  matching the deparser would otherwise rebuild a 4.6 MB index on every deploy).

  `CREATE/DROP INDEX CONCURRENTLY` is illegal inside a transaction, so the shipped `up/0`
  runs through `Sandbox.unboxed_run/2` on a real committed connection — the same shape the
  production migrator uses, exercising the shipped code verbatim.
  """
  # async: false (the documented global-state exception): these commit real catalog changes
  # to the SHARED articles table, so they run in ExUnit's sync phase.
  use Loopctl.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migration.Runner
  alias Loopctl.AdminRepo

  @index "articles_tenant_embeddable_inserted_id_idx"
  @migration_version 20_260_825_130_000
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

  alias Loopctl.Repo.Migrations.AddArticlesPublishedReconciliationIndex

  # Restore the canonical index after every test, whatever the test left behind.
  setup do
    on_exit(fn -> Sandbox.unboxed_run(AdminRepo, &run_up/0) end)
    :ok
  end

  defp run_up do
    Runner.run(
      AdminRepo,
      AdminRepo.config(),
      @migration_version,
      AddArticlesPublishedReconciliationIndex,
      :forward,
      :up,
      :up,
      log: false
    )
  end

  # {oid, indexdef} of the live index, or nil when absent.
  defp catalog do
    sql = """
    SELECT c.oid, pg_get_indexdef(c.oid)
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relname = $1 AND c.relkind = 'i' AND n.nspname = 'public'
    """

    case AdminRepo.query!(sql, [@index]).rows do
      [[oid, def]] -> {oid, def}
      [] -> nil
    end
  end

  test "up/0 replaces a same-named index whose trim set cannot serve the query" do
    Sandbox.unboxed_run(AdminRepo, fn ->
      AdminRepo.query!("DROP INDEX CONCURRENTLY IF EXISTS #{@index}")

      AdminRepo.query!("""
      CREATE INDEX CONCURRENTLY #{@index} ON articles (tenant_id, inserted_at, id)
        WHERE status = 'published' AND body IS NOT NULL AND length(btrim(body, ' ')) > 0
      """)

      assert :ok = run_up()

      {_oid, indexdef} = catalog()
      assert indexdef =~ "btrim(body, ' \t\r\n'"
    end)
  end

  test "up/0 leaves the canonical index in place rather than rebuilding it" do
    Sandbox.unboxed_run(AdminRepo, fn ->
      assert :ok = run_up()
      {oid, _def} = catalog()

      assert :ok = run_up()

      assert {^oid, _} = catalog()
    end)
  end
end
