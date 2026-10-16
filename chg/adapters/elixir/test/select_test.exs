defmodule ChgAdapter.SelectTest do
  use ExUnit.Case, async: true

  alias ChgAdapter.{Graph, Select}

  # Accounts <- Billing <- Invoices (runtime references); Reports stands alone;
  # Greeting reads priv/greeting.txt.
  @graph %Graph{
    source_modules: %{
      "lib/accounts.ex" => [Accounts],
      "lib/billing.ex" => [Billing],
      "lib/invoices.ex" => [Invoices],
      "lib/reports.ex" => [Reports],
      "lib/greeting.ex" => [Greeting]
    },
    external: %{"priv/greeting.txt" => ["lib/greeting.ex"]},
    dependents: %{Accounts => [Billing], Billing => [Invoices]}
  }

  @tests %{
    "test/accounts_test.exs" => [Accounts],
    "test/billing_test.exs" => [Billing],
    "test/invoices_test.exs" => [Invoices, ExUnit.Case],
    "test/reports_test.exs" => [Reports],
    "test/greeting_test.exs" => [Greeting]
  }

  defp select(changed, opts \\ []) do
    refs = %{
      tests: Keyword.get(opts, :tests, @tests),
      source_modules: Keyword.get(opts, :snapshot_sources, @graph.source_modules),
      external: Keyword.get(opts, :snapshot_external, @graph.external)
    }

    Select.run(%{
      changed: changed,
      since_snapshot: Keyword.get(opts, :since_snapshot, []),
      graph: Keyword.get(opts, :graph, @graph),
      refs: refs,
      test_files: Map.keys(refs.tests),
      test_file?: &String.ends_with?(&1, "_test.exs"),
      exists?: fn p -> p not in Keyword.get(opts, :deleted, []) end
    })
  end

  defp tests({:subset, _reason, tests}), do: tests

  test "a context edit selects its tests and its dependents' tests, transitively, and nothing else" do
    assert tests(select(["lib/accounts.ex"])) ==
             ["test/accounts_test.exs", "test/billing_test.exs", "test/invoices_test.exs"]
  end

  test "a leaf edit selects only its own tests" do
    assert tests(select(["lib/invoices.ex"])) == ["test/invoices_test.exs"]
  end

  test "an external resource maps to the modules that read it" do
    assert tests(select(["priv/greeting.txt"])) == ["test/greeting_test.exs"]
  end

  test "a deleted external resource maps through the snapshot's record" do
    graph = %{@graph | external: %{}}

    assert tests(select(["priv/greeting.txt"], graph: graph, deleted: ["priv/greeting.txt"])) ==
             ["test/greeting_test.exs"]
  end

  test "a changed test file is selected for itself" do
    assert tests(select(["test/reports_test.exs"])) == ["test/reports_test.exs"]
  end

  test "test files changed since the snapshot are selected: their references may be stale" do
    assert tests(select([], since_snapshot: ["test/greeting_test.exs", "lib/x.ex"])) ==
             ["test/greeting_test.exs"]
  end

  test "a test file without recorded references is always selected" do
    tests = Map.put(@tests, "test/new_test.exs", :unknown)
    assert tests(select([], tests: tests)) == ["test/new_test.exs"]
  end

  test "a deleted source maps through the snapshot's module map" do
    graph = %{@graph | source_modules: Map.delete(@graph.source_modules, "lib/reports.ex")}

    assert tests(select(["lib/reports.ex"], graph: graph, deleted: ["lib/reports.ex"])) ==
             ["test/reports_test.exs"]
  end

  test "a deleted source the snapshot does not know fails closed" do
    assert {:all, reason} = select(["lib/gone.ex"], deleted: ["lib/gone.ex"])
    assert reason =~ "lib/gone.ex"
  end

  test "paths outside the module graph select nothing and are counted" do
    assert {:subset, reason, []} = select(["README.md", "assets/app.js"])
    assert reason =~ "2 path(s) outside the module graph"
  end
end
