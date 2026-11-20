defmodule Loopctl.Release.ImportHistoryTest do
  @moduledoc """
  `release/import-history.sh` (US-52.4): imports a repository under a prefix with its
  history, records the imported commit in `release/imports.toml`, re-imports only new
  commits, and refuses without changing anything when it cannot import cleanly.

  Runs the real script in throwaway git repositories, with no hooks and no machine config.
  """
  use ExUnit.Case, async: true

  alias Loopctl.DeliveryGates.GitEnv

  if is_nil(System.find_executable("git-filter-repo")) do
    @moduletag skip:
                 "git-filter-repo is not on PATH (CI installs it; apt install git-filter-repo)"
  end

  @script Path.join(File.cwd!(), "release/import-history.sh")
  @identity [
    {"GIT_AUTHOR_NAME", "t"},
    {"GIT_AUTHOR_EMAIL", "t@t"},
    {"GIT_COMMITTER_NAME", "t"},
    {"GIT_COMMITTER_EMAIL", "t@t"}
  ]

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    root = Path.join(Loopctl.RealTmpDir.path!(), "loopctl-import-#{suffix}")
    source = Path.join(root, "owner/source")
    target = Path.join(root, "target")
    File.mkdir_p!(source)
    File.mkdir_p!(target)
    on_exit(fn -> File.rm_rf!(root) end)

    git!(source, ["init", "-q", "-b", "master"])
    for n <- 1..3, do: commit_a!(source, n)

    git!(target, ["init", "-q", "-b", "master"])
    File.write!(Path.join(target, "README.md"), "target\n")
    git!(target, ["add", "README.md"])
    git!(target, ["commit", "-q", "-m", "target base"])

    %{source: source, target: target}
  end

  test "imports with history, re-imports only new commits, then is up to date", ctx do
    {out, 0} = import(ctx.target, ctx.source, "runner")
    assert out =~ "imported: owner/source into runner/"
    assert subjects(ctx.target, "runner/lib/a.ex") == subjects(ctx.source, "lib/a.ex")
    assert length(subjects(ctx.target, "runner/lib/a.ex")) == 3
    assert recorded(ctx.target) == rev!(ctx.source, "HEAD")
    first_import = rev!(ctx.target, "HEAD")

    for n <- 4..5, do: commit_a!(ctx.source, n)
    {_, 0} = import(ctx.target, ctx.source, "runner")
    assert subjects(ctx.target, "runner/lib/a.ex") == subjects(ctx.source, "lib/a.ex")
    assert length(subjects(ctx.target, "runner/lib/a.ex")) == 5
    assert recorded(ctx.target) == rev!(ctx.source, "HEAD")
    # Already-imported commits keep their rewritten SHAs: the first import is an ancestor.
    {_, 0} = git(ctx.target, ["merge-base", "--is-ancestor", first_import, "HEAD"])
    assert imports_count(ctx.target) == 1

    head = rev!(ctx.target, "HEAD")
    {out, 0} = import(ctx.target, ctx.source, "runner")
    assert out =~ "up to date: owner/source at #{String.slice(rev!(ctx.source, "HEAD"), 0, 12)}"
    assert rev!(ctx.target, "HEAD") == head
  end

  test "a dirty working tree is refused and nothing changes", ctx do
    File.write!(Path.join(ctx.target, "dirty.txt"), "x\n")
    assert_refused(ctx, "runner")
  end

  test "a prefix that exists with no record is refused and nothing changes", ctx do
    File.mkdir_p!(Path.join(ctx.target, "runner"))
    File.write!(Path.join(ctx.target, "runner/x.ex"), "x\n")
    git!(ctx.target, ["add", "runner/x.ex"])
    git!(ctx.target, ["commit", "-q", "-m", "a runner dir"])
    assert_refused(ctx, "runner")
  end

  test "an unreachable source is refused and nothing changes", ctx do
    assert_refused(%{ctx | source: Path.join(ctx.source, "missing")}, "runner")
  end

  defp assert_refused(ctx, prefix) do
    head = rev!(ctx.target, "HEAD")
    manifest = Path.join(ctx.target, "release/imports.toml")
    before = File.read(manifest)
    {_out, status} = import(ctx.target, ctx.source, prefix)
    assert status == 2
    assert rev!(ctx.target, "HEAD") == head
    assert File.read(manifest) == before
  end

  defp commit_a!(dir, n) do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/a.ex"), "# #{n}\n")
    git!(dir, ["add", "lib/a.ex"])
    git!(dir, ["commit", "-q", "-m", "change #{n}"])
  end

  defp import(target, source, prefix) do
    System.cmd("bash", [@script, source, prefix],
      cd: target,
      env:
        GitEnv.spawn_env() ++
          @identity ++ [{"GIT_CONFIG_PARAMETERS", "'core.hooksPath=/dev/null'"}],
      stderr_to_stdout: true
    )
  end

  defp subjects(dir, path),
    do: dir |> git!(["log", "--format=%s", "--", path]) |> String.split("\n", trim: true)

  defp recorded(dir) do
    [_, sha] =
      Regex.run(
        ~r/imported_sha = "([0-9a-f]{40})"/,
        File.read!(Path.join(dir, "release/imports.toml"))
      )

    sha
  end

  defp imports_count(dir) do
    dir
    |> Path.join("release/imports.toml")
    |> File.read!()
    |> String.split("[[import]]")
    |> length()
    |> Kernel.-(1)
  end

  defp rev!(dir, ref), do: dir |> git!(["rev-parse", ref]) |> String.trim()

  defp git!(dir, args) do
    {out, status} = git(dir, args)
    assert status == 0, "git #{Enum.join(args, " ")} in #{dir}: #{out}"
    out
  end

  defp git(dir, args) do
    System.cmd("git", GitEnv.config_args() ++ ["-c", "commit.gpgsign=false" | args],
      cd: dir,
      env: GitEnv.spawn_env() ++ @identity,
      stderr_to_stdout: true
    )
  end
end
