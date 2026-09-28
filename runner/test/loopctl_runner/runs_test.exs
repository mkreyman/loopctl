defmodule LoopctlRunner.RunsTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.{Control, ControlConfig, Owner, Runs, RunState}
  import LoopctlRunner.TestSupport

  defp finished(runs_dir, name, finished_at) do
    run_dir = Path.join(runs_dir, name)
    File.mkdir_p!(run_dir)

    RunState.update(
      run_dir,
      Map.merge(owner!(), %{
        "run_id" => name,
        "status" => "succeeded",
        "finished_at" => finished_at
      })
    )
  end

  test "an unparseable finished_at is skipped, not reported, and cannot fail the join" do
    root = tmp_dir!("runs")
    config = config!(root)

    finished(config.runs_dir, "good", "2026-09-12T10:00:00Z")
    # Both sort above the good one as strings; neither is a date-time the contract accepts.
    finished(config.runs_dir, "no-offset", "2026-09-13T10:00:00")
    finished(config.runs_dir, "garbage", "yesterday")

    assert Runs.last_success_at(config.runs_dir) == "2026-09-12T10:00:00Z"

    capacity = %{"cores" => 4, "memory_mb" => 8_000}

    control = %ControlConfig{
      url: "wss://loopctl.example/runner/socket/websocket",
      runner_id: "3781bee6-2b97-4df0-9664-7f01a492630f",
      machine: "minis",
      token_file: Path.join(root, "token"),
      repos: ["mkreyman/home_care_billing"],
      max_sessions: 1,
      status_interval_s: 30
    }

    assert {:ok, %{"sample" => %{"last_build_at" => "2026-09-12T10:00:00Z"}}} =
             Control.join_payload(%{config | control: control}, capacity, false)
  end

  test "success times are compared as times, not as strings" do
    root = tmp_dir!("runs-order")
    config = config!(root)

    finished(config.runs_dir, "later", "2026-09-12T10:00:00Z")
    # Earlier in UTC, though its string sorts higher.
    finished(config.runs_dir, "earlier", "2026-09-12T11:00:00+05:00")

    assert Runs.last_success_at(config.runs_dir) == "2026-09-12T10:00:00Z"
  end
end
