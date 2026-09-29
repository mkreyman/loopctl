defmodule Loopctl.AsyncDdlGuardTest do
  @moduledoc """
  No `async: true` test module, and no helper in `test/support/`, may hand table-locking DDL
  to the database for a table other tests use.

  Inside the Ecto sandbox a test is one transaction, so a `CREATE TRIGGER`, `ALTER TABLE`,
  `DROP INDEX`, `DROP POLICY`, `LOCK TABLE` and the like hold their SHARE ROW EXCLUSIVE or
  ACCESS EXCLUSIVE lock until the test ENDS. Every concurrent async test that touches the
  same table waits out the statement timeout and fails 57014 `query_canceled` — a red that
  never reproduces alone. It shipped three times before this guard (KB 493d2020; on
  2026-09-29 a `CREATE TRIGGER` on `tenant_llm_settings`, an `ALTER TABLE ... DISABLE
  TRIGGER` on the embedding side tables and a `DROP INDEX` on `rate_limit_counters`, #939).

  Lock-free alternatives: `SET LOCAL session_replication_role = replica` to skip triggers, a
  transaction-local setting to force an error. Where the DDL itself is what the test is
  about, the module is `async: false` with the reason in its moduledoc — the repo's
  documented exception to "async: true on every test file". Each worktree has its own test
  database (`MIX_TEST_PARTITION`, `config/test.exs`), so a synchronous module blocks nothing
  outside its own run.

  WHAT IT READS: the SQL LITERAL handed to `query`, `query!`, `query_many` or `query_many!`
  — as the first argument (plain strings, heredocs and `~s|...|`/`~s(...)`, parentheses in the
  SQL included) or piped in (`"..." |> Repo.query!()`) — and every call to one of
  `Loopctl.Repo.HnswIndex`'s `*_sql` DDL builders. A statement on a table the test CREATES
  ITSELF is exempt one statement at a time (`@private_ddl`), never a whole file.

  WHAT IT CANNOT READ, stated so nobody relies on it for this: SQL that reaches `query!`
  through a variable, a module attribute or a helper outside `HnswIndex`. The rule still
  holds there; only the check does not.
  """

  use ExUnit.Case, async: true

  @ddl ~r/\b(CREATE\s+(OR\s+REPLACE\s+)?(CONSTRAINT\s+)?(TRIGGER|UNIQUE\s+INDEX|INDEX|TABLE|FUNCTION|POLICY|RULE|SCHEMA|MATERIALIZED\s+VIEW)|ALTER\s+(TABLE|INDEX|TRIGGER|POLICY)|DROP\s+(INDEX|TRIGGER|TABLE|FUNCTION|POLICY|RULE)|LOCK\s+TABLE|TRUNCATE|REINDEX|CLUSTER|VACUUM\s+FULL|REFRESH\s+MATERIALIZED\s+VIEW|(GRANT|REVOKE)\s+[\w\s,]+\s+ON)\b/i

  @literal ~S{("""[\s\S]*?"""|"(?:[^"\\]|\\.)*"|~[sS]\|[^|]*\||~[sS]\((?:[^()]|\([^()]*\))*\))}

  # The SQL literal a query call receives: `query!(<literal>` or `<literal> |> X.query!(`.
  @handed Regex.compile!(
            ~S{\bquery(?:_many)?!?\(\s*} <>
              @literal <>
              ~S{|} <> @literal <> ~S{\s*\|>\s*[\w.]*\bquery(?:_many)?!?\(},
            "s"
          )

  @builder ~r/HnswIndex\.\w+_sql\(/

  # {file, the DDL as the scan reports it}: a statement on a table, schema or temp table the
  # test creates itself, so no other test can hold or wait on its lock. One statement per
  # entry, so DDL added to the same file later is still read.
  @private_ddl MapSet.new([
                 {"test/loopctl/repo/hnsw_index_params_test.exs",
                  ~S|"CREATE TABLE #{table} (id bigserial PRIMARY KEY, embedding vector(1536))"|},
                 {"test/loopctl/repo/hnsw_index_params_test.exs",
                  "HnswIndex.create_if_absent_sql("},
                 {"test/loopctl/repo/reconcile_hnsw_index_migration_test.exs",
                  ~S|"CREATE TABLE #{table} (id bigserial PRIMARY KEY, embedding vector(1536))"|},
                 {"test/loopctl/repo/reconcile_hnsw_index_migration_test.exs",
                  ~S|"CREATE INDEX #{name} ON #{table} USING hnsw (embedding vector_cosine_ops)"|},
                 {"test/loopctl/repo/reconcile_hnsw_index_migration_test.exs",
                  "HnswIndex.drop_all_sql("},
                 {"test/loopctl/repo/reconcile_hnsw_index_migration_test.exs",
                  "HnswIndex.create_if_absent_sql("},
                 {"test/loopctl/repo/reconcile_hnsw_index_migration_test.exs",
                  "HnswIndex.reconcile_sql("},
                 {"test/loopctl/repo/reconcile_hnsw_index_migration_test.exs",
                  ~S|"CREATE TABLE #{canonical} (id int)"|},
                 {"test/loopctl/search/regconfig_test.exs", ~S|"DROP TABLE IF EXISTS fts_probe"|},
                 {"test/loopctl/workers/channel_post_rescan_worker_test.exs",
                  ~S|"CREATE SCHEMA #{schema}"|},
                 {"test/loopctl/workers/channel_post_rescan_worker_test.exs",
                  ~S|"CREATE TABLE #{schema}.channel_posts (quarantined_at timestamptz)"|}
               ])

  @self "test/loopctl/async_ddl_guard_test.exs"

  test "no async module or test helper hands table-locking DDL to the database" do
    files = Path.wildcard("test/**/*_test.exs") ++ Path.wildcard("test/support/**/*.ex")
    sources = Map.new(files, &{&1, File.read!(&1)})

    scanned =
      for {path, source} <- sources,
          path != @self,
          String.starts_with?(path, "test/support/") or async?(source),
          do: path

    # Vacuity guards: a wrong working directory or a detector that never matches would leave
    # nothing to scan and pass; a stale exemption would silently exempt nothing.
    assert length(files) > 100, "scanned only #{length(files)} files"
    assert async?(sources[@self])
    assert length(scanned) > 100, "only #{length(scanned)} async modules and helpers"

    for {path, statement} <- @private_ddl do
      assert statement in ddl_statements(sources[path]), "stale exemption: #{path} #{statement}"
    end

    offenders =
      for path <- Enum.sort(scanned),
          statement <- ddl_statements(sources[path]),
          not MapSet.member?(@private_ddl, {path, statement}),
          do: {path, statement}

    assert offenders == [],
           "table-locking DDL in an async test module or a test helper (make it lock-free, " <>
             "or async: false with the reason, or exempt a private-table statement): " <>
             inspect(offenders, pretty: true)
  end

  test "the scan reads DDL however it is handed over, and not prose around it" do
    for code <- [
          ~S{AdminRepo.query!("ALTER TABLE t DISABLE TRIGGER x")},
          ~S{"DROP INDEX i" |> AdminRepo.query!()},
          ~S{Repo.query_many!("SELECT set_config('a','b',true); CREATE INDEX i ON t (c)")},
          ~S{AdminRepo.query!("DO $$ BEGIN IF to_regclass('x') IS NULL THEN ALTER TABLE t ADD c int; END IF; END $$")},
          ~S{AdminRepo.query!("DROP POLICY tenant_isolation ON stories")},
          ~S{AdminRepo.query!(~s|CREATE CONSTRAINT TRIGGER t AFTER INSERT ON x|)},
          ~S{AdminRepo.query!(HnswIndex.drop_all_sql("article_embeddings"))},
          "AdminRepo.query!(\"\"\"\nLOCK TABLE articles IN ACCESS EXCLUSIVE MODE\n\"\"\")"
        ] do
      assert ddl_statements(code) != [], "missed: #{code}"
    end

    for prose <- [
          ~S{# AdminRepo.query!("ALTER TABLE t")},
          ~S{test "no lib/ module issues CREATE INDEX" do},
          ~S{assert body =~ "DROP TABLE"},
          ~S{AdminRepo.query!("SET LOCAL session_replication_role = replica")}
        ] do
      assert ddl_statements(prose) == [], "flagged: #{prose}"
    end
  end

  test "the async detector reads the use line, reflowed or not" do
    assert async?("  use Loopctl.DataCase, async: true\n")
    assert async?("  use LoopctlWeb.ConnCase,\n    async: true\n")
    refute async?("  use Loopctl.DataCase, async: false\n")
  end

  defp ddl_statements(source) do
    code = String.replace(source, ~r/^\s*#.*$/m, "")

    handed =
      for [_match | literals] <- Regex.scan(@handed, code),
          literal = Enum.find(literals, &(&1 != "")),
          Regex.match?(@ddl, literal),
          do: literal

    handed ++ (@builder |> Regex.scan(code) |> List.flatten())
  end

  defp async?(source), do: String.match?(source, ~r/^\s*use\s+[\w.]+Case,\s*async:\s*true/m)
end
