defmodule Loopctl.AsyncDdlGuardTest do
  @moduledoc """
  No `async: true` test module may issue table-locking DDL.

  Inside the Ecto sandbox a test is one transaction, so a `CREATE TRIGGER`,
  `ALTER TABLE`, `DROP INDEX`, `LOCK TABLE` and the like hold their SHARE ROW EXCLUSIVE or
  ACCESS EXCLUSIVE lock until the test ENDS. Every concurrent async test that touches the
  same table waits out the statement timeout and fails 57014 `query_canceled` — a red that
  never reproduces alone. It has shipped three times (KB 493d2020; on 2026-09-29 a
  `CREATE TRIGGER` on `tenant_llm_settings`, an `ALTER TABLE ... DISABLE TRIGGER` on the
  embedding side tables and a `DROP INDEX` on `rate_limit_counters`, all fixed in #939).

  The lock-free alternatives: `SET LOCAL session_replication_role = replica` to skip a
  trigger, a transaction-local setting to force an error, or `async: false` where the DDL
  itself is the point. The scan reads what each `query`/`query!` call is handed, so prose
  describing DDL in a comment or moduledoc is not a hit.
  """

  use ExUnit.Case, async: true

  @ddl ~r/\b(CREATE\s+(OR\s+REPLACE\s+)?(TRIGGER|INDEX|UNIQUE\s+INDEX|TABLE|FUNCTION)|ALTER\s+TABLE|DROP\s+(INDEX|TRIGGER|TABLE|FUNCTION)|LOCK\s+TABLE|TRUNCATE|REINDEX|VACUUM\s+FULL)\b/i

  # DDL only on a table, schema or temp table the test CREATES ITSELF: no other test can
  # hold or wait on that lock, so it cannot cause the flake. A new entry needs the same claim
  # to be true of every DDL call in the file.
  @private_ddl ~w(
    test/loopctl/async_ddl_guard_test.exs
    test/loopctl/repo/hnsw_index_params_test.exs
    test/loopctl/repo/reconcile_hnsw_index_migration_test.exs
    test/loopctl/search/regconfig_test.exs
    test/loopctl/workers/channel_post_rescan_worker_test.exs
  )

  # Each `query(`/`query!(` call and the text it is handed, up to its closing paren or a
  # bounded window when the argument spans lines.
  @call ~r/\bquery!?\(([^)]{0,400})/s

  test "no async: true test module runs table-locking DDL" do
    offenders =
      "test/**/*_test.exs"
      |> Path.wildcard()
      |> Enum.reject(&(&1 in @private_ddl))
      |> Enum.filter(&(async?(&1) and issues_ddl?(&1)))
      |> Enum.sort()

    assert offenders == [],
           "async: true modules issuing DDL (make them lock-free or async: false): " <>
             inspect(offenders)
  end

  test "the scan sees a DDL call when one is there" do
    assert Regex.match?(@ddl, ~s|"DROP INDEX rate_limit_counters_bucket_window_start_index"|)

    assert [[argument]] =
             Regex.scan(@call, ~s|AdminRepo.query!("ALTER TABLE t DISABLE TRIGGER x")|,
               capture: :all_but_first
             )

    assert Regex.match?(@ddl, argument)
    refute Regex.match?(@ddl, ~s|"SET LOCAL session_replication_role = replica"|)
  end

  defp issues_ddl?(path) do
    @call
    |> Regex.scan(File.read!(path), capture: :all_but_first)
    |> Enum.any?(fn [argument] -> Regex.match?(@ddl, argument) end)
  end

  defp async?(path),
    do: path |> File.read!() |> String.match?(~r/^\s*use\s+[\w.]+Case,\s*async:\s*true/m)
end
