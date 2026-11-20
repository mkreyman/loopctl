defmodule Loopctl.Release.FactoryReleaseTest do
  @moduledoc """
  US-52.7: `.github/workflows/factory-release.yml` tags and publishes each release set once.

  `.github/scripts/factory-release-plan.sh` is run against a throwaway repository with a
  bare origin; the workflow is read as YAML.
  """
  use ExUnit.Case, async: true

  alias Loopctl.DeliveryGates.GitEnv

  @plan Path.expand(".github/scripts/factory-release-plan.sh")
  @workflow ".github/workflows/factory-release.yml"

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    root = Path.join(Loopctl.RealTmpDir.path!(), "factory-release-#{suffix}")
    origin = Path.join(root, "origin.git")
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(root) end)

    git!(root, ["init", "-q", "--bare", origin])
    git!(repo, ["init", "-q", "-b", "master"])
    git!(repo, ["remote", "add", "origin", origin])
    first = commit_set!(repo, 1)
    %{repo: repo, first: first}
  end

  test "an untagged set is created on this commit", %{repo: repo, first: first} do
    assert plan!(repo, first) == %{"tag" => "factory-1", "action" => "create"}
  end

  test "a re-run on the tagged commit uploads, a later commit of the same set does nothing",
       %{repo: repo, first: first} do
    git!(repo, ["tag", "-a", "-m", "factory-1", "factory-1", first])
    git!(repo, ["push", "-q", "origin", "factory-1"])

    assert plan!(repo, first) == %{"tag" => "factory-1", "action" => "upload"}

    later = commit_set!(repo, 1)
    assert plan!(repo, later) == %{"tag" => "factory-1", "action" => "none"}

    next = commit_set!(repo, 2)
    assert plan!(repo, next) == %{"tag" => "factory-2", "action" => "create"}
  end

  test "the workflow follows green master CI, on fleet-ci, writing only in publish" do
    wf = YamlElixir.read_from_file!(@workflow)

    assert wf["on"] == %{
             "workflow_run" => %{
               "workflows" => ["CI"],
               "types" => ["completed"],
               "branches" => ["master"]
             }
           }

    assert wf["permissions"] == %{"contents" => "read"}
    assert wf["jobs"]["plan"]["if"] =~ "github.event.workflow_run.conclusion == 'success'"

    for {name, job} <- wf["jobs"] do
      assert job["runs-on"] == ["self-hosted", "fleet-ci"], name
      assert job["permissions"] == %{"contents" => "write"} == (name == "publish"), name
    end

    publish = Enum.map_join(wf["jobs"]["publish"]["steps"], "\n", &(&1["run"] || ""))
    assert publish =~ ~s(gh release upload "$TAG" -R "$GITHUB_REPOSITORY" --clobber dist/*)

    smoke = Enum.map_join(wf["jobs"]["build"]["steps"], "\n", &(&1["run"] || ""))
    assert smoke =~ "chg-x86_64-unknown-linux-musl.sha256"
    assert smoke =~ "release/manifest.toml"
  end

  defp plan!(repo, sha) do
    out = Path.join(repo, ".plan-out")
    File.rm(out)

    {log, status} =
      System.cmd("bash", [@plan],
        cd: repo,
        env: GitEnv.spawn_env() ++ [{"SHA", sha}, {"GITHUB_OUTPUT", out}],
        stderr_to_stdout: true
      )

    assert status == 0, log

    out
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(&List.to_tuple(String.split(&1, "=", parts: 2)))
  end

  defp commit_set!(repo, set) do
    File.mkdir_p!(Path.join(repo, "release"))
    nonce = Base.encode16(:crypto.strong_rand_bytes(4))
    File.write!(Path.join(repo, "release/manifest.toml"), "# #{nonce}\nset = #{set}\n")
    git!(repo, ["add", "release/manifest.toml"])
    git!(repo, ["commit", "-q", "-m", "set #{set} #{nonce}"])
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo, env: GitEnv.spawn_env())
    String.trim(sha)
  end

  defp git!(dir, args) do
    {out, status} =
      System.cmd(
        "git",
        GitEnv.config_args() ++
          [
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "tag.gpgsign=false" | args
          ],
        cd: dir,
        env: GitEnv.spawn_env(),
        stderr_to_stdout: true
      )

    assert status == 0, "git #{Enum.join(args, " ")}: #{out}"
    out
  end
end
