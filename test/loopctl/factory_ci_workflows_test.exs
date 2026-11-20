defmodule Loopctl.FactoryCiWorkflowsTest do
  @moduledoc """
  US-52.6: CI judges runner/ and chg/ inside the loopctl repository, each only when it changed.

  `.github/scripts/changed-areas.sh` is run against throwaway repositories; the three
  workflows are read as YAML. A job gated by area is skipped by its `if:`, never by
  `on.paths`, because a required check on a workflow filtered out by paths stays pending.
  """
  use ExUnit.Case, async: true

  alias Loopctl.DeliveryGates.GitEnv

  @areas Path.expand(".github/scripts/changed-areas.sh")
  @areas_output Path.expand(".github/scripts/areas-output.sh")
  @ci ".github/workflows/ci.yml"
  @runner_ci ".github/workflows/runner-ci.yml"
  @chg_ci ".github/workflows/chg-ci.yml"
  @fleet_ci ["self-hosted", "fleet-ci"]
  @macos_expr ~S<${{ matrix.os == 'macos' && vars.CI_RUNNER_MACOS && fromJSON(vars.CI_RUNNER_MACOS) || fromJSON('["self-hosted","fleet-ci"]') }}>
  @every ["chg", "e2e", "runner", "server"]

  describe "changed-areas.sh" do
    setup do
      suffix = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      repo = Path.join(Loopctl.RealTmpDir.path!(), "loopctl-areas-#{suffix}")
      File.mkdir_p!(repo)
      on_exit(fn -> File.rm_rf!(repo) end)
      git!(repo, ["init", "-q", "-b", "master"])
      base = commit!(repo, "README.md")
      %{repo: repo, base: base}
    end

    test "each path maps to its area, sorted and unique", %{repo: repo, base: base} do
      cases = [
        {["runner/lib/a.ex"], ["runner"]},
        {["priv/runner_contract/v1.json"], ["runner", "server"]},
        {["chg/cli/src/main.rs", "chg/adapters/elixir/lib/x.ex"], ["chg"]},
        {["e2e/mix.exs"], ["e2e"]},
        {["lib/loopctl.ex", "docs/x.md", "runner/mix.exs"], ["runner", "server"]},
        {["release/manifest.toml"], @every},
        {[".github/workflows/ci.yml"], @every}
      ]

      for {paths, want} <- cases do
        git!(repo, ["checkout", "-q", "-B", "case", base])
        head = Enum.reduce(paths, nil, fn path, _ -> commit!(repo, path) end)
        assert areas!(repo, base, head) == want, "#{inspect(paths)}"
      end
    end

    test "a pull request is judged on its own commits, not on what its base gained", %{
      repo: repo,
      base: base
    } do
      git!(repo, ["checkout", "-q", "-b", "pr", base])
      head = commit!(repo, "runner/lib/a.ex")
      git!(repo, ["checkout", "-q", "master"])
      moved = commit!(repo, "lib/loopctl.ex")

      assert areas!(repo, moved, head) == ["runner"]
    end

    test "a base it cannot read counts as every area", %{repo: repo, base: base} do
      head = commit!(repo, "runner/lib/a.ex")

      assert areas!(repo, String.duplicate("0", 40), head) == @every
      assert areas!(repo, String.duplicate("a", 40), head) == @every
      assert areas!(repo, base, base) == []
    end

    test "areas-output.sh writes one boolean per area, and a schedule is every area", %{
      repo: repo,
      base: base
    } do
      head = commit!(repo, "chg/cli/src/main.rs")
      out = Path.join(repo, "out")

      run_output!(repo, out, [
        {"GITHUB_EVENT_NAME", "push"},
        {"EVENT_BEFORE", base},
        {"GITHUB_SHA", head}
      ])

      assert File.read!(out) == "server=false\nrunner=false\nchg=true\ne2e=false\n"

      File.rm!(out)
      run_output!(repo, out, [{"GITHUB_EVENT_NAME", "schedule"}])
      assert File.read!(out) == "server=true\nrunner=true\nchg=true\ne2e=true\n"
    end
  end

  describe "runner-ci.yml and chg-ci.yml" do
    for file <- [@runner_ci, @chg_ci] do
      test "#{file} runs on master and epic pushes and master pull requests, unfiltered" do
        on = workflow(unquote(file))["on"]

        assert on["push"] == %{"branches" => ["master", "epic/**"]}
        assert on["pull_request"] == %{"branches" => ["master"]}
        refute Map.has_key?(on["push"], "paths")
        refute Map.has_key?(on["pull_request"], "paths")
      end

      test "#{file} never runs on a GitHub-hosted runner" do
        for {name, job} <- jobs(unquote(file)) do
          assert job["runs-on"] in [@fleet_ci, @macos_expr], "#{name}: #{inspect(job["runs-on"])}"
        end
      end

      test "#{file} keeps the root compiled tree: every checkout is clean: false, then cleaned" do
        for {name, job} <- jobs(unquote(file)) do
          steps = job["steps"]
          i = Enum.find_index(steps, &(&1["uses"] == "actions/checkout@v4"))
          assert get_in(Enum.at(steps, i), ["with", "clean"]) == false, name
          assert Enum.at(steps, i + 1)["run"] == ".github/scripts/clean-workspace.sh", name
        end
      end
    end

    test "the runner job runs the runner's whole gate in runner/, only when runner changed" do
      job = jobs(@runner_ci)["runner"]

      assert job["needs"] == ["changes"]
      assert job["if"] == "needs.changes.outputs.runner == 'true'"
      assert job["defaults"]["run"]["working-directory"] == "runner"

      assert Enum.filter(runs(job), &String.starts_with?(&1, "mix ")) ==
               [
                 "mix deps.get",
                 "mix compile --warnings-as-errors",
                 "mix deps.unlock --check-unused",
                 "mix format --check-formatted",
                 "mix credo --strict --config-file .credo.exs",
                 "mix dialyzer",
                 "mix test"
               ]
    end

    test "chg-ci carries every job of chg's ci.yml, each gated on chg" do
      jobs = jobs(@chg_ci)

      assert jobs |> Map.keys() |> Enum.sort() ==
               ~w(changes elixir-adapter generic-adapter rust typescript-adapter volume-setup)

      for {name, job} <- Map.delete(jobs, "changes") do
        assert job["needs"] == ["changes"], name
        assert job["if"] == "needs.changes.outputs.chg == 'true'", name
      end

      assert Enum.sort(get_in(jobs, ["rust", "strategy", "matrix", "include"])) ==
               [%{"os" => "linux"}, %{"os" => "macos"}]

      generic = runs(jobs["generic-adapter"])
      assert "python3 tests/loop-test.py" in generic
      assert "python3 tests/replay-selection-test.py" in generic
      assert jobs["generic-adapter"]["defaults"]["run"]["working-directory"] == "chg"

      assert "node --test test/unit.test.mjs test/integration.test.mjs" in runs(
               jobs["typescript-adapter"]
             )

      refute File.exists?("chg/.github")
    end
  end

  describe "ci.yml" do
    test "every job but changes, deploy and smoke needs changes and runs only on server" do
      jobs = jobs(@ci)
      gated = Map.drop(jobs, ["changes", "deploy", "smoke"])
      assert map_size(gated) > 0

      for {name, job} <- gated do
        assert "changes" in List.wrap(job["needs"]), name

        assert String.starts_with?(job["if"], "needs.changes.outputs.server == 'true' &&") or
                 job["if"] == "needs.changes.outputs.server == 'true'",
               "#{name}: #{inspect(job["if"])}"
      end
    end

    test "deploy runs on a master push in which nothing failed or was cancelled" do
      deploy = jobs(@ci)["deploy"]
      condition = String.replace(deploy["if"], ~r/\s+/, " ")

      assert "changes" in deploy["needs"]
      assert String.starts_with?(condition, "always() &&")
      assert condition =~ "github.ref == 'refs/heads/master'"
      assert condition =~ "!contains(needs.*.result, 'failure')"
      assert condition =~ "!contains(needs.*.result, 'cancelled')"
    end

    test "smoke follows a deploy that succeeded, whatever was skipped above it" do
      assert jobs(@ci)["smoke"]["if"] =~ "always() && needs.deploy.result == 'success'"
    end
  end

  defp workflow(path), do: YamlElixir.read_from_file!(path)
  defp jobs(path), do: workflow(path)["jobs"]

  defp runs(job), do: for(%{"run" => run} <- job["steps"], do: String.trim(run))

  defp areas!(repo, base, head) do
    {out, 0} = System.cmd("bash", [@areas, base, head], cd: repo, env: GitEnv.spawn_env())
    String.split(out, "\n", trim: true)
  end

  defp run_output!(repo, out, env) do
    {log, status} =
      System.cmd("bash", [@areas_output],
        cd: repo,
        env: GitEnv.spawn_env() ++ [{"GITHUB_OUTPUT", out} | env],
        stderr_to_stdout: true
      )

    assert status == 0, log
  end

  defp commit!(repo, path) do
    full = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, Base.encode16(:crypto.strong_rand_bytes(4)))
    git!(repo, ["add", path])
    git!(repo, ["commit", "-q", "-m", path])
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo, env: GitEnv.spawn_env())
    String.trim(sha)
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
