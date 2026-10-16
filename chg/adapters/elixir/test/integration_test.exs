defmodule ChgAdapter.IntegrationTest do
  # Builds this adapter as an archive, installs it into a private MIX_ARCHIVES, and runs
  # every `mix chg.*` task in a git copy of fixtures/sample, as a product repo would.
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 600_000

  @fixture Path.expand("../fixtures/sample", __DIR__)

  setup_all do
    root = Path.join(System.tmp_dir!(), "chg-adapter-it-#{System.unique_integer([:positive])}")
    archives = Path.join(root, "archives")
    ez = Path.join(root, "chg_adapter.ez")
    File.mkdir_p!(archives)
    on_exit(fn -> File.rm_rf!(root) end)

    {_, 0} = sh("mix", ["archive.build", "-o", ez], File.cwd!(), [{"MIX_ENV", "prod"}])

    {_, 0} =
      sh("mix", ["archive.install", ez, "--force"], File.cwd!(), [{"MIX_ARCHIVES", archives}])

    %{root: root, archives: archives}
  end

  setup %{root: root, archives: archives} do
    dir = Path.join(root, "ws-#{System.unique_integer([:positive])}")
    File.cp_r!(@fixture, dir)
    File.cp!(Path.expand("../.tool-versions", __DIR__), Path.join(dir, ".tool-versions"))
    git!(dir, ["init", "-q"])

    git!(dir, [
      "add",
      "mix.exs",
      ".formatter.exs",
      ".gitignore",
      ".tool-versions",
      ".chg",
      "config",
      "lib",
      "priv",
      "test"
    ])

    git!(dir, ["commit", "-qm", "fixture"])
    %{dir: dir, archives: archives, base: git!(dir, ["rev-parse", "HEAD"])}
  end

  defp sh(cmd, args, dir, env) do
    # The parent `mix test` exports MIX_ENV=test; the child must choose its own.
    env = [{"MIX_ENV", nil}, {"MIX_BUILD_PATH", nil} | env]
    System.cmd(cmd, args, cd: dir, env: env, stderr_to_stdout: false)
  end

  defp git!(dir, args) do
    {out, 0} =
      System.cmd(
        "git",
        ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false" | args],
        cd: dir,
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  # Runs a task and returns {document, exit status}; the document is the last stdout line.
  defp chg(ctx, args) do
    {out, status} = sh("mix", args, ctx.dir, [{"MIX_ARCHIVES", ctx.archives}])
    line = out |> String.split("\n", trim: true) |> List.last()
    {JSON.decode!(line), status}
  end

  defp edit!(ctx, path, fun) do
    full = Path.join(ctx.dir, path)
    File.write!(full, fun.(File.read!(full)))
  end

  defp snapshot!(ctx) do
    assert {%{"work" => work}, 0} = chg(ctx, ["chg.snapshot"])
    work
  end

  test "snapshot builds once, then does no work in under 10 s", ctx do
    assert snapshot!(ctx) == "full"
    started = System.monotonic_time(:millisecond)
    assert snapshot!(ctx) == "none"
    assert System.monotonic_time(:millisecond) - started < 10_000

    edit!(ctx, "lib/sample/reports.ex", &String.replace(&1, "Enum.sum(xs)", "Enum.sum(xs) + 0"))
    git!(ctx.dir, ["commit", "-qam", "reports"])
    assert snapshot!(ctx) == "incremental"
    assert snapshot!(ctx) == "none"
  end

  test "affected selects a context's tests and its dependents' tests, and nothing unrelated",
       ctx do
    snapshot!(ctx)

    edit!(
      ctx,
      "lib/sample/accounts.ex",
      &String.replace(&1, "def name(id)", "def other, do: 1\n  def name(id)")
    )

    git!(ctx.dir, ["commit", "-qam", "accounts"])

    assert {%{"mode" => "subset", "tests" => tests}, 0} =
             chg(ctx, ["chg.affected", "--base", ctx.base])

    assert tests == ["test/sample/accounts_test.exs", "test/sample/billing_test.exs"]
  end

  test "affected follows external resources and deleted sources", ctx do
    snapshot!(ctx)
    File.write!(Path.join(ctx.dir, "priv/greeting.txt"), "bye\n")

    assert {%{"tests" => ["test/sample/greeting_test.exs"]}, 0} =
             chg(ctx, ["chg.affected", "--base", "HEAD"])

    git!(ctx.dir, ["checkout", "-q", "priv/greeting.txt"])
    git!(ctx.dir, ["rm", "-q", "lib/sample/reports.ex"])

    assert {%{"tests" => ["test/sample/reports_test.exs"]}, 0} =
             chg(ctx, ["chg.affected", "--base", "HEAD"])
  end

  test "affected without a snapshot's reference cache selects everything", ctx do
    assert {%{"mode" => "all", "reason" => reason}, 0} =
             chg(ctx, ["chg.affected", "--base", "HEAD"])

    assert reason =~ "no test reference cache"
  end

  test "run reports each test, and exits 1 exactly when one failed or a path is missing", ctx do
    list = Path.join(ctx.dir, "tests.txt")
    File.write!(list, "test/sample/billing_test.exs\ntest/sample/reports_test.exs\n")

    assert {%{"results" => results}, 0} = chg(ctx, ["chg.run", "--tests", list])

    assert Enum.sort(Enum.map(results, &{&1["id"], &1["status"]})) == [
             {"test/sample/billing_test.exs:3", "pass"},
             {"test/sample/reports_test.exs:3", "pass"},
             {"test/sample/reports_test.exs:5", "skip"}
           ]

    edit!(ctx, "lib/sample/billing.ex", &String.replace(&1, "invoice for ", "INVOICE "))
    assert {%{"results" => results}, 1} = chg(ctx, ["chg.run", "--tests", list])

    assert Enum.any?(
             results,
             &match?(%{"id" => "test/sample/billing_test.exs:3", "status" => "fail"}, &1)
           )

    File.write!(list, "test/sample/nope_test.exs\n")
    assert {%{"results" => [%{"status" => "error"}]}, 1} = chg(ctx, ["chg.run", "--tests", list])
  end

  test "shards are disjoint and together cover the suite", ctx do
    ids =
      for i <- 1..3, reduce: [] do
        acc ->
          assert {%{"results" => results}, 0} =
                   chg(ctx, ["chg.shard", "--of", "3", "--index", "#{i}"])

          acc ++ Enum.map(results, & &1["id"])
      end

    assert Enum.sort(ids) == Enum.uniq(Enum.sort(ids))
    assert length(ids) == 5
  end

  test "static passes a clean change and reports format and compile failures", ctx do
    assert {%{"ok" => true, "failures" => []}, 0} = chg(ctx, ["chg.static", "--base", "HEAD"])

    edit!(
      ctx,
      "lib/sample/reports.ex",
      &String.replace(
        &1,
        "def total(xs), do: Enum.sum(xs)",
        "def total(xs),   do: Enum.sum(xs)\n  def unused(y), do: 1"
      )
    )

    assert {%{"ok" => false, "failures" => failures}, 1} =
             chg(ctx, ["chg.static", "--base", "HEAD"])

    checks = Enum.map(failures, &{&1["check"], &1["file"]})
    assert {"format", "lib/sample/reports.ex"} in checks
    assert {"compile", "lib/sample/reports.ex"} in checks
  end

  describe "through chg" do
    setup do
      case System.get_env("CHG_BIN") do
        nil ->
          if System.get_env("CI"),
            do: flunk("CHG_BIN is unset in CI; build chg and point CHG_BIN at it")

          :ok

        bin ->
          %{chg_bin: bin}
      end
    end

    test "an always_all path selects everything, a lib edit selects a subset", ctx do
      if bin = ctx[:chg_bin] do
        run = fn ->
          {out, 0} =
            System.cmd(bin, ["adapter", "exec", "affected", "--base", "HEAD", "--repo", ctx.dir],
              env: [{"MIX_ENV", nil}, {"MIX_ARCHIVES", ctx.archives}]
            )

          JSON.decode!(out)
        end

        assert {_, 0} =
                 System.cmd(bin, ["adapter", "exec", "snapshot", "--repo", ctx.dir],
                   env: [{"MIX_ENV", nil}, {"MIX_ARCHIVES", ctx.archives}]
                 )

        edit!(ctx, "lib/sample/reports.ex", &(&1 <> "\n"))
        assert %{"mode" => "subset", "tests" => ["test/sample/reports_test.exs"]} = run.()

        edit!(ctx, "config/runtime.exs", &(&1 <> "\n"))

        assert %{"mode" => "all", "reason" => "config/runtime.exs matches always_all `config/**`"} =
                 run.()
      end
    end
  end
end
