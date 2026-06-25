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
        assert issue.trigger == "<=>"
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

  describe "REGRESSION — the real lib/loopctl cosine sites all pass (TC-27.8.4)" do
    @real_cosine_files [
      "lib/loopctl/knowledge/vector_search.ex",
      "lib/loopctl/knowledge.ex",
      "lib/loopctl/knowledge/cosine_lint_exceptions.ex"
    ]

    test "every real cosine-bearing lib file reports ZERO issues (helper + registered exempt)" do
      for path <- @real_cosine_files do
        source = File.read!(path)

        source
        |> to_source_file(path)
        |> run_check(CosineQueryReintroduction)
        |> refute_issues()
      end
    end

    test "the real files genuinely CONTAIN `<=>` (the regression test isn't vacuous)" do
      # Guard against a future refactor that removes all `<=>` from these files and
      # makes the zero-issue assertion meaningless: at least one real file must still
      # carry the operator (in a fragment), so the exemption is actually exercised.
      assert Enum.any?(@real_cosine_files, fn path ->
               File.read!(path) =~ "<=>"
             end)
    end
  end
end
