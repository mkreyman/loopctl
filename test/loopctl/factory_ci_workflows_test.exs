defmodule Loopctl.FactoryCiWorkflowsTest do
  @moduledoc """
  US-52.6: CI judges runner/ and chg/ inside the loopctl repository, each only when it changed.

  `.github/scripts/changed-areas.sh` is run against throwaway repositories; the four
  workflows (ci, runner-ci, chg-ci, e2e) are read as YAML. A job gated by area is skipped by its `if:`, never by
  `on.paths`, because a required check on a workflow filtered out by paths stays pending.
  """
  use ExUnit.Case, async: true

  alias Loopctl.DeliveryGates.GitEnv

  @areas Path.expand(".github/scripts/changed-areas.sh")
  @areas_output Path.expand(".github/scripts/areas-output.sh")
  @ci ".github/workflows/ci.yml"
  @runner_ci ".github/workflows/runner-ci.yml"
  @chg_ci ".github/workflows/chg-ci.yml"
  @e2e ".github/workflows/e2e.yml"
  # The jobs the area gate does not wait on: scale-nightly is dispatch-only, live is nightly
  # and dispatch-only, and deploy and smoke ship master rather than check a change (smoke
  # gates nothing by design).
  @not_on_push %{
    ".github/workflows/ci.yml" => ["scale-nightly", "deploy", "smoke"],
    ".github/workflows/e2e.yml" => ["live"]
  }
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
        {"GITHUB_REF", "refs/heads/master"},
        {"EVENT_BEFORE", base},
        {"GITHUB_SHA", head}
      ])

      assert File.read!(out) == "server=false\nrunner=false\nchg=true\ne2e=false\n"

      File.rm!(out)
      run_output!(repo, out, [{"GITHUB_EVENT_NAME", "schedule"}])
      assert File.read!(out) == "server=true\nrunner=true\nchg=true\ne2e=true\n"
    end

    # Finding 10: a later push on a branch cancels the earlier push's run (per-ref
    # cancel-in-progress), so a run judged only on before..sha never covered the earlier
    # push's areas. A branch push is judged from its merge base with master.
    test "a branch push is judged on the whole branch, from its merge base with master", %{
      repo: repo,
      base: base
    } do
      git!(repo, ["update-ref", "refs/remotes/origin/master", base])
      git!(repo, ["checkout", "-q", "-b", "feature/x", base])
      first = commit!(repo, "lib/loopctl.ex")
      head = commit!(repo, "runner/lib/a.ex")
      out = Path.join(repo, "out")

      for before <- [first, String.duplicate("0", 40)] do
        run_output!(repo, out, [
          {"GITHUB_EVENT_NAME", "push"},
          {"GITHUB_REF", "refs/heads/feature/x"},
          {"EVENT_BEFORE", before},
          {"GITHUB_SHA", head}
        ])

        assert File.read!(out) == "server=true\nrunner=true\nchg=false\ne2e=false\n", before
        File.rm!(out)
      end
    end

    test "a branch push whose merge base cannot be found counts as every area", %{
      repo: repo,
      base: base
    } do
      git!(repo, ["checkout", "-q", "-b", "feature/x", base])
      head = commit!(repo, "runner/lib/a.ex")
      out = Path.join(repo, "out")

      run_output!(repo, out, [
        {"GITHUB_EVENT_NAME", "push"},
        {"GITHUB_REF", "refs/heads/feature/x"},
        {"EVENT_BEFORE", base},
        {"GITHUB_SHA", head}
      ])

      assert File.read!(out) == "server=true\nrunner=true\nchg=true\ne2e=true\n"
    end

    # Finding 11: runner-ci and e2e.yml install Erlang and Elixir from the root pin.
    test "the root .tool-versions counts as server, runner and e2e", %{repo: repo, base: base} do
      head = commit!(repo, ".tool-versions")

      assert areas!(repo, base, head) == ["e2e", "runner", "server"]
    end
  end

  describe "every factory workflow" do
    for file <- [@ci, @runner_ci, @chg_ci, @e2e] do
      test "#{file} runs on a push of every branch and never on a pull request" do
        on = workflow(unquote(file))["on"]

        assert on["push"] == %{"branches" => ["**"]}
        refute Map.has_key?(on, "pull_request")
        refute Map.has_key?(on, "pull_request_target")

        text = File.read!(unquote(file))
        refute text =~ "github.event.pull_request"
        refute text =~ ~r/event_name\s*[!=]=\s*'pull_request'/
      end

      test "#{file} ends in an area gate that needs every job a push can run" do
        jobs = jobs(unquote(file))
        gate = jobs["area-gate"]

        assert gate["name"] == "area gate"
        assert gate["if"] == "always()"
        assert gate["runs-on"] == "ubuntu-latest"

        push_jobs =
          jobs
          |> Map.drop(["area-gate" | Map.get(@not_on_push, unquote(file), [])])
          |> Map.keys()
          |> Enum.sort()

        assert "changes" in push_jobs
        assert Enum.sort(gate["needs"]) == push_jobs
      end

      test "#{file} runs its changes job on every event" do
        refute Map.has_key?(jobs(unquote(file))["changes"], "if")
      end
    end

    test "the area gate is the same step in all four workflows" do
      [first | rest] = for file <- [@ci, @runner_ci, @chg_ci, @e2e], do: gate_step(file)

      for step <- rest, do: assert(step == first)
    end

    test "the area gate passes only when changes succeeded and nothing failed or was cancelled" do
      step = gate_step(@ci)

      cases = [
        {%{"changes" => "success", "lint" => "success", "test" => "skipped"}, 0},
        {%{"changes" => "success", "lint" => "skipped"}, 0},
        {%{"changes" => "success", "lint" => "failure"}, 1},
        {%{"changes" => "success", "lint" => "cancelled"}, 1},
        {%{"changes" => "skipped", "lint" => "skipped"}, 1},
        {%{"changes" => "failure", "lint" => "skipped"}, 1},
        {%{"changes" => "cancelled"}, 1},
        {%{"lint" => "success"}, 1}
      ]

      for {results, want} <- cases do
        needs =
          Map.new(results, fn {job, result} -> {job, %{"result" => result, "outputs" => %{}}} end)

        {log, status} =
          System.cmd("bash", ["-e", "-c", step["run"]],
            env: [{"NEEDS", Jason.encode!(needs)}],
            stderr_to_stdout: true
          )

        assert status == want, "#{inspect(results)}: #{log}"
      end
    end

    test "runner-ci and chg-ci run nightly with ci.yml, so the every-area run covers them" do
      for file <- [@runner_ci, @chg_ci] do
        assert workflow(file)["on"]["schedule"] == [%{"cron" => "0 2 * * *"}], file
      end
    end
  end

  describe "runner-ci.yml and chg-ci.yml" do
    for file <- [@runner_ci, @chg_ci] do
      test "#{file} runs every job but its area gate on the fleet-ci pool" do
        for {name, job} <- Map.delete(jobs(unquote(file)), "area-gate") do
          assert job["runs-on"] in [@fleet_ci, @macos_expr], "#{name}: #{inspect(job["runs-on"])}"
        end
      end

      test "#{file} keeps the root compiled tree: every checkout is clean: false, then cleaned" do
        for {name, job} <- Map.delete(jobs(unquote(file)), "area-gate") do
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
               ~w(area-gate changes elixir-adapter generic-adapter rust typescript-adapter volume-setup)

      for {name, job} <- Map.drop(jobs, ["changes", "area-gate"]) do
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
    test "every job but changes, deploy, smoke and the area gate needs changes and runs only on server" do
      jobs = jobs(@ci)
      gated = Map.drop(jobs, ["changes", "deploy", "smoke", "area-gate"])
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

  defp gate_step(file) do
    assert [step] = jobs(file)["area-gate"]["steps"], file
    assert step["env"] == %{"NEEDS" => "${{ toJSON(needs) }}"}, file
    step
  end

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
