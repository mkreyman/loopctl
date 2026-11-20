defmodule ChgAdapter.SelectTest do
  use ExUnit.Case, async: true

  alias ChgAdapter.{Graph, Select}

  # Accounts <- Billing <- Invoices (runtime references), and Invoices expands a Billing
  # struct at compile time; Reports stands alone; Greeting reads priv/greeting.txt; Boot
  # runs at application start.
  @graph %Graph{
    source_modules: %{
      "lib/accounts.ex" => [Accounts],
      "lib/billing.ex" => [Billing],
      "lib/invoices.ex" => [Invoices],
      "lib/reports.ex" => [Reports],
      "lib/greeting.ex" => [Greeting],
      "lib/boot.ex" => [Boot]
    },
    external: %{"priv/greeting.txt" => ["lib/greeting.ex"]},
    dependents: %{Accounts => [Billing], Billing => [Invoices]},
    compile_dependents: %{Billing => [Invoices]}
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
      exists?: fn p -> p not in Keyword.get(opts, :deleted, []) end,
      read: Keyword.get(opts, :read, [])
    })
  end

  defp tests({:subset, _reason, tests}), do: tests

  test "a path read at run time selects everything without a coverage record" do
    assert {:all, reason} = select(["docs/a.md"], read: ["docs/a.md"])
    assert reason =~ "docs/a.md is read at run time"
  end

  test "the reason gives each selected file one cause, so the counts add up to the selection" do
    tests = Map.put(@tests, "test/new_test.exs", nil)

    assert {:subset, reason, selected} =
             select(["test/billing_test.exs", "lib/invoices.ex"],
               since_snapshot: [
                 "test/billing_test.exs",
                 "test/greeting_test.exs",
                 "test/gone_test.exs"
               ],
               tests: tests
             )

    assert selected == [
             "test/billing_test.exs",
             "test/greeting_test.exs",
             "test/invoices_test.exs",
             "test/new_test.exs"
           ]

    assert reason =~
             "4 of 6 test file(s): 1 changed since the base, 1 since the snapshot, " <>
               "1 without recorded references, 1 referencing an affected module"
  end

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
      global: [Boot],
      # Greeting lists docs/stories; Reports reads one file; Invoices runs a subprocess;
      # boot reads config.json.
      reads: %{
        "test/accounts_test.exs" => [],
        "test/billing_test.exs" => [],
        "test/invoices_test.exs" => [{:spawn, "git"}, "lib/invoices.ex"],
        "test/reports_test.exs" => ["docs/reports.md"],
        "test/greeting_test.exs" => ["docs/stories/", "docs/stories/a.json"]
      },
      global_reads: ["docs/config.json", ".", "docs"]
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
        impl?: &(&1 in Keyword.get(opts, :impls, [])),
        read: Keyword.get(opts, :read, []),
        not_read_by: Keyword.get(opts, :not_read_by, [])
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

    test "a digest that differs with nothing changed that can reach it alters nothing" do
      # Two compiles of one commit: map-ordered code comes out reordered.
      flapped = now(%{Reports => "r2", Greeting => "g2", Boot => "x2"})
      assert {:subset, reason, []} = cover([], flapped)
      assert reason =~ "0 module(s) compared, 0 altered module(s)"

      # lib/accounts.ex changed: Billing and Invoices reach Accounts, and Invoices expands
      # Billing at compile time, so Accounts and Invoices are compared and Invoices is
      # altered; the flapped Reports, Greeting and Boot are not compared.
      assert {:subset, reason, tests} =
               cover(["lib/accounts.ex"], Map.put(flapped, Invoices, "i2"))

      assert reason =~ "2 module(s) compared, 1 altered module(s)"
      assert tests == ["test/invoices_test.exs"]
    end

    test "a module reached only at run time is not compared, one reached at compile time is" do
      # Invoices references Accounts only through Billing at run time: a changed Accounts
      # cannot change Billing's code, so a flapped Billing is no evidence.
      graph = %{@graph | compile_dependents: %{}}

      assert tests(
               Select.by_coverage(%{
                 changed: ["lib/accounts.ex"],
                 since_record: [],
                 record: @record,
                 digests: now(%{Billing => "b2"}),
                 graph: graph,
                 test_files: Map.keys(@record.cover),
                 test_file?: &String.ends_with?(&1, "_test.exs"),
                 test_path?: &String.starts_with?(&1, "test/"),
                 impl?: fn _ -> false end,
                 read: [],
                 not_read_by: []
               })
             ) == []

      # With Invoices expanding Billing at compile time, a changed Accounts reaches
      # Invoices' code through Billing, so Invoices is compared and its digest counts.
      assert tests(cover(["lib/accounts.ex"], now(%{Invoices => "i2"}))) ==
               ["test/invoices_test.exs"]
    end

    test "a deleted module's compile dependents are compared" do
      # lib/accounts.ex no longer defines Legacy; Reports checked for it at compile time
      # (`Code.ensure_loaded?(Legacy)` in its body), so Mix recompiled it.
      record = %{
        @record
        | digests: Map.put(@record.digests, Legacy, "l1"),
          cover: Map.put(@record.cover, "test/legacy_test.exs", [Legacy])
      }

      graph = %{
        @graph
        | compile_dependents: Map.put(@graph.compile_dependents, Legacy, [Reports])
      }

      assert {:subset, _, tests} =
               Select.by_coverage(%{
                 changed: ["lib/accounts.ex"],
                 since_record: [],
                 record: record,
                 digests: now(%{Reports => "r2"}),
                 graph: graph,
                 test_files: Map.keys(record.cover),
                 test_file?: &String.ends_with?(&1, "_test.exs"),
                 test_path?: &String.starts_with?(&1, "test/"),
                 impl?: fn _ -> false end,
                 read: [],
                 not_read_by: []
               })

      assert tests == ["test/legacy_test.exs", "test/reports_test.exs"]
    end

    test "a changed source the module graph does not map compares every digest" do
      # A macro in an in-repo path dependency, a script, an undeclared template.
      for p <- ["shared/lib/shared.ex", "priv/repo/seeds.exs", "lib/web/page.html.heex"] do
        assert {:subset, reason, tests} = cover([p], now(%{Reports => "r2"}))
        assert reason =~ "every module compared (#{p} changed)"
        assert tests == ["test/reports_test.exs"]
      end

      # An external resource a module declares stays gated: only its readers are compared.
      assert {:subset, reason, _} = cover(["priv/greeting.txt"], now(%{Reports => "r2"}))
      assert reason =~ "1 module(s) compared"
    end

    test "config, deps or the toolchain changed: every digest is compared" do
      for p <- ["config/config.exs", "mix.lock", "mix.exs", ".tool-versions", "deps/x/lib/x.ex"] do
        assert {:subset, reason, tests} = cover([p], now(%{Reports => "r2"}))
        assert reason =~ "every module compared (#{p} changed)"
        assert tests == ["test/reports_test.exs"]
      end
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

    test "a path read at run time selects its readers, a directory's listers and spawners" do
      assert tests(cover(["docs/reports.md"], now(%{}), read: ["docs/reports.md"])) ==
               ["test/invoices_test.exs", "test/reports_test.exs"]

      # A new file under a listed directory, changed since the record only.
      assert tests(
               cover([], now(%{}),
                 since_record: ["docs/stories/b/new.json"],
                 read: ["docs/stories/b/new.json"]
               )
             ) ==
               ["test/greeting_test.exs", "test/invoices_test.exs"]

      # A sibling whose name shares a prefix is not under the directory, and a directory
      # read but not listed (a stat, here of the root and of docs at boot) is not either.
      assert tests(cover(["docs/stories2.md"], now(%{}), read: ["docs/stories2.md"])) ==
               ["test/invoices_test.exs"]

      assert {:all, _} =
               cover(["docs/x.md"], now(%{}),
                 record: %{@record | global_reads: ["./"]},
                 read: ["docs/x.md"]
               )
    end

    test "a path read at run time under the test paths is not test data" do
      read = ["test/fixtures/claim.json"]
      assert tests(cover(read, now(%{}), read: read)) == ["test/invoices_test.exs"]
    end

    test "a path read outside any one test file, or a subprocess there, selects everything" do
      assert {:all, reason} = cover(["docs/config.json"], now(%{}), read: ["docs/config.json"])
      assert reason =~ "docs/config.json was read outside any one test file"

      record = %{@record | global_reads: [{:spawn, "chrome"}]}
      assert {:all, reason} = cover(["docs/x.md"], now(%{}), record: record, read: ["docs/x.md"])
      assert reason =~ "a subprocess (chrome) started outside any one test file"
      assert tests(cover(["lib/reports.ex"], now(%{}), record: record)) == []
    end

    test "a subprocess the manifest says reads no such path (not_read_by) is no read" do
      record = %{@record | global_reads: [{:spawn, "mix"}]}

      assert tests(
               cover(["docs/reports.md"], now(%{}),
                 record: record,
                 read: ["docs/reports.md"],
                 not_read_by: ["mix", "git"]
               )
             ) == ["test/reports_test.exs"]

      assert {:all, reason} =
               cover(["docs/reports.md"], now(%{}),
                 record: record,
                 read: ["docs/reports.md"],
                 not_read_by: ["git"]
               )

      assert reason =~ "a subprocess (mix) started"
    end

    test "a caller and a record from before read_at_runtime still select by coverage" do
      record = Map.drop(@record, [:reads, :global_reads])

      input = %{
        changed: ["lib/accounts.ex"],
        since_record: [],
        record: record,
        digests: now(%{Accounts => "a2"}),
        graph: @graph,
        test_files: Map.keys(record.cover),
        test_file?: &String.ends_with?(&1, "_test.exs"),
        test_path?: &String.starts_with?(&1, "test/"),
        impl?: fn _ -> false end
      }

      assert tests(Select.by_coverage(input)) == [
               "test/accounts_test.exs",
               "test/billing_test.exs"
             ]
    end

    test "a test file the record has no reads for is selected by a path read at run time" do
      record = %{@record | reads: Map.delete(@record.reads, "test/accounts_test.exs")}

      assert tests(cover(["docs/none.md"], now(%{}), record: record, read: ["docs/none.md"])) ==
               ["test/accounts_test.exs", "test/invoices_test.exs"]
    end

    test "a module that ran outside any one test file (global) selects everything" do
      assert {:all, reason} = cover(["lib/boot.ex"], now(%{Boot => "x2"}))
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
