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

  describe "by_coverage" do
    # The record: what each test file executed at an earlier commit, and every module's
    # digest there. Billing calls Accounts; Invoices only uses Billing's struct (so it
    # never calls Billing, and only Billing's digest changing tells us).
    @record %{
      sha: String.duplicate("a", 40),
      age: 2,
      digests: %{
        Accounts => "a1",
        Billing => "b1",
        Invoices => "i1",
        Reports => "r1",
        Greeting => "g1",
        Boot => "x1"
      },
      cover: %{
        "test/accounts_test.exs" => [Accounts],
        "test/billing_test.exs" => [Billing, Accounts],
        "test/invoices_test.exs" => [Invoices],
        "test/reports_test.exs" => [Reports],
        "test/greeting_test.exs" => [Greeting]
      },
      global: [Boot]
    }

    defp cover(changed, digests, opts \\ []) do
      record = Keyword.get(opts, :record, @record)

      Select.by_coverage(%{
        changed: changed,
        since_record: Keyword.get(opts, :since_record, []),
        record: record,
        digests: digests,
        graph: @graph,
        test_files: Keyword.get(opts, :test_files, Map.keys(record.cover)),
        test_file?: &String.ends_with?(&1, "_test.exs"),
        test_path?: &String.starts_with?(&1, "test/"),
        impl?: &(&1 in Keyword.get(opts, :impls, []))
      })
    end

    defp now(changes), do: Map.merge(@record.digests, Map.new(changes))

    test "a module whose code changed selects the files that executed it, and no others" do
      assert tests(cover(["lib/accounts.ex"], now(%{Accounts => "a2"}))) ==
               ["test/accounts_test.exs", "test/billing_test.exs"]
    end

    test "a module changed only through compile time is altered by its digest" do
      # A struct default changed in Billing and was expanded into Invoices.
      assert tests(cover(["lib/billing.ex"], now(%{Billing => "b2", Invoices => "i2"}))) ==
               ["test/billing_test.exs", "test/invoices_test.exs"]
    end

    test "a source edit that leaves the compiled code as the record has it alters nothing" do
      # A comment, a line shift, or a revert to the record's code: those tests passed.
      assert tests(cover(["lib/reports.ex"], now(%{}))) == []
    end

    test "an external resource changed since the base or the record alters its readers" do
      assert tests(cover(["priv/greeting.txt"], now(%{}))) == ["test/greeting_test.exs"]

      assert tests(cover([], now(%{}), since_record: ["priv/greeting.txt"])) ==
               ["test/greeting_test.exs"]
    end

    test "test data changed since the record fails closed too" do
      assert {:all, _} = cover([], now(%{}), since_record: ["test/fixtures/claim.json"])
    end

    test "a deleted module selects the files that executed it" do
      assert tests(cover(["lib/greeting.ex"], Map.delete(@record.digests, Greeting))) ==
               ["test/greeting_test.exs"]
    end

    test "a module that ran at boot or while tests compiled selects everything" do
      assert {:all, reason} = cover([], now(%{Boot => "x2"}))
      assert reason =~ "Boot"
    end

    test "a new protocol implementation selects everything; another new module nothing" do
      assert {:all, reason} = cover([], Map.put(@record.digests, Impl, "n"), impls: [Impl])
      assert reason =~ "Impl"
      assert tests(cover([], Map.put(@record.digests, Helper, "n"))) == []
    end

    test "changed tests, tests changed since the record, and tests it lacks are selected" do
      files = ["test/new_test.exs" | Map.keys(@record.cover)]

      assert tests(
               cover(["test/reports_test.exs"], now(%{}),
                 since_record: ["test/greeting_test.exs", "lib/x.ex"],
                 test_files: files
               )
             ) == ["test/greeting_test.exs", "test/new_test.exs", "test/reports_test.exs"]
    end

    test "changed test data fails closed; other paths outside the graph select nothing" do
      assert {:all, reason} = cover(["test/fixtures/claim.json"], now(%{}))
      assert reason =~ "test/fixtures/claim.json"
      assert {:subset, _, []} = cover(["README.md", "assets/app.js"], now(%{}))
    end

    test "the reason names the record and how far behind it is" do
      assert {:subset, reason, _} = cover([], now(%{}))
      assert reason =~ "coverage of aaaaaaaaaaaa (2 commit(s) behind)"
    end
  end
end
