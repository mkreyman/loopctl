defmodule LoopctlRunner.LivenessTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.Liveness
  import LoopctlRunner.TestSupport

  @window 60_000
  @now 1_000_000_000

  defp obs(overrides) do
    Map.merge(
      %{
        now_ms: @now,
        last_stdout_ms: @now - 2 * @window,
        transcript_mtime_ms: @now - 2 * @window,
        subagents_mtime_ms: nil,
        agent_status: :idle
      },
      Map.new(overrides)
    )
  end

  describe "evaluate/2" do
    test "every signal quiet and the agents probe saying idle is parked" do
      assert {:parked, evidence} = Liveness.evaluate(obs([]), @window)
      assert evidence["agent_status"] == "idle"
      assert evidence["stdout_idle_ms"] == 2 * @window
      assert evidence["subagents_idle_ms"] == nil
    end

    test "a session absent from claude agents is positive evidence too" do
      assert {:parked, _} = Liveness.evaluate(obs(agent_status: :absent), @window)
    end

    test "any one recent signal is active, whatever the others say" do
      assert {:active, [:stdout]} = Liveness.evaluate(obs(last_stdout_ms: @now - 1), @window)

      assert {:active, [:transcript]} =
               Liveness.evaluate(obs(transcript_mtime_ms: @now - 1), @window)

      assert {:active, [:agents]} = Liveness.evaluate(obs(agent_status: :working), @window)
    end

    test "recent subagent writes suppress parking: a panel is legitimately running" do
      assert {:active, [:subagents]} =
               Liveness.evaluate(obs(subagents_mtime_ms: @now - 1), @window)
    end

    test "a solo session with no subagents directory is NOT parked while it writes its transcript" do
      assert {:active, [:transcript]} =
               Liveness.evaluate(
                 obs(subagents_mtime_ms: nil, transcript_mtime_ms: @now - 5),
                 @window
               )
    end

    test "silence plus a failed probe is not evidence of parking" do
      assert {:quiet, [:agents_unconfirmed]} =
               Liveness.evaluate(obs(agent_status: :unknown), @window)
    end

    test "a missing transcript is no evidence of activity" do
      assert {:parked, _} = Liveness.evaluate(obs(transcript_mtime_ms: nil), @window)
    end
  end

  describe "parse_agents/2" do
    test "reads interactive and background rows for the session" do
      rows =
        ~s([{"sessionId":"x","status":"busy"},{"sessionId":"y","state":"blocked"},{"sessionId":"z","state":"working"}])

      assert Liveness.parse_agents(rows, "x") == :working
      assert Liveness.parse_agents(rows, "y") == :idle
      assert Liveness.parse_agents(rows, "z") == :working
      assert Liveness.parse_agents(rows, "missing") == :absent
    end

    test "tolerates a warning line before the JSON, and reports garbage as unknown" do
      assert Liveness.parse_agents(~s(warning: x\n[{"sessionId":"x","status":"idle"}]), "x") ==
               :idle

      assert Liveness.parse_agents("no json here", "x") == :unknown
      assert Liveness.parse_agents(~s([{"sessionId":"x"}]), "x") == :unknown
    end
  end

  test "file_signals/2 finds the transcript by session id and the newest subagents write" do
    root = tmp_dir!("liveness")
    slug = Path.join(root, "-some-mangled-cwd")
    File.mkdir_p!(Path.join([slug, "sid-1", "subagents"]))
    File.write!(Path.join(slug, "sid-1.jsonl"), "{}\n")
    File.write!(Path.join([slug, "sid-1", "subagents", "agent-a.jsonl"]), "{}\n")
    File.touch!(Path.join(slug, "sid-1.jsonl"), 1_700_000_000)

    signals = Liveness.file_signals(root, "sid-1")
    assert signals.transcript_mtime_ms == 1_700_000_000_000
    assert signals.subagents_mtime_ms > signals.transcript_mtime_ms

    assert Liveness.file_signals(root, "sid-2") == %{
             transcript_mtime_ms: nil,
             subagents_mtime_ms: nil
           }
  end
end
