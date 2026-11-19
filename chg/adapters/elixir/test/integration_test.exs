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
      "apps",
      "config",
      "docs",
      "lib",
      "priv",
      "test"
    ])

    git!(dir, ["commit", "-qm", "fixture"])
    %{dir: dir, root: root, archives: archives, base: git!(dir, ["rev-parse", "HEAD"])}
  end

  # The machine's git config stays out of the fixture's repos, for this test's git calls
  # and every git a task runs: a global core.hooksPath would run the developer's own
  # pre-commit hook on the fixture's commits.
  @isolated_git [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]

  defp sh(cmd, args, dir, env) do
    # The parent `mix test` exports MIX_ENV=test; the child must choose its own.
    env = [{"MIX_ENV", nil}, {"MIX_BUILD_PATH", nil} | @isolated_git] ++ env
    System.cmd(cmd, args, cd: dir, env: env, stderr_to_stdout: false)
  end

  defp git!(dir, args) do
    {out, 0} =
      System.cmd(
        "git",
        ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false" | args],
        cd: dir,
        env: @isolated_git,
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  # Runs a task and returns {document, exit status}; the document is the last stdout line.
  defp chg(ctx, args, env \\ []) do
    {out, status} = sh("mix", args, ctx.dir, [{"MIX_ARCHIVES", ctx.archives} | env])
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
    lock = Path.join(ctx.dir, "mix.lock")
    digest = :crypto.hash(:sha256, if(File.exists?(lock), do: File.read!(lock), else: ""))
    marker = Path.join(ctx.dir, "deps/.chg_lock")
    assert File.read!(marker) == Base.encode16(digest, case: :lower)
    # A snapshot from before the marker gets one without building again.
    File.rm!(marker)
    assert snapshot!(ctx) == "none"
    assert File.exists?(marker)
    started = System.monotonic_time(:millisecond)
    assert snapshot!(ctx) == "none"
    assert System.monotonic_time(:millisecond) - started < 10_000

    edit!(ctx, "lib/sample/reports.ex", &String.replace(&1, "Enum.sum(xs)", "Enum.sum(xs) + 0"))
    git!(ctx.dir, ["commit", "-qam", "reports"])
    assert snapshot!(ctx) == "incremental"
    assert snapshot!(ctx) == "none"
  end

  test "snapshot of the same commit moved to another path compiles again there", ctx do
    # Like Phoenix's embed_templates: recompiles when the tree's path changes, which
    # `check_cwd: false` does not suppress.
    File.write!(Path.join(ctx.dir, "lib/sample/baked.ex"), """
    defmodule Sample.Baked do
      @cwd File.cwd!()
      def __mix_recompile__?, do: File.cwd!() != @cwd
      def cwd, do: @cwd
    end
    """)

    git!(ctx.dir, ["add", "lib/sample/baked.ex"])
    git!(ctx.dir, ["commit", "-qm", "baked"])
    assert snapshot!(ctx) == "full"

    moved = ctx.dir <> "-moved"
    {_, 0} = System.cmd("cp", ["-a", ctx.dir, moved])
    beam = Path.join(moved, "_build/test/lib/sample/ebin/Elixir.Sample.Baked.beam")
    before = File.stat!(beam, time: :posix).mtime
    # Past a whole second, so a rebuilt beam's mtime differs.
    Process.sleep(1100)

    assert snapshot!(%{ctx | dir: moved}) == "incremental"
    assert File.stat!(beam, time: :posix).mtime > before, "the moved tree's beam was not rebuilt"
    assert snapshot!(%{ctx | dir: moved}) == "none"
  end

  test "snapshot builds a tree with no .git from CHG_SHA, the reference cache too", ctx do
    File.rm_rf!(Path.join(ctx.dir, ".git"))
    env = [{"CHG_SHA", ctx.base}, {"GIT_CEILING_DIRECTORIES", ctx.root}]
    assert {%{"work" => "full"}, 0} = chg(ctx, ["chg.snapshot"], env)
    assert {%{"work" => "none"}, 0} = chg(ctx, ["chg.snapshot"], env)
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

  test "a test file that does not compile is an error, and the document is still last", ctx do
    # A module that loads first runs while the broken one still compiles, so the
    # formatter has printed its dot, with no newline, when `mix test` gives up. The broken
    # file waits for the quick test's marker so that order does not rest on a sleep.
    marker = Path.join(ctx.dir, "quick.ran")

    File.write!(Path.join(ctx.dir, "test/sample/a_quick_test.exs"), """
    defmodule Sample.AQuickTest do
      use ExUnit.Case, async: true
      test "runs before the compile error", do: File.write!(#{inspect(marker)}, "")
    end
    """)

    File.write!(Path.join(ctx.dir, "test/sample/broken_test.exs"), """
    defmodule Sample.BrokenTest do
      use ExUnit.Case
      Enum.find(1..100, fn _ -> File.exists?(#{inspect(marker)}) or Process.sleep(100) end)
      Process.sleep(200)
      Code.require_file("missing.ex", "/nonexistent")
      test "never", do: :ok
    end
    """)

    list = Path.join(ctx.dir, "tests.txt")

    File.write!(
      list,
      "test/sample/a_quick_test.exs\ntest/sample/billing_test.exs\ntest/sample/broken_test.exs\n"
    )

    broken = %{"id" => "test/sample/broken_test.exs", "status" => "error", "ms" => 0}

    for args <- [["chg.run", "--tests", list], ["chg.shard", "--of", "1", "--index", "1"]] do
      File.rm(marker)
      {out, 1} = sh("mix", args, ctx.dir, [{"MIX_ARCHIVES", ctx.archives}])
      assert out =~ ~r/\.\n\{"results"/, "a dot ended the progress mid-line: #{out}"

      %{"results" => results} =
        out |> String.split("\n", trim: true) |> List.last() |> JSON.decode!()

      assert broken in results
    end
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
    assert length(ids) == 14
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

  # mkreyman/chg#47. Fetches dialyxir from Hex and builds both PLTs from scratch, so it
  # is the slowest test here.
  @tag timeout: 1_200_000
  test "incremental dialyzer judges a change exactly as mix dialyzer does", ctx do
    edit!(ctx, "mix.exs", fn mix ->
      mix
      |> String.replace(
        ~s|deps: [{:shared, path: "apps/shared"}]|,
        ~s|deps: [{:shared, path: "apps/shared"}, | <>
          ~s|{:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}],\n| <>
          ~s|      dialyzer: [plt_core_path: "_build/\#{Mix.env()}", plt_add_apps: [:ex_unit]]|
      )
    end)

    # A contract the compiler does not check and dialyzer does, committed before the
    # snapshot, so the incremental PLT caches its warning.
    plant_contract!(ctx, "lib/sample/billing.ex")
    {_, 0} = sh("mix", ["deps.get"], ctx.dir, [{"MIX_ARCHIVES", ctx.archives}])
    git!(ctx.dir, ["add", "mix.exs", "mix.lock", "lib/sample/billing.ex"])
    git!(ctx.dir, ["commit", "-qm", "dialyxir"])

    snapshot!(ctx)
    assert File.regular?(Path.join(ctx.dir, "_build/chg/dialyzer-test.iplt"))

    # A check runs in a workspace cloned from the snapshot at another path, where the
    # incremental PLT's cached warnings carry the snapshot's paths: all of it below.
    ws = %{ctx | dir: Path.join(ctx.root, "moved-#{System.unique_integer([:positive])}")}
    File.cp_r!(ctx.dir, ws.dir)

    # The cached warning of an unchanged module: printed, and filtered, as mix dialyzer does.
    assert_same_judgement(ws, 2, ["lib/sample/billing.ex"])
    File.write!(Path.join(ws.dir, ".dialyzer_ignore.exs"), ~s|[{"lib/sample/billing.ex"}]\n|)
    assert_same_judgement(ws, 0, [])
    File.rm!(Path.join(ws.dir, ".dialyzer_ignore.exs"))

    # A warning in a changed module, which the check re-analyses.
    plant_contract!(ws, "lib/sample/reports.ex")
    assert_same_judgement(ws, 2, ["lib/sample/billing.ex", "lib/sample/reports.ex"])

    assert {%{"ok" => false, "failures" => failures}, 1} =
             chg(ws, ["chg.static", "--base", "HEAD"])

    assert Enum.sort(Enum.map(failures, &{&1["check"], &1["file"]})) == [
             {"dialyzer", "lib/sample/billing.ex"},
             {"dialyzer", "lib/sample/reports.ex"}
           ]

    # A PLT dialyzer cannot read (truncated, or another OTP's) is a dialyzer error: exit
    # 3, and the check falls back to mix dialyzer rather than failing the commit.
    File.write!(Path.join(ws.dir, "_build/chg/dialyzer-test.iplt"), "not a PLT")
    assert {_, 3} = dialyzer(ws, ["chg.dialyzer"])

    assert {%{"ok" => false, "failures" => [_, _] = failures}, 1} =
             chg(ws, ["chg.static", "--base", "HEAD"])

    assert Enum.all?(
             failures,
             &(&1["file"] in ["lib/sample/billing.ex", "lib/sample/reports.ex"])
           )

    # Without the incremental PLT a check never builds one: it falls back to mix dialyzer.
    File.rm!(Path.join(ws.dir, "_build/chg/dialyzer-test.iplt"))
    assert {_, 3} = dialyzer(ws, ["chg.dialyzer"])

    assert {%{"ok" => false, "failures" => [_, _]}, 1} =
             chg(ws, ["chg.static", "--base", "HEAD"])
  end

  defp plant_contract!(ctx, path) do
    edit!(
      ctx,
      path,
      &String.replace(
        &1,
        ~r/\nend\s*\z/,
        ~s|\n\n  @spec label() :: integer()\n  def label, do: "x"\nend\n|
      )
    )
  end

  # `mix dialyzer --format short` and `mix chg.dialyzer` exit with `status` and print the
  # same warning lines, one in each of `files`, each relative to the project.
  defp assert_same_judgement(ctx, status, files) do
    {classic, ^status} = dialyzer(ctx, ["dialyzer", "--format", "short"])
    {incremental, ^status} = dialyzer(ctx, ["chg.dialyzer"])
    assert warning_lines(incremental) == warning_lines(classic)
    assert Enum.map(warning_lines(incremental), &hd(String.split(&1, ":"))) == files
  end

  # Both outputs merged: `mix dialyzer` prints its warnings on stderr.
  defp dialyzer(ctx, args) do
    env = [{"MIX_BUILD_PATH", nil}, {"MIX_ARCHIVES", ctx.archives}, {"MIX_ENV", "test"}]
    System.cmd("mix", args, cd: ctx.dir, env: @isolated_git ++ env, stderr_to_stdout: true)
  end

  defp warning_lines(out),
    do: out |> String.split("\n") |> Enum.filter(&(&1 =~ ~r/^\S+\.exs?:\d+/)) |> Enum.sort()

  test "a recorded run selects by compiled code: a comment selects nothing, a behaviour change its tests",
       ctx do
    snapshot!(ctx)
    history = Path.join(ctx.root, "history-#{System.unique_integer([:positive])}")
    File.mkdir_p!(history)
    record = Path.join(history, ctx.base <> ".cover")

    assert {%{"results" => [_ | _]}, 0} =
             chg(ctx, ["chg.shard", "--of", "1", "--index", "1"], [{"CHG_RECORD", record}])

    rec = record |> File.read!() |> :erlang.binary_to_term()
    assert rec.sha == ctx.base
    assert Sample.Billing in rec.cover["test/sample/billing_test.exs"]
    assert Sample.Accounts in rec.cover["test/sample/billing_test.exs"]
    assert Map.has_key?(rec.ms, "test/sample/billing_test.exs")
    assert Map.has_key?(rec.digests, Sample.Reports)
    # Compile-time calls count for the file compiled. The compiling process's own calls
    # count for no other file and are not global; a process it starts is timed, so before
    # the first test module (here) it is global too.
    assert Sample.Constants in rec.cover["test/sample/greeting_test.exs"]
    assert Sample.Spawned in rec.cover["test/sample/greeting_test.exs"]
    refute Sample.Constants in rec.global
    refute Sample.Case in rec.global
    refute Sample.Constants in rec.cover["test/sample/accounts_test.exs"]
    # Reads: a file at run time, a directory listed while compiling (that file's alone),
    # and a subprocess. None of them happened outside every window.
    files = rec.reads["test/sample/files_test.exs"]
    assert "docs/reports.md" in files
    assert "docs/stories/" in files
    assert {:spawn, "true"} in files

    for {f, reads} <- rec.reads,
        f != "test/sample/files_test.exs",
        do:
          refute("docs/stories/" in reads, "#{f} credited with another file's compile-time read")

    # Reads under _build count as what they were compiled from: a beam as its module, a
    # file under the built priv as the project's priv path.
    built = "test/sample/build_reads_test.exs"
    assert Sample.Scanned in rec.cover[built]
    refute Enum.any?(rec.cover, fn {f, mods} -> f != built and Sample.Scanned in mods end)
    assert "priv/greeting.txt" in rec.reads[built]
    # A path dependency's build counts as its source directory, its priv as that path.
    shared = "test/sample/shared_reads_test.exs"
    assert "apps/shared/" in rec.reads[shared]
    assert "apps/shared/priv/note.txt" in rec.reads[shared]
    refute Enum.any?(rec.reads, fn {f, r} -> f != shared and "apps/shared/" in r end)

    refute Enum.any?(rec.global_reads, &match?({:spawn, _}, &1))
    refute Enum.any?(rec.global_reads, &(&1 == "./" or String.starts_with?(&1, "docs")))

    refute Enum.any?(Map.values(rec.reads), fn r ->
             Enum.any?(r, &(is_binary(&1) and String.starts_with?(&1, ["_build", "deps", "/"])))
           end)

    env = [{"CHG_COVER", record}]
    edit!(ctx, "lib/sample/reports.ex", &("# a comment shifts every line\n" <> &1))
    git!(ctx.dir, ["commit", "-qam", "comment"])

    assert {%{"mode" => "subset", "tests" => [], "reason" => "coverage of " <> _}, 0} =
             chg(ctx, ["chg.affected", "--base", "HEAD~1"], env)

    # A test that only scanned a module's beam runs when that module changes, and one that
    # read the built priv when the source priv is read at run time and changed.
    edit!(ctx, "lib/sample/scanned.ex", &String.replace(&1, ":allowed", ":denied"))

    assert {%{"mode" => "subset", "tests" => ["test/sample/build_reads_test.exs"]}, 0} =
             chg(ctx, ["chg.affected", "--base", "HEAD"], env)

    edit!(ctx, "lib/sample/scanned.ex", &String.replace(&1, ":denied", ":allowed"))
    # A path dependency's modules are in no record: a change under it runs everything,
    # named by read_at_runtime or not, with coverage or from the module graph.
    edit!(ctx, "apps/shared/lib/shared.ex", &String.replace(&1, ":shared", ":changed"))
    read_shared = [{"CHG_READ", "apps/shared/lib/shared.ex"}]

    for extra <- [[], read_shared], given <- [env, []] do
      assert {%{"mode" => "all", "reason" => reason}, 0} =
               chg(ctx, ["chg.affected", "--base", "HEAD"], given ++ extra)

      assert reason =~ "apps/shared/lib/shared.ex is in the path dependency shared (apps/shared/)"
    end

    # Committed since the record (and the snapshot), with nothing changed since the base.
    git!(ctx.dir, ["commit", "-qam", "shared"])

    for given <- [env, []] do
      assert {%{"mode" => "all", "reason" => reason}, 0} =
               chg(ctx, ["chg.affected", "--base", "HEAD"], given)

      assert reason =~ "in the path dependency shared"
    end

    git!(ctx.dir, ["reset", "-q", "--hard", "HEAD~1"])
    read_priv = [{"CHG_READ", "priv/greeting.txt"}]

    assert {%{"mode" => "subset", "tests" => tests}, 0} =
             chg(ctx, ["chg.affected", "--base", "HEAD"], env ++ read_priv)

    assert "test/sample/build_reads_test.exs" in tests
    refute "test/sample/reports_test.exs" in tests

    edit!(ctx, "lib/sample/accounts.ex", &String.replace(&1, "user-", "member-"))

    assert {%{"mode" => "subset", "tests" => tests, "reason" => "coverage of " <> _}, 0} =
             chg(ctx, ["chg.affected", "--base", "HEAD"], env)

    assert "test/sample/accounts_test.exs" in tests
    assert "test/sample/billing_test.exs" in tests

    # A new file under a listed directory selects its listers by the record, and the whole
    # suite without one. (The edit to accounts.ex stays, for the dirty record below.)
    File.write!(Path.join(ctx.dir, "docs/stories/b.json"), "{}\n")
    read = [{"CHG_READ", "docs/stories/b.json"}]

    assert {%{"mode" => "subset", "tests" => tests}, 0} =
             chg(ctx, ["chg.affected", "--base", "HEAD"], env ++ read)

    assert "test/sample/files_test.exs" in tests

    assert {%{"mode" => "all", "reason" => reason}, 0} =
             chg(ctx, ["chg.affected", "--base", "HEAD"], read)

    assert reason =~ "docs/stories/b.json is read at run time"
    File.rm!(Path.join(ctx.dir, "docs/stories/b.json"))

    # A record made at another commit is not written: the tree must be exactly HEAD.
    dirty = Path.join(history, "dirty.cover")
    chg(ctx, ["chg.shard", "--of", "1", "--index", "1"], [{"CHG_RECORD", dirty}])
    refute File.exists?(dirty)
  end

  test "a build outside the repo (MIX_BUILD_PATH) is read as what it was compiled from",
       ctx do
    build = Path.join(ctx.root, "build-#{System.unique_integer([:positive])}")
    record = Path.join(ctx.root, "elsewhere-#{System.unique_integer([:positive])}.cover")
    env = [{"MIX_BUILD_PATH", build}, {"CHG_RECORD", record}]

    assert {%{"results" => [_ | _]}, 0} =
             chg(ctx, ["chg.shard", "--of", "1", "--index", "1"], env)

    assert File.exists?(Path.join(build, "lib/sample/ebin/Elixir.Sample.Scanned.beam"))
    rec = record |> File.read!() |> :erlang.binary_to_term()
    built = "test/sample/build_reads_test.exs"
    shared = "test/sample/shared_reads_test.exs"
    assert Sample.Scanned in rec.cover[built]
    assert "priv/greeting.txt" in rec.reads[built]
    assert "apps/shared/" in rec.reads[shared]
    assert "apps/shared/priv/note.txt" in rec.reads[shared]
  end

  test "a change to an umbrella sibling outside the project selects every test", ctx do
    # The project as an umbrella child (apps/sample) whose sibling is apps/shared: the
    # sibling is outside the project's directory but inside the repository.
    umbrella = Path.join(ctx.root, "umbrella-#{System.unique_integer([:positive])}")
    project = Path.join(umbrella, "apps/sample")
    File.mkdir_p!(Path.join(umbrella, "apps"))
    File.cp_r!(ctx.dir, project)
    File.rm_rf!(Path.join(project, ".git"))
    File.rename!(Path.join(project, "apps/shared"), Path.join(umbrella, "apps/shared"))
    File.rm_rf!(Path.join(project, "apps"))

    edit!(
      %{dir: project},
      "mix.exs",
      &String.replace(&1, ~s(path: "apps/shared"), ~s(path: "../shared"))
    )

    git!(umbrella, ["init", "-q"])
    git!(umbrella, ["add", "apps"])
    git!(umbrella, ["commit", "-qm", "umbrella"])

    edit!(
      %{dir: umbrella},
      "apps/shared/lib/shared.ex",
      &String.replace(&1, ":shared", ":changed")
    )

    assert {%{"mode" => "all", "reason" => reason}, 0} =
             chg(%{ctx | dir: project}, ["chg.affected", "--base", "HEAD"])

    assert reason =~ "apps/shared/lib/shared.ex is in the path dependency shared (apps/shared/)"
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
              env: [{"MIX_ENV", nil}, {"MIX_ARCHIVES", ctx.archives} | @isolated_git]
            )

          JSON.decode!(out)
        end

        assert {_, 0} =
                 System.cmd(bin, ["adapter", "exec", "snapshot", "--repo", ctx.dir],
                   env: [{"MIX_ENV", nil}, {"MIX_ARCHIVES", ctx.archives} | @isolated_git]
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
