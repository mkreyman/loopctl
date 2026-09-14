defmodule Loopctl.DeliveryGates.Measurement.RepoHistoryGitTest do
  @moduledoc """
  The one part of `Loopctl.DeliveryGates.Measurement.RepoHistory` a canned runner cannot cover:
  `git/2` itself, and specifically its STREAM handling.

  Every other test in this directory injects a runner, so `git/2` had no test at all — which
  meant restoring `stderr_to_stdout: true` left the whole suite green while a warning line was
  appended to output that gets split into a file list or a diffstat. This drives the real binary
  against a temporary repository configured to warn on a ZERO exit.

  ## What went wrong the first time, because the fix is shaped by it

  The first version created its fixture with `git init` and trusted it. Under `mix test` alone
  that works. Under the COMMIT HOOK it does not: this project's `pre-commit` runs the suite, and
  git exports `GIT_DIR`, `GIT_WORK_TREE` and `GIT_INDEX_FILE` to a hook. **`-C <repo>` does not
  win against `GIT_DIR`**, so every command — the `init` included — targeted the real checkout.
  Ten commits named "one" and "two" landed on the working branch, carrying whatever was staged
  plus the fixture's own `a.txt`, and the suite reported green.

  Four guards now, because the environment is the hazard and the previous fix addressed only its
  symptom:

  1. **`RepoHistory.scrubbed_git_env/0` on every invocation** — the actual fix, in the module
     under test as well as here, so an inherited `GIT_DIR` cannot retarget anything.
  2. The fixture is created under `System.tmp_dir!/0`, OUTSIDE the project tree, so a discovery
     failure has no repository above it to find and is a loud error rather than somebody's
     branch.
  3. Every command pins `--git-dir` and `--work-tree`.
  4. `assert_isolated/1` refuses to proceed unless git agrees the toplevel IS the fixture. That
     is the one that turns a recurrence into a red test instead of ten commits, and it is what
     caught this on the re-run.
  """
  use ExUnit.Case, async: true

  alias Loopctl.DeliveryGates.Measurement.RepoHistory

  # No tenant: this module reads git and never the database.

  # A `.gitattributes` NEGATIVE PATTERN makes git warn on stderr and exit 0 — a real advisory
  # warning from the repository's own configuration, not one injected by the test's environment.
  defp warning_repo do
    repo =
      Path.join([
        System.tmp_dir!(),
        "loopctl-git-fixture-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(repo) end)

    {_out, 0} =
      System.cmd("git", ["-C", repo, "init", "-q", "."],
        stderr_to_stdout: true,
        env: RepoHistory.scrubbed_git_env()
      )

    assert_isolated(repo)

    git!(repo, ["config", "user.email", "harness@example.test"])
    git!(repo, ["config", "user.name", "harness"])

    File.write!(Path.join(repo, "a.txt"), "one\n")
    git!(repo, ["add", "a.txt"])
    git!(repo, ["commit", "-qm", "one"])

    File.write!(Path.join(repo, ".gitattributes"), "[attr]macro\n!!!negative\n")
    File.write!(Path.join(repo, "a.txt"), "one\ntwo\n")
    git!(repo, ["add", ".gitattributes", "a.txt"])
    git!(repo, ["commit", "-qm", "two"])

    repo
  end

  # `--git-dir` and `--work-tree` pinned, and hooks disabled so this repository's own commit gate
  # never runs inside a test.
  defp git!(repo, args) do
    all =
      [
        "--git-dir",
        Path.join(repo, ".git"),
        "--work-tree",
        repo,
        "-c",
        "core.hooksPath=/dev/null"
      ] ++
        args

    {out, 0} =
      System.cmd("git", all,
        cd: repo,
        stderr_to_stdout: true,
        env: RepoHistory.scrubbed_git_env()
      )

    out
  end

  # The guard that would have turned ten commits on a working branch into one red test.
  defp assert_isolated(repo) do
    assert File.dir?(Path.join(repo, ".git")),
           "the fixture repository was not created at #{repo} — refusing to run git here, " <>
             "because every command would resolve to whatever repository is above it"

    {toplevel, 0} =
      System.cmd("git", ["-C", repo, "rev-parse", "--show-toplevel"],
        stderr_to_stdout: true,
        env: RepoHistory.scrubbed_git_env()
      )

    assert Path.expand(String.trim(toplevel)) == Path.expand(repo),
           "git resolves #{repo} to #{String.trim(toplevel)} — the fixture is not isolated"
  end

  describe "git/2 on a SUCCESSFUL command that warns" do
    test "the repository really does warn on stderr with a zero exit" do
      # The premise of every assertion below. Without it the others pass vacuously on a
      # repository that emits nothing, which is the shape of unfalsifiable check this file
      # exists to replace.
      repo = warning_repo()

      {merged, 0} =
        System.cmd("git", ["-C", repo, "diff", "--numstat", "HEAD~1", "HEAD"],
          stderr_to_stdout: true,
          env: RepoHistory.scrubbed_git_env()
        )

      assert merged =~ "warning:"
    end

    test "returns stdout ONLY — no warning line reaches the parsed bytes" do
      repo = warning_repo()

      assert {:ok, output} = RepoHistory.git(repo, ["diff", "--numstat", "-z", "HEAD~1", "HEAD"])

      refute output =~ "warning:"
      refute output =~ "Negative patterns"
    end

    test "so the diffstat computed from those bytes counts no phantom file" do
      # The CONSEQUENCE, not just the bytes: a merged warning becomes an extra record here, and
      # the same pollution in an `ls-tree -z` read becomes a phantom path in the file lists the
      # stale-trigger split is computed from — which is what the headline strata rest on.
      repo = warning_repo()

      assert {:ok, numstat} = RepoHistory.git(repo, ["diff", "--numstat", "-z", "HEAD~1", "HEAD"])

      # Two files, three added lines: `.gitattributes` is new (2 lines) and `a.txt` gains one.
      assert %{files: 2, changed_lines: 3} = RepoHistory.diffstat(numstat)
    end

    test "an ls-tree read splits into real paths and nothing else" do
      repo = warning_repo()

      assert {:ok, output} = RepoHistory.git(repo, ["ls-tree", "-r", "--name-only", "-z", "HEAD"])

      assert output |> String.split(<<0>>, trim: true) |> Enum.sort() == [
               ".gitattributes",
               "a.txt"
             ]
    end
  end

  # These print a line of git's own stderr into the suite output. That is not noise to be
  # silenced: it IS the demonstration that stderr is no longer captured into the returned bytes,
  # and capturing it to keep the output tidy would restore the defect this file exists to pin.
  describe "git/2 on a FAILING command" do
    test "reports the status and never re-runs the command" do
      # A re-run to enrich the message could observe a transient that had cleared, and would then
      # return a SUCCESSFUL payload as the text of a `git_failed` error.
      repo = warning_repo()

      assert {:error, {:git_failed, status, _output}} =
               RepoHistory.git(repo, ["rev-parse", "--verify", "no-such-ref^{commit}"])

      assert status != 0
    end

    test "a path with no repository above it is an error, not a write to somebody else's" do
      # The incident this file is written around: a directory that is not a repository must
      # FAIL here. It only did not because the fixture used to sit inside one.
      outside =
        Path.join(System.tmp_dir!(), "loopctl-not-a-repo-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(outside) end)

      assert {:error, {:git_failed, _status, _output}} =
               RepoHistory.git(outside, ["rev-parse", "HEAD"])
    end
  end
end
