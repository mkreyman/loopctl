defmodule LoopctlE2e.TwoSessionsLiveTest do
  @moduledoc """
  TC-52.20.1..6 live: `two_sessions_one_repo` against loopctl.com with two real MCP server
  processes on this machine. Tagged :live and :two_sessions_one_repo; it needs
  LOOPCTL_E2E_AGENT_KEY (a plain agent key: the sessions register holders with it) and runs
  alone with `mix e2e --only two_sessions_one_repo`. The lapse wait makes it take about 16
  minutes. Every step goes to stage-log/<run_id>-two-sessions.log.
  """
  use ExUnit.Case, async: true

  alias LoopctlE2e.Mcp
  alias LoopctlE2e.Run
  alias LoopctlE2e.TwoSessions

  @moduletag :live
  @moduletag :two_sessions_one_repo
  @moduletag timeout: :infinity

  @tag :tmp_dir
  test "two sessions on one machine and one repo never collide", %{tmp_dir: dir} do
    {sandbox, _} = Code.eval_file(Path.expand("../../config/sandbox.exs", __DIR__))
    agent_key = System.get_env("LOOPCTL_E2E_AGENT_KEY")
    assert agent_key not in [nil, ""], "LOOPCTL_E2E_AGENT_KEY is not set"
    assert sandbox.project_id not in [nil, ""], "LOOPCTL_E2E_PROJECT_ID is not set"
    node = System.find_executable("node") || flunk("node is not on PATH")

    run_id = Run.run_id()
    File.mkdir_p!("stage-log")
    log_path = Path.join("stage-log", "#{run_id}-two-sessions.log")

    log = fn line ->
      stamped = "#{DateTime.utc_now() |> DateTime.to_iso8601()} #{line}\n"
      File.write!(log_path, stamped, [:append])
      IO.write(stamped)
    end

    server = System.get_env("LOOPCTL_E2E_SERVER", "https://loopctl.com")
    index = Path.expand("../../../mcp-server/index.js", __DIR__)

    start_session = fn %{worktree: worktree, session_id: session_id} ->
      Mcp.start(
        node: node,
        index: index,
        cwd: worktree,
        env: [
          {"LOOPCTL_SERVER", server},
          {"LOOPCTL_AGENT_KEY", agent_key},
          {"CLAUDE_SESSION_ID", session_id},
          # The session id must be this one, never one this test process inherited.
          {"CLAUDE_CODE_SESSION_ID", false},
          # One key per process: the scenario's sessions are agents and nothing else.
          {"LOOPCTL_ORCH_KEY", false},
          {"LOOPCTL_USER_KEY", false},
          {"LOOPCTL_E2E_ORCH_KEY", false},
          {"LOOPCTL_E2E_AGENT_KEY", false},
          {"E2E_GITHUB_TOKEN", false}
        ]
      )
    end

    deps = %{
      start_session: start_session,
      call: &Mcp.call/3,
      kill: &Mcp.kill/1,
      stop: &Mcp.stop/1,
      git: fn args ->
        case System.cmd("git", args, stderr_to_stdout: true) do
          {_, 0} -> :ok
          {out, status} -> {:error, "exit #{status}: #{String.trim(out)}"}
        end
      end,
      now_ms: fn -> System.monotonic_time(:millisecond) end,
      utc_now: &DateTime.utc_now/0,
      sleep: &Process.sleep/1,
      log: log
    }

    cfg = %{
      project_id: sandbox.project_id,
      repo_url: "https://github.com/#{sandbox.repo}.git",
      run_id: run_id,
      dir: dir
    }

    case TwoSessions.run(cfg, deps) do
      {:ok, _ctx} -> log.("two_sessions_one_repo #{run_id}: passed")
      {:error, failure} -> flunk(TwoSessions.describe(failure))
    end
  end
end
