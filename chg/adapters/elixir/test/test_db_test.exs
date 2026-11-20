defmodule ChgAdapter.TestDbTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias ChgAdapter.TestDb

  @pg Ecto.Adapters.Postgres
  @tree MapSet.new([10, 20, 30])

  defp io(overrides) do
    me = self()

    Map.merge(
      %{
        adapter: fn _ -> @pg end,
        tree: fn _ -> @tree end,
        versions: fn _ -> {:ok, [10, 20, 30]} end,
        drop: fn c ->
          send(me, {:dropped, c[:database]})
          :ok
        end,
        recreates?: true
      },
      Map.new(overrides)
    )
  end

  defp reset(repos, overrides \\ []) do
    with_io(:stderr, fn -> TestDb.reset_ahead(repos, io(overrides)) end)
  end

  @repo {Sample.Repo, [database: "sample_test"]}

  test "a database holding a version the tree lacks is dropped" do
    assert {["sample_test"], err} = reset([@repo], versions: fn _ -> {:ok, [10, 20, 30, 40]} end)
    assert err =~ "sample_test holds migration(s) this tree lacks (40): dropping it"
    assert_received {:dropped, "sample_test"}
  end

  test "a database at or behind the tree is kept" do
    assert {[], ""} = reset([@repo])
    assert {[], ""} = reset([@repo], versions: fn _ -> {:ok, [10]} end)
    refute_received {:dropped, _}
  end

  test "versions older than the tree's oldest migration (a squashed dump) are not ahead" do
    assert {[], ""} = reset([@repo], versions: fn _ -> {:ok, [1, 2, 10, 20, 30]} end)
  end

  test "a tree with no migrations, a repo on another adapter, or no database name is left alone" do
    ahead = [versions: fn _ -> {:ok, [99]} end]
    assert {[], ""} = reset([@repo], [tree: fn _ -> MapSet.new() end] ++ ahead)
    assert {[], ""} = reset([@repo], [adapter: fn _ -> Ecto.Adapters.SQLite3 end] ++ ahead)
    assert {[], ""} = reset([{Sample.Repo, [url: "ecto://x"]}], ahead)
    refute_received {:dropped, _}
  end

  test "a check that cannot run is reported, and nothing is dropped" do
    assert {[], err} =
             reset([@repo], versions: fn _ -> {:error, "password authentication failed"} end)

    assert err =~ "sample_test not checked: password authentication failed"
    refute_received {:dropped, _}
  end

  test "without a setup task before `test`, an ahead database is reported, not dropped" do
    assert {[], err} = reset([@repo], versions: fn _ -> {:ok, [40]} end, recreates?: false)
    assert err =~ "runs nothing before `test` to build it again: not dropped"
    refute_received {:dropped, _}
  end

  test "a failed drop is reported" do
    assert {[], err} =
             reset([@repo],
               versions: fn _ -> {:ok, [40]} end,
               drop: fn _ -> {:error, "in use"} end
             )

    assert err =~ "sample_test not dropped: in use"
  end

  test "the test alias builds the database when it runs a task before `test`" do
    assert TestDb.recreates?(["hcb.setup_test_db", "test"])
    assert TestDb.recreates?(["ecto.create --quiet", "ecto.migrate", "test --cover"])
    refute TestDb.recreates?(["test"])
    refute TestDb.recreates?("test --cover")
    refute TestDb.recreates?(nil)
  end

  test "the tree's versions come from every migrations directory and the repo's own paths" do
    dir = Path.join(System.tmp_dir!(), "chg-test-db-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    for f <- [
          "priv/repo/migrations/20261001000000_a.exs",
          "priv/repo/test_migrations/20261002000000_b.exs",
          "priv/other_repo/migrations/20261003000000_c.exs",
          "priv/custom/migrations/20261004000000_d.exs",
          "db/migrate/20261005000000_e.exs",
          "priv/repo/migrations/README.md",
          "priv/repo/seeds.exs"
        ] do
      path = Path.join(dir, f)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "")
    end

    assert TestDb.tree_versions(dir, []) ==
             MapSet.new([
               20_261_001_000_000,
               20_261_002_000_000,
               20_261_003_000_000,
               20_261_004_000_000
             ])

    assert MapSet.member?(
             TestDb.tree_versions(dir, migrations_paths: ["db/migrate"]),
             20_261_005_000_000
           )
  end

  test "ahead lists the database's versions no tree migration has, sorted" do
    assert TestDb.ahead([3, 1, 2], MapSet.new([1, 2, 3])) == []
    assert TestDb.ahead([9, 1, 2, 3, 7], MapSet.new([1, 2, 3])) == [7, 9]
  end

  test "a product without ecto repos is left alone" do
    assert TestDb.reset_ahead() == []
  end
end
