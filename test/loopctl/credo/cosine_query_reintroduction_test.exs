defmodule Loopctl.Credo.Check.CosineQueryReintroductionTest do
  @moduledoc """
  US-27.8 TC-27.8.4: unit tests for the cosine-`<=>` reintroduction Credo guard.

  Proves the check is a REAL anti-regression guard, not a no-op:

    * it FLAGS a new hand-rolled `fragment("… <=> …")` outside the shared helper, and
      the issue message NAMES the offending `M.f/a`;
    * it EXEMPTS the whole `Loopctl.Knowledge.VectorSearch` module (the helper's home);
    * it EXEMPTS a registered `CosineLintExceptions` function (`do_distant_pairs/7`,
      `novelty_distance_query/4`) — the allowlist works;
    * it is PRECISE — a `<=>` in a `@moduledoc`/`@doc`/comment/Regex/data string is NOT
      flagged (those are documentation, not a query);
    * REGRESSION: the REAL cosine-bearing `lib/loopctl` sources pass the check with ZERO
      issues, i.e. every existing `<=>` (the 3 `VectorSearch` helper sites + the 3
      registered `Loopctl.Knowledge` exceptions) is correctly exempt and nothing leaks.

  The check lives under `.credo/` (outside `lib/`, so `MIX_ENV=prod mix compile` can't
  drag it into the release) and is loaded by Credo via `.credo.exs` `requires:`. For the
  unit test we `Code.require_file/1` it explicitly.
  """
  use Credo.Test.Case, async: true

  @check_path Path.expand("../../../.credo/checks/cosine_query_reintroduction.ex", __DIR__)

  # Load the out-of-lib check source into the test VM once. `CosineLintExceptions` is
  # ordinary `lib/` code (compiled in :test), so it's already available for the check's
  # allowlist read.
  Code.require_file(@check_path)

  alias Loopctl.Credo.Check.CosineQueryReintroduction

  # Credo is a `runtime: false` dep, so its application (which supervises the
  # `Credo.Service.*` GenServers that `Credo.Test.Case`'s `to_source_file/2` and
  # `run_check/2` talk to) is not auto-started. Boot it for this test module. In the FULL
  # suite another test may have started it already, so accept `:already_started` (this is
  # NOT `Application.ensure_all_started/1`, which would itself need the runtime started —
  # we go straight to `Application.start/1` and treat already-running as success).
  setup_all do
    # `ensure_all_started/1` pulls in credo's deps (:bunt, :file_system, …). In the full
    # suite credo may already be up (another `Credo.Test.Case` user, or a prior run in the
    # same VM), in which case the supervisor reports `:already_started` — treat that as
    # success rather than letting a `{:ok, _}` match crash the whole module's setup_all.
    case Application.ensure_all_started(:credo) do
      {:ok, _started} -> :ok
      {:error, {:credo, {{:already_started, _pid}, _}}} -> :ok
      {:error, {_app, {:already_started, _pid}}} -> :ok
      {:error, reason} -> raise "could not start :credo for the lint test: #{inspect(reason)}"
    end

    :ok
  end

  describe "flags a NEW hand-rolled cosine site outside the helper (AC-27.8.5)" do
    test "a fragment(\"… <=> …\") ORDER BY in a non-helper module is reported once, naming the M.f/a" do
      """
      defmodule My.Rogue.Search do
        import Ecto.Query

        def nearest(tenant_id, target) do
          from(a in Article,
            where: a.tenant_id == ^tenant_id,
            order_by: [asc: fragment("? <=> ?", a.embedding, ^target)],
            limit: 10
          )
        end
      end
      """
      |> to_source_file("lib/my/rogue/search.ex")
      |> run_check(CosineQueryReintroduction)
      |> assert_issue(fn issue ->
        assert issue.message =~ "My.Rogue.Search.nearest/2"
        assert issue.message =~ "Loopctl.Knowledge.VectorSearch"
        assert issue.message =~ "CosineLintExceptions"
        assert issue.trigger == "distance"
      end)
    end

    test "a MIN(<=>) aggregate in an UN-registered function is reported" do
      """
      defmodule My.Rogue.Novelty do
        import Ecto.Query

        def min_distance(tenant_id, target) do
          from(a in Article,
            where: a.tenant_id == ^tenant_id,
            select: fragment("MIN(? <=> ?::vector)", a.embedding, ^target)
          )
        end
      end
      """
      |> to_source_file("lib/my/rogue/novelty.ex")
      |> run_check(CosineQueryReintroduction)
      |> assert_issue(fn issue ->
        assert issue.message =~ "My.Rogue.Novelty.min_distance/2"
      end)
    end

    test "a cosine fragment OUTSIDE any def (module level) is still reported (no hiding spot)" do
      """
      defmodule My.Rogue.ModuleLevel do
        import Ecto.Query
        @bad from(a in Article, order_by: fragment("? <=> ?", a.embedding, a.embedding))
      end
      """
      |> to_source_file("lib/my/rogue/module_level.ex")
      |> run_check(CosineQueryReintroduction)
      |> assert_issue(fn issue ->
        assert issue.message =~ "My.Rogue.ModuleLevel"
        assert issue.message =~ "module-level"
      end)
    end

    test "an INTERPOLATED fragment string is flagged (`<=>` lives in a `<<>>` node) — review FN-1" do
      # The `\#{col}` is escaped so the FIXTURE source carries a literal interpolated
      # `fragment("#{col} <=> ?", …)`. A shallow direct-child check missed this (the `<=>`
      # is not a direct plain-binary arg); the deep arg-walk now catches it.
      """
      defmodule My.Rogue.Interp do
        import Ecto.Query

        def nearest(col, target) do
          from(a in Article, order_by: fragment("\#{col} <=> ?", ^target))
        end
      end
      """
      |> to_source_file("lib/my/rogue/interp.ex")
      |> run_check(CosineQueryReintroduction)
      |> assert_issue(fn issue ->
        assert issue.message =~ "My.Rogue.Interp.nearest/2"
        assert issue.trigger == "distance"
      end)
    end

    test "a CONCATENATED fragment string is flagged (`<=>` inside a `<>` node) — review FN-2" do
      """
      defmodule My.Rogue.Concat do
        import Ecto.Query

        def nearest(target) do
          from(a in Article, order_by: fragment("? <=>" <> " ?", ^target))
        end
      end
      """
      |> to_source_file("lib/my/rogue/concat.ex")
      |> run_check(CosineQueryReintroduction)
      |> assert_issue(fn issue ->
        assert issue.message =~ "My.Rogue.Concat.nearest/1"
      end)
    end

    test "a NESTED-module site is attributed to its OWN module (not the outer one)" do
      # Guards the per-module exemption: a rogue `<=>` in a module nested inside an exempt
      # one must still be flagged on its own full name, not wholesale-suppressed.
      """
      defmodule My.Outer do
        defmodule Inner do
          import Ecto.Query

          def nearest(target) do
            from(a in Article, order_by: fragment("? <=> ?", a.embedding, ^target))
          end
        end
      end
      """
      |> to_source_file("lib/my/outer.ex")
      |> run_check(CosineQueryReintroduction)
      |> assert_issue(fn issue ->
        assert issue.message =~ "My.Outer.Inner.nearest/1"
      end)
    end
  end

  describe "flags alternate distance spellings + raw-SQL entrypoints (review F1/SQL-1/SQL-2)" do
    test "the `cosine_distance(...)` FUNCTION spelling is flagged — same op as `<=>` (review F1)" do
      """
      defmodule My.Rogue.FnSpelling do
        import Ecto.Query

        def nearest(t) do
          from(a in Article, order_by: fragment("cosine_distance(embedding, ?)", ^t))
        end
      end
      """
      |> to_source_file("lib/my/rogue/fn_spelling.ex")
      |> run_check(CosineQueryReintroduction)
      |> assert_issue(fn issue -> assert issue.message =~ "My.Rogue.FnSpelling.nearest/1" end)
    end

    test "a raw `Repo.query_many!` cosine SQL is flagged (review SQL-1)" do
      """
      defmodule My.Rogue.QueryMany do
        def topk(target, k) do
          Repo.query_many!(
            "SELECT id FROM articles ORDER BY embedding <=> $1 LIMIT $2",
            [target, k]
          )
        end
      end
      """
      |> to_source_file("lib/my/rogue/query_many.ex")
      |> run_check(CosineQueryReintroduction)
      |> assert_issue(fn issue -> assert issue.message =~ "My.Rogue.QueryMany.topk/2" end)
    end

    test "a raw `Repo.stream` cosine SQL is flagged (review SQL-2)" do
      """
      defmodule My.Rogue.Stream do
        def each(target) do
          Repo.stream("SELECT id FROM articles ORDER BY embedding <=> $1", [target])
        end
      end
      """
      |> to_source_file("lib/my/rogue/stream.ex")
      |> run_check(CosineQueryReintroduction)
      |> assert_issue(fn issue -> assert issue.message =~ "My.Rogue.Stream.each/1" end)
    end
  end

  describe "precision + documented residuals (review F3 false-pos, var-pipe residual)" do
    test "a distance token in a fragment VALUE arg (not the SQL template) is NOT flagged (review F3)" do
      # `<=>` here is BOUND DATA, not the SQL template — fragment's SQL is arg 1 only, so a
      # token in a later (value) arg must not false-positive.
      """
      defmodule My.Fine.ValueArg do
        import Ecto.Query

        def f(t) do
          from(a in Article, where: fragment("? = ?", a.name, "prefix <=> suffix") and a.id == ^t)
        end
      end
      """
      |> to_source_file("lib/my/fine/value_arg.ex")
      |> run_check(CosineQueryReintroduction)
      |> refute_issues()
    end

    test "a var-held cosine SQL string piped to query! is the DOCUMENTED residual (NOT caught)" do
      # No literal at the call site → the AST can't see it (closing this needs data-flow
      # analysis). Pinned so the boundary is DELIBERATE + visible; loopctl never builds a
      # cosine query this way (the coarse file-set guard backstops a new-file occurrence).
      """
      defmodule My.Residual.VarPipe do
        def f(t) do
          sql = "SELECT id FROM articles ORDER BY embedding <=> $1"
          Repo.query!(sql, [t])
        end
      end
      """
      |> to_source_file("lib/my/residual/var_pipe.ex")
      |> run_check(CosineQueryReintroduction)
      |> refute_issues()
    end

    test "a cosine SQL string held in a MODULE ATTRIBUTE then referenced is the DOCUMENTED residual (NOT caught)" do
      # The `@cosine_sql "…<=>…"` definition is an `@` attribute node, NOT a SQL-bearing call,
      # and the usage `Repo.query!(@cosine_sql, …)` passes an attribute REFERENCE (no literal at
      # the call). Like the var-pipe, closing this needs data-flow; pinned as a deliberate, visible
      # boundary. The file-set tripwire backstops it: the `<=>` literal in the @attr def lands in
      # the discovered set, so a NEW file shaped this way fails the regression guard.
      """
      defmodule My.Residual.AttrRef do
        @cosine_sql "SELECT id FROM articles ORDER BY embedding <=> $1"
        def f(t), do: Repo.query!(@cosine_sql, [t])
      end
      """
      |> to_source_file("lib/my/residual/attr_ref.ex")
      |> run_check(CosineQueryReintroduction)
      |> refute_issues()
    end
  end

  describe "exempts the helper module and the registered allowlist (AC-27.8.5)" do
    test "the whole Loopctl.Knowledge.VectorSearch module is exempt (its home)" do
      # Same forbidden shape as above, but the file IS the helper module → no issue.
      """
      defmodule Loopctl.Knowledge.VectorSearch do
        import Ecto.Query

        def candidate_pool_query(tenant_id, target) do
          from(a in Article,
            where: a.tenant_id == ^tenant_id,
            order_by: [asc: fragment("? <=> ?", a.embedding, ^target)]
          )
        end
      end
      """
      |> to_source_file("lib/loopctl/knowledge/vector_search.ex")
      |> run_check(CosineQueryReintroduction)
      |> refute_issues()
    end

    test "a registered exception (Loopctl.Knowledge.do_distant_pairs/7) is exempt" do
      # The EXACT registered {module, fun, arity}: Loopctl.Knowledge.do_distant_pairs/7.
      """
      defmodule Loopctl.Knowledge do
        import Ecto.Query

        defp do_distant_pairs(tenant_id, min_d, max_d, limit, offset, bridge?, vis) do
          from(a in Article,
            join: b in Article,
            on: a.id < b.id,
            where: fragment("(? <=> ?) BETWEEN ? AND ?", a.embedding, b.embedding, ^min_d, ^max_d)
          )
        end
      end
      """
      |> to_source_file("lib/loopctl/knowledge.ex")
      |> run_check(CosineQueryReintroduction)
      |> refute_issues()
    end

    test "a registered exception (Loopctl.Knowledge.novelty_distance_query/4) is exempt" do
      """
      defmodule Loopctl.Knowledge do
        import Ecto.Query

        def novelty_distance_query(tenant_id, embedding, prior_tag, vis) do
          from(a in Article,
            where: a.tenant_id == ^tenant_id,
            select: fragment("MIN(? <=> ?::vector)", a.embedding, ^embedding)
          )
        end
      end
      """
      |> to_source_file("lib/loopctl/knowledge.ex")
      |> run_check(CosineQueryReintroduction)
      |> refute_issues()
    end

    test "the SAME function name but the WRONG arity is NOT exempt (the allowlist is mfa-keyed)" do
      # do_distant_pairs registered at /7; a /2 with the same name is a different fn and
      # must be flagged — proving the allowlist matches on arity, not just name.
      """
      defmodule Loopctl.Knowledge do
        import Ecto.Query

        defp do_distant_pairs(tenant_id, target) do
          from(a in Article,
            where: a.tenant_id == ^tenant_id,
            order_by: fragment("? <=> ?", a.embedding, ^target)
          )
        end
      end
      """
      |> to_source_file("lib/loopctl/knowledge.ex")
      |> run_check(CosineQueryReintroduction)
      |> assert_issue(fn issue ->
        assert issue.message =~ "Loopctl.Knowledge.do_distant_pairs/2"
      end)
    end

    test "the registered name in a DIFFERENT module is NOT exempt (allowlist is module-keyed)" do
      # novelty_distance_query/4 is registered for Loopctl.Knowledge ONLY; the same
      # name+arity in another module is a fresh hand-rolled site and must be flagged.
      """
      defmodule Some.Other.Module do
        import Ecto.Query

        def novelty_distance_query(tenant_id, embedding, prior_tag, vis) do
          from(a in Article, select: fragment("MIN(? <=> ?::vector)", a.embedding, ^embedding))
        end
      end
      """
      |> to_source_file("lib/some/other/module.ex")
      |> run_check(CosineQueryReintroduction)
      |> assert_issue(fn issue ->
        assert issue.message =~ "Some.Other.Module.novelty_distance_query/4"
      end)
    end
  end

  describe "precision — documentation/data `<=>` is NOT a query (no false positives)" do
    test "a `<=>` in a @moduledoc / @doc / comment / data string is not flagged" do
      """
      defmodule My.Documented do
        @moduledoc "Discusses the cosine `<=>` operator at length."

        @exceptions [%{rationale: "uses ? <=> ? in a self-join"}]

        @doc "Returns nothing. Mentions ? <=> ? only in prose."
        def noop do
          # a <=> b would be a cosine distance, but this is a comment
          _regex = ~r/\\? <=> \\?/
          :ok
        end
      end
      """
      |> to_source_file("lib/my/documented.ex")
      |> run_check(CosineQueryReintroduction)
      |> refute_issues()
    end

    test "a non-SQL function call whose string arg contains `<=>` is not flagged" do
      # Only fragment/query!/query/explain calls bear SQL. A plain IO.puts of a string
      # that happens to contain `<=>` is documentation/logging, not a query.
      """
      defmodule My.Logger do
        def log do
          IO.puts("computed ? <=> ? distance")
        end
      end
      """
      |> to_source_file("lib/my/logger.ex")
      |> run_check(CosineQueryReintroduction)
      |> refute_issues()
    end
  end

  describe "REGRESSION — every real lib distance-token file passes the check (TC-27.8.4)" do
    # The SAME distance tokens the check itself scans for. Kept in sync deliberately: if the
    # check learns a new spelling, this discovery must learn it too (else a new family of
    # hand-rolled distance query could land in a file this guard never inspects).
    @distance_tokens ["<=>", "<->", "<#>", "cosine_distance(", "l2_distance(", "inner_product("]

    # DISCOVERED at compile time: every lib/ source that textually carries ANY distance token
    # (real query, or doc/comment prose). Computed, not hardcoded, so a NEW cosine-bearing file
    # is automatically pulled into the per-file check below.
    @lib_distance_files Path.wildcard("lib/**/*.ex")
                        |> Enum.filter(fn p ->
                          src = File.read!(p)
                          Enum.any?(@distance_tokens, &String.contains?(src, &1))
                        end)
                        |> Enum.sort()

    # The ALLOWLISTED set of files permitted to carry a distance token today, each annotated.
    # A diff to this list is a visible, reviewable decision — exactly the tripwire that closes
    # the documented var-pipe residual at FILE granularity: a `<=>` literal assembled into a
    # variable still lands its string in the file, so a NEW file carrying it expands the
    # discovered set and trips the set-equality test, forcing review even though the per-site
    # check (which needs a literal AT the call) can't see it.
    @allowed_distance_files [
                              # real cosine query sites:
                              "lib/loopctl/knowledge.ex",
                              "lib/loopctl/knowledge/vector_search.ex",
                              # US-28.2 agent-memory HNSW recall (Memory.memory_candidate_query/4,
                              # registered in CosineLintExceptions — same index-safe shape as
                              # VectorSearch but bound to the Memory schema):
                              "lib/loopctl/memory.ex",
                              # registry rationale strings quote the operators (data, not query):
                              "lib/loopctl/knowledge/cosine_lint_exceptions.ex",
                              # doc-only tokens (a `<->` arrow in prose / a `<=>` inside a comment):
                              "lib/loopctl/knowledge/okf.ex",
                              "lib/loopctl/workers/article_linking_worker.ex"
                            ]
                            |> Enum.sort()

    test "every lib file carrying a distance token reports ZERO issues (helper + registered + docs exempt)" do
      # Covers the real cosine sites AND the doc-only files: a real hand-rolled query later
      # added to ANY of them (e.g. okf.ex / the worker) would be flagged, because only
      # VectorSearch + the registered fns are exempt — doc prose is not.
      for path <- @lib_distance_files do
        path
        |> File.read!()
        |> to_source_file(path)
        |> run_check(CosineQueryReintroduction)
        |> refute_issues()
      end
    end

    test "the discovered distance-token file set EQUALS the reviewed allowlist (file-set tripwire)" do
      # Set-equality (not subset): a NEW file carrying a distance token trips this (review it —
      # route a real query through VectorSearch or register it; if doc-only, add it here with a
      # note). Removal also trips it (the regression could have gone vacuous). This is the coarse
      # backstop for the var-pipe residual that the per-site AST check structurally cannot catch.
      assert @lib_distance_files == @allowed_distance_files,
             "lib distance-token files drifted from the reviewed allowlist.\n" <>
               "  discovered: #{inspect(@lib_distance_files)}\n" <>
               "  allowed:    #{inspect(@allowed_distance_files)}\n" <>
               "A new file here means a hand-rolled distance op (or a var-assembled cosine SQL " <>
               "string) landed outside VectorSearch — route it through the helper / register it, " <>
               "or (if it's doc-only) add it to @allowed_distance_files with a one-line reason."
    end

    test "at least one allowed file genuinely CONTAINS a real `<=>` (the regression isn't vacuous)" do
      assert Enum.any?(@allowed_distance_files, fn path -> File.read!(path) =~ "<=>" end)
    end
  end

  describe "WIRING — the check is actually enabled in .credo.exs and not inline-disabled (E1/DISABLE-1)" do
    @credo_config File.read!(".credo.exs")

    test "`.credo.exs` ENABLES the cosine check and REQUIRES both its source + the registry (E1)" do
      # If a future edit drops the check from the enabled set or stops `requires:`-ing it, the
      # guard silently stops running (`mix credo --strict` would pass without it). Pin both.
      assert @credo_config =~ "Loopctl.Credo.Check.CosineQueryReintroduction",
             "the cosine reintroduction check is no longer listed in .credo.exs — it must stay " <>
               "in the enabled `checks` so `mix credo --strict` runs it on every PR"

      assert @credo_config =~ ".credo/checks/cosine_query_reintroduction.ex",
             "`.credo.exs` must `require` the out-of-lib check source (it lives outside lib/ so " <>
               "it isn't auto-compiled; dropping the require makes the check a no-op)"

      assert @credo_config =~ "lib/loopctl/knowledge/cosine_lint_exceptions.ex",
             "`.credo.exs` must `require` the allowlist registry — the check reads it at load " <>
               "time and fails-closed (:nofile) without it (DISPROVED architect F2; load-bearing)"
    end

    test "no lib/ source DISABLES the cosine check inline (DISABLE-1)" do
      # A `# credo:disable-...CosineQueryReintroduction` (named) OR a blanket file-level disable
      # in one of the cosine-bearing files would silently re-open the regression. Forbid both.
      named_disables =
        Path.wildcard("lib/**/*.ex")
        |> Enum.filter(fn p ->
          src = File.read!(p)
          src =~ ~r/credo:disable[^\n]*CosineQueryReintroduction/
        end)

      assert named_disables == [],
             "found an inline `credo:disable` targeting the cosine check in: " <>
               "#{inspect(named_disables)} — that re-opens the #168/#170/#172 regression silently. " <>
               "Register a real exception in CosineLintExceptions instead."

      blanket_disables_in_cosine_files =
        @allowed_distance_files
        |> Enum.filter(fn p ->
          # a disable with NO check name (directive ENDS the line) disables ALL checks — incl.
          # ours — for that file/line. A NAMED one (`… this-file Credo.Check.X`) is fine: the
          # check name follows, so `\s*$` won't match. `/m` makes `$` an end-of-LINE anchor.
          File.read!(p) =~ ~r/credo:disable-for-(this-file|next-line|lines:\d+)\s*$/m
        end)

      assert blanket_disables_in_cosine_files == [],
             "found a blanket (un-named) `credo:disable` in a cosine-bearing file: " <>
               "#{inspect(blanket_disables_in_cosine_files)} — it would disable the cosine guard " <>
               "too. Scope the disable to the specific unrelated check by name."
    end
  end
end
