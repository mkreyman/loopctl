defmodule Loopctl.Knowledge.SearchEventCoverageTest do
  @moduledoc """
  The registry is a DECLARATION, so the thing that can silently rot is the bond between it
  and the schema it declares over: a renamed column would leave a profile reporting a
  confident zero for a column that no longer exists. These tests break the BUILD on that,
  and pin the two shapes a coverage report must never get wrong — an unprofiled tool
  vanishing, and a structurally-absent column counted as a defect.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge.SearchEvent
  alias Loopctl.Knowledge.SearchEventCoverage, as: Coverage

  @from ~U[2026-08-13 00:00:00.000000Z]
  @to ~U[2026-08-15 00:00:00.000000Z]
  @at ~U[2026-08-14 10:00:00.000000Z]

  # A fully-covered AGENT row: every declared column non-blank, so any `missing` a test
  # sees came from what that test changed and not from the baseline.
  defp covered(tenant_id, attrs \\ %{}) do
    base = %{
      tenant_id: tenant_id,
      inserted_at: @at,
      query: "a real query",
      tool: "knowledge_search",
      mode_used: "combined",
      result_count: 3,
      duration_ms: 12,
      agent_id: Ecto.UUID.generate(),
      client_session_id: "sess-#{System.unique_integer([:positive])}",
      client_host: "minis",
      client_repo: "loopctl",
      client_entrypoint: "mcp",
      client_version: "1.2.3",
      client_kind: "main",
      client_model: "opus",
      client_effort: "high",
      outcome: "ok"
    }

    fixture(:search_event, Map.merge(base, attrs))
  end

  defp report(tenant_id), do: Coverage.report(tenant_id, @from, @to)

  defp profile(report, tool), do: Enum.find(report.profiles, &(&1.tool == tool))

  describe "the registry" do
    test "declares only columns that exist on the schema" do
      fields = MapSet.new(SearchEvent.__schema__(:fields))
      declared = Coverage.columns() |> Map.keys() |> MapSet.new()

      assert MapSet.size(declared) > 0

      assert MapSet.subset?(declared, fields),
             "undeclarable columns: #{inspect(MapSet.difference(declared, fields))}"
    end

    test "every profile column is declared in the column registry" do
      declared = Coverage.columns() |> Map.keys() |> MapSet.new()

      # An empty registry would make every loop in this describe block assert NOTHING and
      # still report green. Each test anchors its own iteration source for that reason.
      refute Enum.empty?(Coverage.profiles())

      for profile <- Coverage.profiles() do
        used = MapSet.new(profile.required ++ profile.enrichable)
        assert MapSet.size(used) > 0

        assert MapSet.subset?(used, declared),
               "#{profile.tool}: #{inspect(MapSet.difference(used, declared))}"
      end
    end

    test "required and enrichable never overlap within a profile" do
      refute Enum.empty?(Coverage.profiles())

      for profile <- Coverage.profiles() do
        assert MapSet.disjoint?(MapSet.new(profile.required), MapSet.new(profile.enrichable)),
               "#{profile.tool} declares a column as both required and enrichable"
      end
    end

    test "every declared column names one of the three populations" do
      columns = Coverage.columns()
      assert map_size(columns) > 0

      for {column, {scope, test, select_key}} <- columns do
        assert scope in Coverage.scopes(), "#{column} has unknown scope #{inspect(scope)}"
        assert test in [:text, :value], "#{column} has unknown missing-test #{inspect(test)}"

        # The select key is a LITERAL in the registry rather than interpolated at call time,
        # which trades a runtime atom build for a copy-paste hazard: a row pointing at
        # ANOTHER column's count is well-formed and reports a confident wrong number. Pinned
        # by STRING, so the check itself constructs no atom either.
        assert Atom.to_string(select_key) == Atom.to_string(column) <> "_missing",
               "#{column} declares select key #{inspect(select_key)}"
      end
    end

    test "tools are unique, so no profile can shadow another" do
      tools = Coverage.profiled_tools()
      assert tools == Enum.uniq(tools)
      assert length(tools) == length(Coverage.profiles())
    end
  end

  describe "report/3 window" do
    test "refuses an empty, inverted or pre-history window rather than reporting zeros" do
      tenant = fixture(:tenant)

      assert_raise ArgumentError, ~r/from < to/, fn -> Coverage.report(tenant.id, @to, @from) end
      assert_raise ArgumentError, ~r/from < to/, fn -> Coverage.report(tenant.id, @to, @to) end

      before = DateTime.add(Coverage.history_starts(), -1, :second)

      assert_raise ArgumentError, ~r/instrument did not exist/, fn ->
        Coverage.report(tenant.id, before, @to)
      end

      far = DateTime.add(@from, (Coverage.max_window_days() + 1) * 86_400, :second)
      assert_raise ArgumentError, ~r/exceeds/, fn -> Coverage.report(tenant.id, @from, far) end
    end

    test "counts only rows inside [from, to)" do
      tenant = fixture(:tenant)
      covered(tenant.id, %{inserted_at: @from})
      covered(tenant.id, %{inserted_at: @to})

      assert report(tenant.id).rows_total == 1
    end
  end

  describe "report/3 shape" do
    test "every declared profile appears, including one with no rows" do
      tenant = fixture(:tenant)
      covered(tenant.id)

      report = report(tenant.id)

      assert Enum.map(report.profiles, & &1.tool) == Coverage.profiled_tools()

      quiet = profile(report, "knowledge_context")
      assert quiet.rows == 0
      assert quiet.populations == %{all: 0, ran: 0, agent: 0}

      # nil, never 0.0: zero would assert every row carried the column when there were none.
      assert quiet.required[:query].share_missing == nil
      assert quiet.required[:query].population == 0
    end

    test "a fully covered row reports no missing column anywhere" do
      tenant = fixture(:tenant)
      covered(tenant.id)

      searched = profile(report(tenant.id), "knowledge_search")

      assert searched.rows == 1
      assert searched.populations == %{all: 1, ran: 1, agent: 1}

      declared = Enum.find(Coverage.profiles(), &(&1.tool == "knowledge_search"))
      columns = Map.merge(searched.required, searched.enrichable)

      # PIN THE SET THE LOOP ITERATES, against the REGISTRY rather than against itself. A
      # bare `for` over an empty map asserts nothing and still reports green — verified
      # inert with `bin/mutate.sh` (report the columns as `%{}` and this test passed) before
      # this assertion existed. Comparing to the declaration catches that, because the
      # declaration is the thing the report is supposed to be derived FROM.
      assert MapSet.new(Map.keys(columns)) == MapSet.new(declared.required ++ declared.enrichable)

      for {column, stats} <- columns do
        assert stats.missing == 0, "#{column} counted missing on a fully covered row"
        assert stats.share_missing == +0.0
      end
    end

    test "a missing required column is counted with its share" do
      tenant = fixture(:tenant)
      covered(tenant.id)
      covered(tenant.id, %{client_repo: nil, client_kind: nil})

      searched = profile(report(tenant.id), "knowledge_search")

      assert searched.rows == 2
      assert searched.required[:client_repo].missing == 1
      assert searched.required[:client_repo].population == 2
      assert searched.required[:client_repo].share_missing == 0.5

      # Still an agent row: `client_session_id` alone puts it in the agent population, which
      # is what makes a null `client_kind` reportable rather than invisible.
      assert searched.required[:client_kind].missing == 1
      assert searched.required[:client_host].missing == 0
    end

    test "enrichable columns are reported apart from required ones" do
      tenant = fixture(:tenant)
      covered(tenant.id, %{client_model: nil, client_effort: nil})

      searched = profile(report(tenant.id), "knowledge_search")

      refute Map.has_key?(searched.required, :client_model)
      assert searched.enrichable[:client_model].missing == 1
      assert searched.enrichable[:client_effort].share_missing == 1.0

      # `Enum.all?` on an EMPTY map is `true`, so pin the set first or the line below is a
      # green that means nothing. Same defect, same fix as the fully-covered test above.
      declared = Enum.find(Coverage.profiles(), &(&1.tool == "knowledge_search"))
      assert MapSet.new(Map.keys(searched.required)) == MapSet.new(declared.required)
      assert Enum.all?(searched.required, fn {_c, s} -> s.missing == 0 end)
    end

    test "a non-agent row is outside the agent population, so client_* is not scored" do
      tenant = fixture(:tenant)
      # No client_kind and no client_session_id: the recall hook / smoke-test shape, which
      # can never carry client context. Scoring it would measure loopctl's own automation.
      covered(tenant.id, %{
        client_session_id: nil,
        client_kind: nil,
        client_host: nil,
        client_repo: nil,
        client_entrypoint: nil,
        client_version: nil,
        client_model: nil,
        client_effort: nil
      })

      searched = profile(report(tenant.id), "knowledge_search")

      assert searched.rows == 1
      assert searched.populations.agent == 0
      assert searched.required[:client_host].population == 0
      assert searched.required[:client_host].missing == 0
      assert searched.required[:client_host].share_missing == nil
      # The baseline columns are still scored over :all.
      assert searched.required[:query].population == 1
    end

    test "a rejected row is outside the :ran population, so mode_used is not a defect" do
      tenant = fixture(:tenant)

      covered(tenant.id, %{
        outcome: "rejected",
        mode_used: nil,
        duration_ms: nil,
        result_count: 0
      })

      searched = profile(report(tenant.id), "knowledge_search")

      assert searched.rows == 1
      assert searched.populations.ran == 0
      assert searched.required[:mode_used].missing == 0
      assert searched.required[:mode_used].share_missing == nil
      assert searched.required[:duration_ms].missing == 0
    end

    test "knowledge_list drops query, because a browse page has none by construction" do
      tenant = fixture(:tenant)
      covered(tenant.id, %{tool: "knowledge_list", query: nil})

      listed = profile(report(tenant.id), "knowledge_list")

      assert listed.rows == 1
      refute Map.has_key?(listed.required, :query)
      assert Map.has_key?(listed.required, :mode_used)
    end

    test "a blank string counts as missing on a text column" do
      tenant = fixture(:tenant)
      # `cast/4` maps "" to nil, so this lands as NULL; the point is that neither shape is
      # read as coverage.
      covered(tenant.id, %{client_repo: ""})

      searched = profile(report(tenant.id), "knowledge_search")
      assert searched.required[:client_repo].missing == 1
    end
  end

  describe "unprofiled tools" do
    test "a tool with rows and no profile is reported, never dropped" do
      tenant = fixture(:tenant)
      covered(tenant.id)
      covered(tenant.id, %{tool: "corpus_search"})
      covered(tenant.id, %{tool: "corpus_search"})
      covered(tenant.id, %{tool: nil})

      report = report(tenant.id)

      assert report.unprofiled == [
               %{tool: "corpus_search", rows: 2},
               %{tool: nil, rows: 1}
             ]

      # `rows_total` accounts for every row in the window, profiled or not — the invariant
      # that makes a silently-dropped tool detectable.
      assert report.rows_total == 4
      assert Enum.sum(Enum.map(report.profiles, & &1.rows)) == 1
    end

    test "no unprofiled bucket when every row has a profile" do
      tenant = fixture(:tenant)
      covered(tenant.id, %{tool: "memory_recall"})

      assert report(tenant.id).unprofiled == []
    end
  end

  describe "tenant isolation" do
    test "tenant A's report never counts tenant B's rows" do
      a = fixture(:tenant)
      b = fixture(:tenant)

      covered(a.id)
      covered(b.id, %{client_repo: nil})
      covered(b.id, %{tool: "corpus_search"})

      report_a = report(a.id)
      assert report_a.rows_total == 1
      assert report_a.unprofiled == []
      assert profile(report_a, "knowledge_search").required[:client_repo].missing == 0

      report_b = report(b.id)
      assert report_b.rows_total == 2
      assert report_b.unprofiled == [%{tool: "corpus_search", rows: 1}]
      assert profile(report_b, "knowledge_search").required[:client_repo].missing == 1
    end
  end
end
