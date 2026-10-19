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

  alias Loopctl.Repo
  alias Loopctl.Test.LockGuard

  @race "committed transactions racing on independent `sandbox: false` connections: the " <>
          "sandbox puts every allowed process on one connection, which serialises the race itself"
  @second_connection "a lock or write held by a SECOND connection is the subject, so its rows " <>
                       "are committed for both connections to see"
  @trigger_fault "injects its fault with a trigger on a shared table; that DDL lock would " <>
                   "stall every concurrent test writing the table until the test ended"
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
    "test/loopctl/changes_lock_test.exs" => @race,
    "test/loopctl/changes/events_lock_test.exs" => @race,
    "test/loopctl/changes/review_custody_lock_test.exs" => @race,
    "test/loopctl/config_test_exs_partition_wiring_test.exs" =>
      "the subject is config/test.exs's own read of the OS environment at load time",
    "test/loopctl/context_retriever/entity_definitions_rollback_test.exs" => @migration,
    "test/loopctl/context_retriever/executor_stale_column_test.exs" =>
      "drops `stories.sort_key`: a real stale schema is the subject, and the DDL lock on " <>
        "`stories` would block every concurrent test",
    "test/loopctl/coordination_claim_race_test.exs" => @race,
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
    "test/loopctl/token_usage/correction_lock_test.exs" => @race,
    "test/loopctl/workers/audit_partition_worker_test.exs" =>
      "creates and drops partitions of the shared `audit_log` tree: catalog DDL every " <>
        "audit write queues behind",
    "test/loopctl/workers/revoke_expired_dispatches_plan_scale_test.exs" => @scale,
    "test/loopctl/workers/triage_trigger_worker_lock_test.exs" => @second_connection,
    "test/loopctl/workers/verification_runner_worker_lock_test.exs" => @second_connection,
    "test/loopctl_web/runner_channel_lock_test.exs" => @second_connection
  }

  # Writes to state every test process shares. A line matching `@global_writes`, or a call
  # `global_calls/1` finds in the parsed file, fails unless that file's entry in
  # `@global_write_allowed` names the write. Being sync-allowed exempts a module from
  # nothing but `set_mox_global`: Mox's global mode needs a sync module, and the module is
  # sync for the reason `@sync_allowed` gives. Erasing a persistent term is not matched:
  # clearing a key a test's own setup made unique is cleanup.
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

  # path => {the writes that file may make, why}. Any other write in it still fails.
  @global_write_allowed %{
    @self_path => {~r/.*/, "names every pattern as its own positive control"},
    "test/test_helper.exs" =>
      {~r/Logger\.put_module_level\(|:persistent_term\.put\(/,
       "runs once, before any test: raises Logger levels (CLAUDE.md's one sanctioned place) " <>
         "and creates the story-number counter"},
    "test/loopctl/config_embedding_read_path_test.exs" =>
      {~r/set_mox_global/, "its own guard's control strings name the call"},
    "test/loopctl/config_test_exs_partition_wiring_test.exs" =>
      {~r/System\.(put_env|delete_env)\(/,
       "config/test.exs reading the OS environment at load time is the subject"},
    "test/loopctl/system_config_test.exs" =>
      {~r/SystemConfig\.put\/2/,
       "SystemConfig's default namespace is the subject, and every key is unique to its test"}
  }

  # Read once: three scans and the control share every file's source and sync verdict.
  setup_all do
    tests = Path.wildcard("test/**/*_test.exs")
    support = Path.wildcard("test/support/**/*.ex")
    sources = Map.new(["test/test_helper.exs" | tests ++ support], &{&1, File.read!(&1)})
    sync = for path <- tests, source_sync?(sources[path]), into: MapSet.new(), do: path
    {:ok, tests: tests, support: support, sources: sources, sync: sync}
  end

  defp comment?(line), do: String.starts_with?(String.trim_leading(line), "#")

  # Comment lines are blanked rather than dropped, so line numbers still match.
  defp blank_comments(source) do
    source
    |> String.split("\n")
    |> Enum.map_join("\n", fn line -> if comment?(line), do: "", else: line end)
  end

  # Read from the parsed file, not its lines, so a `use` that `mix format`
  # wraps across lines is judged by its options all the same.
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

  # Every global write in a source, as {line, what was written}.
  defp global_writes(source) do
    by_line =
      for {line, number} <- source |> String.split("\n") |> Enum.with_index(1),
          not comment?(line),
          [text | _] <- [Regex.run(@global_writes, line)],
          do: {number, text}

    by_line ++ global_calls(Code.string_to_quoted!(source))
  end

  # Calls that write the node-wide cache without naming it, however `mix format` wraps
  # them: `SystemConfig.put/2` (the default namespace, where `put/3` takes a test's own)
  # and `TermCache.put/3` on a module namespace rather than a test's own ETS table.
  defp global_calls(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, mod}, :put]}, meta, args} = node, acc when is_list(args) ->
          {node, global_call(List.last(mod), args, meta[:line]) ++ acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp global_call(:SystemConfig, args, line) when length(args) < 3,
    do: [{line, "SystemConfig.put/2"}]

  defp global_call(:TermCache, [namespace | _], line) do
    if module_namespace?(namespace),
      do: [{line, "TermCache.put/3 on a module namespace"}],
      else: []
  end

  defp global_call(_module, _args, _line), do: []

  defp module_namespace?({:__aliases__, _, _}), do: true
  defp module_namespace?({:__MODULE__, _, _}), do: true
  defp module_namespace?(namespace), do: is_atom(namespace)

  defp allowed_write?(path, text, sync) do
    named =
      case Map.fetch(@global_write_allowed, path) do
        {:ok, {pattern, _why}} -> text =~ pattern
        :error -> false
      end

    named or (text =~ ~r/set_mox_global/ and MapSet.member?(sync, path))
  end

  test "every sync test module states why it cannot be async", %{tests: tests, sync: sync} do
    assert length(tests) > 500

    unlisted = sync |> Enum.reject(&Map.has_key?(@sync_allowed, &1)) |> Enum.sort()

    assert unlisted == [],
           "these run sync (async: false, or no async flag). Pass what they share in " <>
             "as an argument or option and make them async, or add each to " <>
             "@sync_allowed with the reason its subject is the shared thing:\n" <>
             Enum.join(unlisted, "\n")

    stale = @sync_allowed |> Map.keys() |> Enum.reject(&MapSet.member?(sync, &1)) |> Enum.sort()
    assert stale == [], "no longer sync, so drop from @sync_allowed:\n" <> Enum.join(stale, "\n")
  end

  test "no test writes global state to steer the code", %{sources: sources, sync: sync} do
    offenders =
      for {path, source} <- Enum.sort(sources),
          {line, text} <- global_writes(source),
          not allowed_write?(path, text, sync),
          do: "#{path}:#{line}: #{text}"

    assert offenders == [],
           "these write application env, the OS environment, the Mix shell, the Logger " <>
             "config or levels, a persistent term, the node-wide SystemConfig cache or " <>
             "Mox's global mode. Pass the dependency in instead:\n" <>
             Enum.join(offenders, "\n")
  end

  # DDL or an explicit lock on a table every test uses holds its lock to the end
  # of the test's sandbox transaction, so each concurrent test touching that
  # table waits: a test that stalls only when another runs beside it.
  # `Loopctl.Test.LockGuard` catches a lock still held at teardown on an owner
  # connection; this catches the statement in the source, wherever it runs.
  # Whole-file patterns, so a statement split across heredoc lines is still
  # seen; a table may be schema-qualified or quoted, and LOCK, TRUNCATE and DROP INDEX
  # may name several. An interpolated table cannot be read from the source, so it is
  # reported whatever it names; an index is mapped to the table it is on.
  @name ~S{(?:"?public"?\.)?"?[a-z_]+"?}
  @target "(" <> @name <> ~S"|#\{[^}]*\})"
  @targets "(" <> @name <> ~S"(?:\s*,\s*" <> @name <> ~S")*|#\{[^}]*\})"
  @shared_table_ddl [
    table: ~r/\bALTER\s+TABLE\s+(?:(?:IF\s+EXISTS|ONLY)\s+)*#{@target}/i,
    table: ~r/\bLOCK\s+TABLE\s+(?:ONLY\s+)?#{@targets}/i,
    table: ~r/\bLOCK\s+(?:ONLY\s+)?#{@targets}\s+IN\s/i,
    table: ~r/\bTRUNCATE\s+(?:TABLE\s+)?(?:ONLY\s+)?#{@targets}/i,
    table:
      ~r/\bCREATE\s+(?:OR\s+REPLACE\s+)?(?:CONSTRAINT\s+)?TRIGGER\b[^;]{0,300}?\bON\s+(?:ONLY\s+)?#{@target}/i,
    table: ~r/\bDROP\s+TRIGGER\b[^;]{0,200}?\bON\s+#{@target}/i,
    table: ~r/\bCREATE\s+(?:UNIQUE\s+)?INDEX\b[^;]{0,300}?\bON\s+(?:ONLY\s+)?#{@target}/i,
    index: ~r/\bDROP\s+INDEX\s+(?:CONCURRENTLY\s+)?(?:IF\s+EXISTS\s+)?#{@targets}/i
  ]

  # path => {the hits that file may show, why}: DDL text the source cannot show is safe.
  @ddl_allowed %{
    "test/loopctl/embeddings/legacy_index_retirement_runbook_test.exs" =>
      {["articles"], "asserts the runbook's DROP INDEX text and runs no SQL"},
    "test/loopctl/repo/reconcile_hnsw_index_migration_test.exs" =>
      {[:interpolated],
       "its interpolated table is one each test creates in its own sandbox transaction"}
  }

  # Every table in the test database is one other tests use: a table a test creates
  # inside its own sandbox transaction is never committed, so no other connection sees
  # it. Read from the catalog rather than the schemas, so a table only raw SQL reaches
  # (`rate_limit_counters`) counts, and so an index resolves to its table.
  defp catalog do
    _backend_pids = LockGuard.start_owner!(Repo)
    %{rows: tables} = Repo.query!("SELECT tablename FROM pg_tables WHERE schemaname = 'public'")

    %{rows: indexes} =
      Repo.query!("SELECT indexname, tablename FROM pg_indexes WHERE schemaname = 'public'")

    %{
      tables: MapSet.new(tables, fn [table] -> table end),
      indexes: Map.new(indexes, &List.to_tuple/1)
    }
  end

  defp shared_ddl(source, %{tables: tables, indexes: indexes}) do
    code = blank_comments(source)

    hits =
      for {kind, pattern} <- @shared_table_ddl,
          [{start, _}, {from, length}] <- Regex.scan(pattern, code, return: :index),
          target <- targets(binary_part(code, from, length)),
          table = resolve(kind, target, indexes),
          table == :interpolated or MapSet.member?(tables, table),
          do: {line_of(code, start), table}

    Enum.uniq(hits)
  end

  defp targets(capture) do
    if String.starts_with?(capture, "\#{") do
      [:interpolated]
    else
      for [_, name] <- Regex.scan(~r/(?:"?public"?\.)?"?([a-z_]+)"?/i, capture),
          do: String.downcase(name)
    end
  end

  defp resolve(_kind, :interpolated, _indexes), do: :interpolated
  defp resolve(:table, name, _indexes), do: name
  defp resolve(:index, name, indexes), do: Map.get(indexes, name)

  defp line_of(code, offset),
    do: code |> binary_part(0, offset) |> String.split("\n") |> length()

  # A support helper's DDL runs in whichever test calls it: {module, "path:line: table"}.
  defp ddl_helpers(support, sources, catalog) do
    for path <- support,
        [{line, table} | _] <- [shared_ddl(sources[path], catalog)],
        [_, module] <- Regex.scan(~r/^\s*defmodule\s+([\w.]+)/m, sources[path]),
        do: {module, "#{path}:#{line}: #{table}"}
  end

  # Named in full, or by its last segment under a multi-alias of its namespace.
  defp references?(source, module) do
    code = blank_comments(source)
    {namespace, [last]} = module |> String.split(".") |> Enum.split(-1)
    prefix = Enum.join(namespace, ".")

    String.contains?(code, module) or
      (prefix != "" and String.contains?(code, prefix <> ".{") and code =~ ~r/\b#{last}\b/)
  end

  test "no async test runs DDL or takes a lock on a table other tests use", ctx do
    catalog = catalog()
    assert MapSet.member?(catalog.tables, "stories")
    assert MapSet.member?(catalog.tables, "rate_limit_counters")

    helpers = ddl_helpers(ctx.support, ctx.sources, catalog)
    assert Enum.any?(helpers, &match?({"Loopctl.Test.BrokenChain", _}, &1))

    async = Enum.reject(ctx.tests, &(&1 == @self_path or MapSet.member?(ctx.sync, &1)))

    hits = Map.new(async, &{&1, shared_ddl(ctx.sources[&1], catalog)})

    direct =
      for {path, path_hits} <- Enum.sort(hits),
          {number, table} <- path_hits,
          table not in elem(Map.get(@ddl_allowed, path, {[], nil}), 0),
          do: "#{path}:#{number}: #{table}"

    stale =
      for {path, {tables, _why}} <- @ddl_allowed,
          table <- tables,
          not Enum.any?(Map.get(hits, path, []), &match?({_, ^table}, &1)),
          do: "#{path}: #{table}"

    assert stale == [], "no longer seen, so drop from @ddl_allowed:\n" <> Enum.join(stale, "\n")

    via_helpers =
      for {module, site} <- helpers,
          path <- async,
          references?(ctx.sources[path], module),
          do: "#{path} calls #{module} (#{site})"

    assert direct ++ via_helpers == [],
           "these alter or lock a table every test shares, inside a transaction " <>
             "that holds the lock to the test's end. Inject the failure, or use " <>
             "a table the test creates:\n" <> Enum.join(direct ++ via_helpers, "\n")
  end

  test "the scans see a sync module, a global write and shared DDL when there is one", ctx do
    # Positive control: without it, a scan that matched nothing would pass all three.
    assert Enum.any?(Map.keys(@sync_allowed), &MapSet.member?(ctx.sync, &1))
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

    # The node-wide cache, written through its wrappers, wrapped across lines or not.
    assert global_writes(~s{SystemConfig.put(\n  "k",\n  0\n)}) == [{1, "SystemConfig.put/2"}]
    assert global_writes(~s{SystemConfig.put("k", 0, cache)}) == []

    assert global_writes(~s{TermCache.put(Loopctl.SystemConfig, "k", 0)}) ==
             [{1, "TermCache.put/3 on a module namespace"}]

    assert global_writes(~s{TermCache.put(__MODULE__, "k", 0)}) ==
             [{1, "TermCache.put/3 on a module namespace"}]

    assert global_writes(~s{TermCache.put(cache(), "k", 0)}) == []
    # Sync-allowed exempts only Mox's global mode.
    assert allowed_write?(
             "test/loopctl/coordination_claim_race_test.exs",
             "set_mox_global",
             ctx.sync
           )

    refute allowed_write?(
             "test/loopctl/coordination_claim_race_test.exs",
             "Application.put_env(",
             ctx.sync
           )

    refute allowed_write?("test/loopctl/system_config_test.exs", "Application.put_env(", ctx.sync)

    catalog = %{
      tables: MapSet.new(["tenants", "stories", "audit_chain"]),
      indexes: %{"stories_pkey" => "stories"}
    }

    lock = ~s{Repo.query!("LOCK TABLE tenants IN SHARE ROW EXCLUSIVE MODE")}
    assert shared_ddl(lock, catalog) == [{1, "tenants"}]
    assert shared_ddl(~s{Repo.query!("LOCK TABLE stories")}, catalog) == [{1, "stories"}]
    assert shared_ddl(~s{"LOCK stories IN ACCESS EXCLUSIVE MODE"}, catalog) == [{1, "stories"}]

    assert shared_ddl(~s{"LOCK TABLE stories, public.tenants IN SHARE MODE"}, catalog) ==
             [{1, "stories"}, {1, "tenants"}]

    trigger = "x\ncreate trigger t\n  before insert on public.audit_chain"
    assert shared_ddl(trigger, catalog) == [{2, "audit_chain"}]

    assert shared_ddl(~s{"DROP TRIGGER IF EXISTS t ON audit_chain"}, catalog) == [
             {1, "audit_chain"}
           ]

    assert shared_ddl(~s{ALTER TABLE "tenants" ADD CHECK (false)}, catalog) == [{1, "tenants"}]

    assert shared_ddl(~s{ALTER TABLE IF EXISTS ONLY stories ADD CHECK (false)}, catalog) == [
             {1, "stories"}
           ]

    assert shared_ddl(~s{CREATE INDEX "stories_x_idx" ON stories (title)}, catalog) == [
             {1, "stories"}
           ]

    assert shared_ddl(~s{DROP INDEX IF EXISTS stories_pkey}, catalog) == [{1, "stories"}]

    assert shared_ddl(~S|"ALTER TABLE #{@table} ADD CHECK (false)"|, catalog) == [
             {1, :interpolated}
           ]

    assert shared_ddl(~s{TRUNCATE stories, tenants}, catalog) == [{1, "stories"}, {1, "tenants"}]

    assert shared_ddl(~s{sql!("LOCK TABLE lock_probe IN SHARE ROW EXCLUSIVE MODE")}, catalog) ==
             []

    assert shared_ddl("DateTime.truncate(:second)", catalog) == []
    assert shared_ddl("  # LOCK TABLE stories", catalog) == []

    # A helper is matched by name, never by a module whose name only contains it.
    assert references?("Loopctl.Test.BrokenChain.install!(id)", "Loopctl.Test.BrokenChain")
    assert references?("alias Loopctl.Test.{BrokenChain, Other}", "Loopctl.Test.BrokenChain")
    refute references?("LoopctlWeb.StoryEscalationBrokenChainTest", "Loopctl.Test.BrokenChain")
    refute references?("# Loopctl.Test.BrokenChain", "Loopctl.Test.BrokenChain")
  end
end
