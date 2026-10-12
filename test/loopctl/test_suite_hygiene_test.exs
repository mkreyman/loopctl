defmodule Loopctl.TestSuiteHygieneTest do
  @moduledoc """
  US-46.6: the suite stays concurrent. No test module runs sync without a stated
  reason, no test steers the code by writing global state, and no async test takes
  a DDL lock on a table other tests use.

  Mark, 2026-10-07: "refactor all code that is trying to manipulate global state
  instead of passing that input as a param -- what's called dependency injection."
  Epic 46 converted the modules that ran sync only because the code read shared
  state; this guard is what keeps them converted. Ported from home_care_billing's
  `TestSuiteHygieneTest`.

  A module whose SUBJECT is the shared thing (CLAUDE.md, Test Conventions rule 1)
  goes in `@sync_allowed` with its reason; the module's own moduledoc says the same
  at greater length.
  """
  use ExUnit.Case, async: true

  @race "committed transactions racing on independent `sandbox: false` connections: the " <>
          "sandbox puts every allowed process on one connection, which serialises the race itself"
  @second_connection "a lock or write held by a SECOND connection is the subject, so its rows " <>
                       "are committed for both connections to see"
  @trigger_fault "injects its fault with a trigger on a shared table; that DDL lock would " <>
                   "stall every concurrent test writing the table until the test ended"
  @audit_chain_fault "installs a refusing trigger on the shared `audit_chain` table: the " <>
                       "broken chain is the subject and nothing in the app can produce one"
  @migration "runs a shipped migration's DDL against a shared table, the migration being the subject"
  @scale "commits a seeded corpus and asserts on the planner over it, and planner statistics " <>
           "are database-wide; excluded from the default suite by its scale tag"
  @committed_tenant "the API key resolves on `AdminRepo` while the executor reads on `Repo`, two " <>
                      "connections that see only COMMITTED rows; excluded by its :e2e tag"

  @sync_allowed %{
    "test/e2e/context_retriever_journey_test.exs" => @committed_tenant,
    "test/e2e/context_retriever_security_test.exs" => @committed_tenant,
    "test/loopctl/admin_repo_topology_test.exs" =>
      "an AdminRepo write committing apart from a failed Repo transaction is the subject: " <>
        "two connections over committed rows",
    "test/loopctl/config_test_exs_partition_wiring_test.exs" =>
      "the subject is config/test.exs's own read of the OS environment at load time",
    "test/loopctl/context_retriever/entity_definitions_rollback_test.exs" => @migration,
    "test/loopctl/context_retriever/executor_stale_column_test.exs" =>
      "drops `stories.sort_key`: a real stale schema is the subject, and the DDL lock on " <>
        "`stories` would block every concurrent test",
    "test/loopctl/coordination_claim_race_test.exs" => @race,
    "test/loopctl/delivery/merge_precondition_lock_test.exs" => @second_connection,
    "test/loopctl/delivery/placement_fault_test.exs" =>
      @trigger_fault <> "; the sweep test is about committed rows by definition",
    "test/loopctl/delivery/session_end_release_fault_test.exs" =>
      "each subject needs a second connection or a trigger on a shared table",
    "test/loopctl/delivery/stages_lock_test.exs" => @race,
    "test/loopctl/delivery/triage_dispatcher_fault_test.exs" => @trigger_fault,
    "test/loopctl/delivery/triage_trigger_lock_test.exs" => @second_connection,
    "test/loopctl/embeddings/hnsw_dead_entry_recall_test.exs" =>
      "poisons and VACUUMs the shared HNSW graph: every concurrent insert enters the same " <>
        "graph, so neither state would be this test's alone",
    "test/loopctl/intake_escalation_concurrency_test.exs" => @race,
    "test/loopctl/knowledge/by_source_change_feed_plan_scale_test.exs" => @scale,
    "test/loopctl/knowledge/cosine_lint_vs_scale_gate_scale_test.exs" => @scale,
    "test/loopctl/knowledge/distant_pairs_novelty_scale_test.exs" => @scale,
    "test/loopctl/knowledge/embedding_dimension_plan_scale_test.exs" => @scale,
    "test/loopctl/knowledge/keyset_plan_scale_test.exs" => @scale,
    "test/loopctl/knowledge/plan_assertions_scale_test.exs" => @scale,
    "test/loopctl/knowledge/remediation_matrix_scale_test.exs" => @scale,
    "test/loopctl/knowledge/scale_calibration_mismatch_scale_test.exs" => @scale,
    "test/loopctl/knowledge/scale_seed_nightly_test.exs" => @scale,
    "test/loopctl/knowledge/scale_seed_test.exs" => @scale,
    "test/loopctl/knowledge/streaming_export_scale_test.exs" => @scale,
    "test/loopctl/knowledge/topk_endpoints_scale_test.exs" => @scale,
    "test/loopctl/knowledge/vector_endpoint_e2e_latency_scale_test.exs" => @scale,
    "test/loopctl/knowledge/vector_search_scale_test.exs" => @scale,
    "test/loopctl/knowledge/vector_search_under_fill_scale_test.exs" => @scale,
    "test/loopctl/memory/scale_recall_test.exs" => @scale,
    "test/loopctl/migrations/fresh_db_embedding_guard_test.exs" =>
      "takes an ACCESS EXCLUSIVE DDL lock on `articles`, the guarded migration being the subject",
    "test/loopctl/pgbouncer_startup_params_test.exs" =>
      "connects through a real pgbouncer outside the sandbox; excluded by its :pgbouncer tag",
    "test/loopctl/progress/claim_lock_test.exs" => @race,
    "test/loopctl/rate_limiter/postgres_concurrency_test.exs" => @race,
    "test/loopctl/repo/add_articles_published_reconciliation_index_migration_test.exs" =>
      @migration,
    "test/loopctl/repo/drop_legacy_articles_embedding_hnsw_index_migration_test.exs" =>
      @migration,
    "test/loopctl/repo/drop_redundant_channel_posts_recent_idx_migration_test.exs" => @migration,
    "test/loopctl/repo/memory_stores_rollback_test.exs" => @migration,
    "test/loopctl/repo/runner_agent_backfill_migration_test.exs" => @migration,
    "test/loopctl/repo/triage_dispatch_backfill_migration_test.exs" => @migration,
    "test/loopctl/runners/capacity_concurrency_test.exs" =>
      "how Postgres arbitrates concurrent slot reservations is the subject: " <> @race,
    "test/loopctl/tenants/enrollment_lock_test.exs" => @race,
    "test/loopctl/test_lock_guard_test.exs" =>
      "takes DDL locks deliberately, on a probe table it commits, to test the guard that " <>
        "refuses them in async tests",
    "test/loopctl/threads/review_dispatch_race_test.exs" => @race,
    "test/loopctl/threads/thread_reviews_rollback_test.exs" => @migration,
    "test/loopctl/token_usage/correction_lock_test.exs" => @race,
    "test/loopctl/workers/audit_partition_worker_test.exs" =>
      "creates and drops partitions of the shared `audit_log` tree: catalog DDL every " <>
        "audit write queues behind",
    "test/loopctl/workers/revoke_expired_dispatches_plan_scale_test.exs" => @scale,
    "test/loopctl/workers/triage_trigger_worker_lock_test.exs" => @second_connection,
    "test/loopctl/workers/verification_runner_worker_lock_test.exs" => @second_connection,
    "test/loopctl_web/controllers/story_stage_report_broken_chain_test.exs" => @audit_chain_fault,
    "test/loopctl_web/runner_channel_lock_test.exs" => @second_connection,
    "test/loopctl_web/runner_channel_thread_broken_chain_test.exs" => @audit_chain_fault
  }

  # Writes to state every test process shares, checked in every file that runs
  # beside other tests (sync-allowed modules run alone). test_helper.exs runs once,
  # before any test: it raises Logger levels (CLAUDE.md's one sanctioned place) and
  # creates the story-number counter. This file and the scale-module Mox guard name
  # the patterns as their own controls. Erasing a persistent term is not
  # matched: clearing a key a test's own setup made unique is cleanup.
  @global_writes ~r/
    Application\.(put_env|delete_env|put_all_env)\( |
    :application\.(set_env|unset_env)\( |
    System\.(put_env|delete_env)\( |
    :os\.(putenv|unsetenv)\( |
    Mix\.shell\((?!\)) |
    Logger\.(configure|configure_backend|add_backend|remove_backend|add_handlers|
      add_translator|remove_translator|
      put_module_level|delete_module_level|put_application_level|delete_application_level|
      put_all_module_levels|delete_all_module_levels)\( |
    :logger\.(set_primary_config|update_primary_config|set_handler_config|update_handler_config|
      add_handler|remove_handler|add_primary_filter|remove_primary_filter|
      add_handler_filter|remove_handler_filter|update_formatter_config|
      set_proxy_config|update_proxy_config|
      set_module_level|unset_module_level|set_application_level|unset_application_level)\( |
    :persistent_term\.put\( |
    :erlang\.system_flag\( |
    set_mox_global
  /x
  @self_path "test/loopctl/test_suite_hygiene_test.exs"
  @global_write_allowed [
    @self_path,
    "test/test_helper.exs",
    "test/loopctl/config_embedding_read_path_test.exs"
  ]

  defp test_files, do: Path.wildcard("test/**/*_test.exs")

  defp code_lines(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
  end

  # Read from the parsed file, not its lines, so a `use` that `mix format`
  # wraps across lines is judged by its options all the same.
  defp sync?(path), do: path |> File.read!() |> source_sync?()

  defp source_sync?(source) do
    {_ast, sync?} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk(false, fn
        {:use, _, [{:__aliases__, _, parts} | opts]} = node, acc ->
          {node, acc or (case_template?(parts) and not async?(opts))}

        node, acc ->
          {node, acc}
      end)

    sync?
  end

  defp case_template?(parts),
    do: parts |> List.last() |> Atom.to_string() |> String.ends_with?("Case")

  defp async?([opts]) when is_list(opts), do: Keyword.get(opts, :async) == true
  defp async?(_no_opts), do: false

  test "every sync test module states why it cannot be async" do
    files = test_files()
    assert length(files) > 500

    sync = files |> Enum.filter(&sync?/1) |> Enum.sort()
    unlisted = sync -- Map.keys(@sync_allowed)

    assert unlisted == [],
           "these run sync (async: false, or no async flag). Pass what they share in " <>
             "as an argument or option and make them async, or add each to " <>
             "@sync_allowed with the reason its subject is the shared thing:\n" <>
             Enum.join(unlisted, "\n")

    stale = Map.keys(@sync_allowed) -- sync
    assert stale == [], "no longer sync, so drop from @sync_allowed:\n" <> Enum.join(stale, "\n")
  end

  test "no test writes global state to steer the code" do
    offenders =
      for path <- ["test/test_helper.exs" | test_files()] ++ Path.wildcard("test/support/**/*.ex"),
          path not in @global_write_allowed,
          path not in Map.keys(@sync_allowed),
          Enum.any?(code_lines(path), &(&1 =~ @global_writes)),
          do: path

    assert offenders == [],
           "these write application env, the OS environment, the Mix shell, the Logger " <>
             "config or levels, a persistent term or Mox's global mode. Pass the dependency in instead:\n" <>
             Enum.join(offenders, "\n")
  end

  # DDL or an explicit lock on a table every test uses holds its lock to the end
  # of the test's sandbox transaction, so each concurrent test touching that
  # table waits: a test that stalls only when another runs beside it.
  # `Loopctl.Test.LockGuard` catches a lock still held at teardown on an owner
  # connection; this catches the statement in the source, wherever it runs.
  # Whole-file patterns, so a statement split across heredoc lines is still
  # seen; a table may be schema-qualified or quoted.
  @table ~S{(?:"?public"?\.)?"?([a-z_]+)"?}
  @shared_table_ddl [
    ~r/ALTER\s+TABLE\s+(?:ONLY\s+)?(?:IF\s+EXISTS\s+)?#{@table}/i,
    ~r/LOCK\s+(?:TABLE\s+)?(?:ONLY\s+)?#{@table}\s+IN\s/i,
    ~r/TRUNCATE\s+(?:TABLE\s+)?(?:ONLY\s+)?#{@table}/i,
    ~r/CREATE\s+(?:OR\s+REPLACE\s+)?(?:CONSTRAINT\s+)?TRIGGER\b[^;]*?\bON\s+#{@table}/i,
    ~r/CREATE\s+(?:UNIQUE\s+)?INDEX\b[^;"]*?\bON\s+#{@table}/i
  ]

  # The app's tables, and the ones its dependencies write that every test
  # reaches (an Oban insert, a migration check).
  defp shared_tables do
    {:ok, modules} = :application.get_key(:loopctl, :modules)

    for module <- [Oban.Job | modules],
        Code.ensure_loaded?(module),
        function_exported?(module, :__schema__, 1),
        source = module.__schema__(:source),
        is_binary(source),
        into: MapSet.new(["schema_migrations"]),
        do: source
  end

  # Comment lines are blanked rather than dropped, so line numbers still match.
  defp shared_ddl(source, tables) do
    code =
      source
      |> String.split("\n")
      |> Enum.map_join("\n", fn line ->
        if String.starts_with?(String.trim_leading(line), "#"), do: "", else: line
      end)

    for pattern <- @shared_table_ddl,
        [{start, _}, {from, length}] <- Regex.scan(pattern, code, return: :index),
        table = code |> binary_part(from, length) |> String.downcase(),
        MapSet.member?(tables, table),
        do: {line_of(code, start), table}
  end

  defp line_of(code, offset),
    do: code |> binary_part(0, offset) |> String.split("\n") |> length()

  test "no async test runs DDL or takes a lock on a table other tests use" do
    tables = shared_tables()
    assert MapSet.member?(tables, "tenants")
    assert MapSet.member?(tables, "stories")

    offenders =
      for path <- test_files(),
          # Its own control strings name these statements.
          path != @self_path,
          not sync?(path),
          {number, table} <- path |> File.read!() |> shared_ddl(tables),
          do: "#{path}:#{number}: #{table}"

    assert offenders == [],
           "these alter or lock a table every test shares, inside a transaction " <>
             "that holds the lock to the test's end. Inject the failure, or use " <>
             "a table the test creates:\n" <> Enum.join(offenders, "\n")
  end

  test "the scans see a sync module, a global write and shared DDL when there is one" do
    # Positive control: without it, a scan that matched nothing would pass all three.
    assert Enum.any?(Map.keys(@sync_allowed), &sync?/1)
    # Judged by its options, however a `use` is wrapped.
    refute source_sync?("defmodule M do\n  use Loopctl.DataCase,\n    async: true\nend")
    assert source_sync?("defmodule M do\n  use Loopctl.DataCase,\n    async: false\nend")
    assert source_sync?("defmodule M do\n  use ExUnit.Case\nend")
    refute source_sync?("defmodule M do\n  use GenServer\nend")

    assert ~s{System.put_env("X", "1")} =~ @global_writes
    assert "Application.put_env(:loopctl, :k, 1)" =~ @global_writes
    assert "Logger.put_module_level(Mod, :info)" =~ @global_writes
    assert "Logger.configure(level: :debug)" =~ @global_writes
    assert ":logger.unset_module_level(Mod)" =~ @global_writes
    assert ":application.set_env(:loopctl, :k, 1)" =~ @global_writes
    assert "Mix.shell(shell)" =~ @global_writes
    refute "Mix.shell()" =~ @global_writes
    refute ":logger.update_process_metadata(%{a: 1})" =~ @global_writes
    assert ":persistent_term.put({Mod, :owner}, self())" =~ @global_writes
    assert "Mox.set_mox_global()" =~ @global_writes
    refute "Application.get_env(:loopctl, :k)" =~ @global_writes

    tables = MapSet.new(["tenants", "audit_chain"])
    lock = ~s{Repo.query!("LOCK TABLE tenants IN SHARE ROW EXCLUSIVE MODE")}
    assert shared_ddl(lock, tables) == [{1, "tenants"}]
    trigger = "x\ncreate trigger t\n  before insert on public.audit_chain"
    assert shared_ddl(trigger, tables) == [{2, "audit_chain"}]
    assert shared_ddl(~s{ALTER TABLE "tenants" ADD CHECK (false)}, tables) == [{1, "tenants"}]
    assert shared_ddl(~s{sql!("LOCK TABLE lock_probe IN SHARE ROW EXCLUSIVE MODE")}, tables) == []
    assert shared_ddl("DateTime.truncate(:second)", tables) == []
  end
end
