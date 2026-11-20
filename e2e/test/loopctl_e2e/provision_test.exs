defmodule LoopctlE2e.ProvisionTest do
  @moduledoc """
  TC-52.9.7: provision.sh makes a sandbox match the template and is idempotent, and the
  workflows have the shape AC-52.9.6 and AC-52.9.7 name. The script runs against a local bare
  repository (SANDBOX_REMOTE) and a `gh` stub on PATH that answers as an existing repository
  with the label.
  """
  use ExUnit.Case, async: true

  @script Path.expand("sandbox/provision.sh")
  @template Path.expand("sandbox/template")

  @moduletag :tmp_dir

  defp stub_gh(dir, label) do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "gh"), """
    #!/bin/sh
    echo "$*" >> "#{dir}/gh.log"
    case "$1 $2" in
      "repo view") exit 0 ;;
      "label list") echo "#{label}" ;;
      *) exit 0 ;;
    esac
    """)

    File.chmod!(Path.join(bin, "gh"), 0o755)
    bin
  end

  defp provision(dir, bin, remote) do
    env = [
      {"PATH", bin <> ":" <> System.get_env("PATH")},
      {"GH_TOKEN", "test-token"},
      {"SANDBOX_REMOTE", remote},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"}
    ]

    System.cmd("bash", [@script], env: env, cd: dir, stderr_to_stdout: true)
  end

  defp git(dir, args) do
    {out, 0} =
      System.cmd("git", ["-C", dir | args],
        env: [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]
      )

    String.trim(out)
  end

  test "a first run pushes the template; a second changes nothing and says so", %{tmp_dir: dir} do
    remote = Path.join(dir, "sandbox.git")
    git(dir, ["init", "--quiet", "--bare", "-b", "master", remote])
    bin = stub_gh(dir, "loopctl")

    assert {out, 0} = provision(dir, bin, remote)
    assert out =~ "pushed the template"
    head = git(remote, ["rev-parse", "master"])

    files = git(remote, ["ls-tree", "-r", "--name-only", "master"]) |> String.split("\n")
    assert ".chg/adapter.toml" in files
    assert ".github/workflows/ci.yml" in files
    assert ".github/workflows/deploy.yml" in files
    assert "mix.exs" in files

    assert {out, 0} = provision(dir, bin, remote)
    assert out =~ "already matches the template; sandbox up to date"
    assert git(remote, ["rev-parse", "master"]) == head
  end

  test "a run's own file is never deleted", %{tmp_dir: dir} do
    remote = Path.join(dir, "sandbox.git")
    git(dir, ["init", "--quiet", "--bare", "-b", "master", remote])
    bin = stub_gh(dir, "loopctl")
    {_, 0} = provision(dir, bin, remote)

    clone = Path.join(dir, "clone")
    git(dir, ["clone", "--quiet", remote, clone])
    File.mkdir_p!(Path.join(clone, "lib/sandbox/runs"))

    File.write!(
      Path.join(clone, "lib/sandbox/runs/r1.ex"),
      "defmodule Sandbox.Runs.R1, do: nil\n"
    )

    git(clone, ["add", "lib/sandbox/runs/r1.ex"])
    git(clone, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-m", "run"])
    git(clone, ["push", "--quiet", "origin", "master"])

    assert {out, 0} = provision(dir, bin, remote)
    assert out =~ "sandbox up to date"
    assert git(remote, ["ls-tree", "-r", "--name-only", "master"]) =~ "lib/sandbox/runs/r1.ex"
  end

  test "a missing label is created", %{tmp_dir: dir} do
    remote = Path.join(dir, "sandbox.git")
    git(dir, ["init", "--quiet", "--bare", "-b", "master", remote])
    bin = stub_gh(dir, "some-other-label")

    assert {out, 0} = provision(dir, bin, remote)
    assert out =~ "created label loopctl"
    assert File.read!(Path.join(dir, "gh.log")) =~ "label create loopctl"
  end

  test "without a token it refuses with exit 2", %{tmp_dir: dir} do
    env = [{"GH_TOKEN", ""}, {"GITHUB_TOKEN", ""}]
    assert {out, 2} = System.cmd("bash", [@script], env: env, cd: dir, stderr_to_stdout: true)
    assert out =~ "set GH_TOKEN"
  end

  describe "the workflows" do
    test "the sandbox records a production deployment on master" do
      deploy = File.read!(Path.join(@template, ".github/workflows/deploy.yml"))

      assert deploy =~ "branches: [master]"
      assert deploy =~ "environment=production"
      assert deploy =~ "state=success"
    end

    test "the sandbox is gated by chg and its CI runs the suite" do
      assert File.read!(Path.join(@template, ".chg/adapter.toml")) =~ ~s(kind = "elixir")
      assert File.read!(Path.join(@template, "mix.exs")) =~ "check_cwd: false"
      assert File.read!(Path.join(@template, ".github/workflows/ci.yml")) =~ "mix test"
    end

    # The runner refuses a repository with no .loopctl/mode, and only `pr` runs.
    test "the sandbox opts into the pull-request delivery mode" do
      assert File.read!(Path.join(@template, ".loopctl/mode")) |> String.trim() == "pr"
    end

    # Verification and the merge gate count only push runs of the story's branch at its head.
    test "the sandbox CI runs on a push of every branch and never on a pull request" do
      ci = File.read!(Path.join(@template, ".github/workflows/ci.yml"))

      assert ci =~ ~s(branches: ["**"])
      refute ci =~ ~r/^\s*pull_request:/m
    end

    test "e2e.yml runs nightly at 07:00 and on dispatch, one at a time on fleet-ci" do
      yml = File.read!(Path.expand("../.github/workflows/e2e.yml"))

      assert yml =~ ~s(cron: "0 7 * * *")
      assert yml =~ "workflow_dispatch:"
      assert yml =~ "group: e2e\n      cancel-in-progress: false"
      assert yml =~ "runs-on: [self-hosted, fleet-ci]"
      assert yml =~ "secrets.LOOPCTL_E2E_ORCH_KEY"
      assert yml =~ "secrets.E2E_GITHUB_TOKEN"
      assert yml =~ "LOOPCTL_E2E_PROJECT_ID: ${{ vars.LOOPCTL_E2E_PROJECT_ID }}"
      assert yml =~ "if: failure()"
      assert yml =~ "path: e2e/stage-log/"
    end
  end
end
