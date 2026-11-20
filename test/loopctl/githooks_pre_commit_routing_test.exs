defmodule Loopctl.GithooksPreCommitRoutingTest do
  @moduledoc """
  US-52.6: `.githooks/pre-commit` judges each area of the repository by its own checks.

  Runs the real hook in throwaway repositories with `mix`, `cargo` and `node` stubbed first
  on PATH and a fake fleet hook under a throwaway HOME; each stub logs its name, the
  directory it ran in and its arguments.
  """
  use ExUnit.Case, async: true

  alias Loopctl.DeliveryGates.GitEnv

  @hook Path.expand(".githooks/pre-commit")

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    root = Path.join(Loopctl.RealTmpDir.path!(), "loopctl-precommit-#{suffix}")
    repo = Path.join(root, "repo")
    home = Path.join(root, "home")
    bin = Path.join(root, "bin")
    log = Path.join(root, "calls.log")
    Enum.each([repo, home, bin], &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf!(root) end)

    for tool <- ["mix", "cargo", "node"] do
      write_exec!(Path.join(bin, tool), """
      #!/bin/bash
      echo "#{tool} $(pwd -P) $*" >> "#{log}"
      [ "${FAKE_FAIL:-}" != "#{tool} $1" ] || exit 1
      """)
    end

    write_exec!(Path.join([home, ".git-hooks", "pre-commit"]), """
    #!/bin/bash
    echo "fleet $*" >> "#{log}"
    """)

    git!(repo, ["init", "-q", "-b", "master"])
    commit!(repo, "runner/lib/old.ex")
    {physical, 0} = System.cmd("pwd", ["-P"], cd: repo)

    %{repo: repo, home: home, bin: bin, log: log, physical: String.trim(physical)}
  end

  test "runner/ alone runs mix precommit in runner/ and never the fleet hook", ctx do
    stage!(ctx.repo, "runner/lib/a.ex")

    assert {_, 0} = hook(ctx)
    assert calls(ctx) == ["mix #{ctx.physical}/runner precommit"]
  end

  test "chg/ outside its adapters runs cargo fmt, clippy and test in chg/", ctx do
    stage!(ctx.repo, "chg/cli/src/main.rs")

    assert {_, 0} = hook(ctx)

    assert calls(ctx) == [
             "cargo #{ctx.physical}/chg fmt --all --check",
             "cargo #{ctx.physical}/chg clippy --all-targets --locked -- -D warnings",
             "cargo #{ctx.physical}/chg test --locked"
           ]
  end

  test "the Elixir adapter runs format, compile and test there, and no cargo", ctx do
    stage!(ctx.repo, "chg/adapters/elixir/lib/x.ex")
    dir = "#{ctx.physical}/chg/adapters/elixir"

    assert {_, 0} = hook(ctx)

    assert calls(ctx) == [
             "mix #{dir} format --check-formatted",
             "mix #{dir} compile --warnings-as-errors",
             "mix #{dir} test"
           ]
  end

  test "the TypeScript adapter runs its unit and integration tests there", ctx do
    stage!(ctx.repo, "chg/adapters/typescript/src/x.mjs")

    assert {_, 0} = hook(ctx)

    assert calls(ctx) == [
             "node #{ctx.physical}/chg/adapters/typescript --test test/unit.test.mjs test/integration.test.mjs"
           ]
  end

  test "a path outside runner/, chg/ and e2e/ hands to the fleet hook after the area checks",
       ctx do
    stage!(ctx.repo, "runner/lib/a.ex")
    stage!(ctx.repo, "lib/loopctl.ex")

    assert {_, 0} = hook(ctx, ["x"])
    assert calls(ctx) == ["mix #{ctx.physical}/runner precommit", "fleet x"]
  end

  test "a failing check stops the commit, names its area, and skips the fleet hook", ctx do
    stage!(ctx.repo, "chg/cli/src/main.rs")
    stage!(ctx.repo, "lib/loopctl.ex")

    {out, status} = hook(ctx, [], [{"FAKE_FAIL", "cargo clippy"}])

    assert status == 1
    assert out =~ "❌ chg: 'cargo clippy --all-targets --locked -- -D warnings' failed in chg/"
    refute Enum.any?(calls(ctx), &String.starts_with?(&1, "fleet"))
    refute Enum.any?(calls(ctx), &(&1 =~ "cargo #{ctx.physical}/chg test"))
  end

  test "a deleted runner file is a staged runner path", ctx do
    commit!(ctx.repo, "runner/mix.exs")
    git!(ctx.repo, ["rm", "-q", "runner/lib/old.ex"])

    assert {_, 0} = hook(ctx)
    assert calls(ctx) == ["mix #{ctx.physical}/runner precommit"]
  end

  test "a commit deleting a whole area has nothing to check there", ctx do
    git!(ctx.repo, ["rm", "-q", "runner/lib/old.ex"])

    assert {out, 0} = hook(ctx)
    assert out =~ "runner/ is gone in this commit"
    assert calls(ctx) == []
  end

  test "e2e/ alone runs format, compile, credo and the offline tests there", ctx do
    stage!(ctx.repo, "e2e/mix.exs")
    dir = "#{ctx.physical}/e2e"

    assert {_, 0} = hook(ctx)

    assert calls(ctx) == [
             "mix #{dir} format --check-formatted",
             "mix #{dir} compile --warnings-as-errors",
             "mix #{dir} credo --strict --config-file .credo.exs",
             "mix #{dir} test --exclude live"
           ]
  end

  test "a commit staging nothing is the fleet hook's", ctx do
    assert {_, 0} = hook(ctx)
    assert calls(ctx) == ["fleet "]
  end

  defp hook(ctx, args \\ [], env \\ []) do
    System.cmd("bash", [@hook | args],
      cd: ctx.repo,
      env:
        GitEnv.spawn_env() ++
          [{"HOME", ctx.home}, {"PATH", ctx.bin <> ":" <> System.get_env("PATH", "")} | env],
      stderr_to_stdout: true
    )
  end

  defp calls(ctx) do
    case File.read(ctx.log) do
      {:ok, body} -> String.split(body, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp stage!(repo, path) do
    full = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "x\n")
    git!(repo, ["add", path])
  end

  defp commit!(repo, path) do
    stage!(repo, path)
    git!(repo, ["commit", "-q", "-m", path])
  end

  defp write_exec!(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  defp git!(repo, args) do
    {out, status} =
      System.cmd(
        "git",
        GitEnv.config_args() ++
          ["-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false" | args],
        cd: repo,
        env: GitEnv.spawn_env(),
        stderr_to_stdout: true
      )

    assert status == 0, "git #{Enum.join(args, " ")}: #{out}"
    out
  end
end
