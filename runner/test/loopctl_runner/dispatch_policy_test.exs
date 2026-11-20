defmodule LoopctlRunner.DispatchPolicyTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.{ControlConfig, DispatchPolicy}
  import LoopctlRunner.TestSupport

  @dispatch %{
    "dispatch_id" => "7d0c1f6e-3b1a-4f7e-9c2d-5a6b7c8d9e0f",
    "story_id" => "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b",
    "kind" => "implement",
    "repo" => "mkreyman/home_care_billing",
    "base_branch" => "master",
    "branch" => "loop/story-1",
    "claim_epoch" => 3,
    "wall_clock_seconds" => 1800,
    "max_turns" => 100,
    "token_budget" => nil
  }

  @ready %{draining: false, in_flight: 0, free_disk_mb: &__MODULE__.plenty/1}

  def plenty(_path), do: 50_000

  setup do
    root = tmp_dir!("policy")
    base = config!(root)

    control = %ControlConfig{
      url: "wss://loopctl.example/runner/socket/websocket",
      runner_id: "3781bee6-2b97-4df0-9664-7f01a492630f",
      machine: "minis",
      token_file: Path.join(root, "token"),
      repos: ["mkreyman/home_care_billing"],
      max_sessions: 2,
      accepts_dispatches: true
    }

    config = %{
      base
      | control: control,
        repos: %{"home_care_billing" => root},
        branch_prefixes: ["loop/"],
        max_wall_clock_s: 3600,
        max_turns: 200
    }

    {:ok, config: config, root: root}
  end

  defp decide(ctx, dispatch \\ @dispatch, state \\ @ready, control \\ %{}) do
    config = %{ctx.config | control: Map.merge(ctx.config.control, control)}
    DispatchPolicy.decide(dispatch, config, state)
  end

  defp reason({:refuse, reason, _detail}), do: reason
  defp reason(other), do: other

  test "a dispatch inside every limit is accepted with the fields a story is built from", ctx do
    assert {:accept, story} = decide(ctx)
    root = ctx.root

    assert %{
             repo: "home_care_billing",
             repo_path: ^root,
             base: "master",
             branch: "loop/story-1",
             wall_clock_s: 1800,
             max_turns: 100
           } = story
  end

  describe "deadline_at (contract 1.19.0)" do
    @now ~U[2026-09-28 10:00:00Z]

    defp at(seconds), do: @now |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()

    defp decide_at(ctx, deadline),
      do: decide(ctx, Map.put(@dispatch, "deadline_at", deadline), Map.put(@ready, :now, @now))

    test "is parsed once, into the instant the accepted fields carry", ctx do
      assert {:accept, %{deadline_at: deadline}} = decide_at(ctx, at(3600))
      assert deadline == DateTime.add(@now, 3600, :second)

      assert {:accept, %{deadline_at: nil}} = decide(ctx, @dispatch, Map.put(@ready, :now, @now))
    end

    test "one that leaves no time to stop a session by then is refused other, never a capability",
         ctx do
      room =
        ctx.config.kill_grace_s + LoopctlRunner.Story.deadline_margin_s() +
          ctx.config.min_session_s

      # Still in the future, but a second short of the grace, the skew margin and the least
      # session worth starting.
      assert {:refuse, "other", detail} = decide_at(ctx, at(room - 1))
      assert detail =~ ~r/^deadline_passed: /
      assert {:refuse, "other", _} = decide_at(ctx, at(-60))

      # One second more and there is time.
      assert {:accept, _} = decide_at(ctx, at(room))
    end

    test "the minimum runtime is the dispatch's own wall clock when that is shorter", ctx do
      # 60 s minimum, a 20 s dispatch: 20 s before stop_by is enough for it.
      ctx = %{ctx | config: %{ctx.config | min_session_s: 60}}
      short = Map.put(@dispatch, "wall_clock_seconds", 20)
      room = ctx.config.kill_grace_s + LoopctlRunner.Story.deadline_margin_s() + 20
      state = Map.put(@ready, :now, @now)

      assert {:accept, _} = decide(ctx, Map.put(short, "deadline_at", at(room)), state)

      assert {:refuse, "other", "deadline_passed: " <> _} =
               decide(ctx, Map.put(short, "deadline_at", at(room - 1)), state)
    end
  end

  test "a dispatch whose previous sessionless run is still ending is refused busy, for now",
       ctx do
    # A moment, not a capability: `other`, which loopctl places again — never `kind_not_supported`.
    assert {:refuse, "other", "busy: " <> _} =
             decide(ctx, @dispatch, Map.put(@ready, :ending, true))

    assert {:accept, _} = decide(ctx, @dispatch, Map.put(@ready, :ending, false))
  end

  test "nothing is accepted unless the runner is configured to accept dispatches", ctx do
    assert reason(decide(ctx, @dispatch, @ready, %{accepts_dispatches: false})) ==
             "dispatches_disabled"

    # The default of a config that never mentions it.
    assert %ControlConfig{accepts_dispatches: false} = struct(ControlConfig, [])
  end

  test "the refusal says WHICH dispatches_disabled this is, and never says nothing", ctx do
    # One reason, two conditions — a machine configured not to take work, and a foreground
    # `mix loopctl.serve` run refusing by default. From loopctl's side the reason alone cannot
    # tell them apart, so the caller supplies the alternative wording.
    off = %{accepts_dispatches: false}
    foreground = "a foreground dev run refuses dispatches by default"

    assert {:refuse, "dispatches_disabled", ^foreground} =
             decide(ctx, @dispatch, Map.put(@ready, :dispatches_disabled_detail, foreground), off)

    # Absent, and the configured case keeps its own sentence.
    configured = "this runner is not configured to accept dispatches"
    assert {:refuse, "dispatches_disabled", ^configured} = decide(ctx, @dispatch, @ready, off)

    # An empty or nil detail is never sent: a detail that says nothing is worse than the default,
    # because loopctl would have to special-case it.
    for empty <- ["", nil] do
      state = Map.put(@ready, :dispatches_disabled_detail, empty)
      assert {:refuse, "dispatches_disabled", ^configured} = decide(ctx, @dispatch, state, off)
    end
  end

  test "draining and capacity come before anything about the dispatch itself", ctx do
    bad_repo = %{@dispatch | "repo" => "someone/else"}
    assert reason(decide(ctx, bad_repo, %{@ready | draining: true})) == "draining"
    assert reason(decide(ctx, bad_repo, %{@ready | in_flight: 2})) == "at_capacity"
    assert reason(decide(ctx, @dispatch, %{@ready | in_flight: 1})) != "at_capacity"
  end

  test "too little free disk, or none measured, is refused", ctx do
    assert reason(decide(ctx, @dispatch, %{@ready | free_disk_mb: fn _ -> 100 end})) ==
             "insufficient_disk"

    assert reason(decide(ctx, @dispatch, %{@ready | free_disk_mb: fn _ -> nil end})) ==
             "insufficient_disk"
  end

  test "the repo checkout's volume is checked, not only the runs directory's", ctx do
    repo_path = ctx.root
    test = self()

    low_on_repo = fn
      ^repo_path -> 100
      path -> send(test, {:checked, path}) && 50_000
    end

    assert {:refuse, "insufficient_disk", detail} =
             decide(ctx, @dispatch, %{@ready | free_disk_mb: low_on_repo})

    assert detail =~ "under #{repo_path}"
    runs_dir = ctx.config.runs_dir
    assert_received {:checked, ^runs_dir}

    # The runs directory's volume can refuse on its own too.
    low_on_runs = fn
      ^runs_dir -> nil
      _ -> 50_000
    end

    assert reason(decide(ctx, @dispatch, %{@ready | free_disk_mb: low_on_runs})) ==
             "insufficient_disk"
  end

  test "a repo must be allowed by control.repos and have a local checkout", ctx do
    assert reason(decide(ctx, %{@dispatch | "repo" => "someone/else"})) == "repo_not_allowed"

    unmapped = %{ctx | config: %{ctx.config | repos: %{"other" => ctx.root}}}
    assert reason(decide(unmapped)) == "repo_not_allowed"
    assert reason(decide(ctx, Map.delete(@dispatch, "repo"))) == "repo_not_allowed"
  end

  test "the branch must carry an allowed prefix, and both refs be plain ref names", ctx do
    assert reason(decide(ctx, %{@dispatch | "branch" => "master"})) == "branch_not_allowed"

    assert reason(decide(ctx, %{@dispatch | "branch" => "loop/../master"})) ==
             "branch_not_allowed"

    assert reason(decide(ctx, %{@dispatch | "base_branch" => "-x"})) == "branch_not_allowed"
  end

  test "triage is held to plain ref names only, never to the prefixes", ctx do
    # It never writes its `branch`: loopctl sends a triage with the BASE as its branch, run on a
    # detached tree. On 2026-11-06 minis (prefixes ["loop/"]) refused every triage dispatch
    # `master is outside ["loop/"]`.
    assert {:accept, _} = decide(ctx, %{@dispatch | "kind" => "triage", "branch" => "master"})

    assert reason(decide(ctx, %{@dispatch | "kind" => "triage", "branch" => "loop/../master"})) ==
             "branch_not_allowed"

    # A retired review kind has no exemption left to claim.
    assert reason(decide(ctx, %{@dispatch | "kind" => "review", "branch" => "master"})) ==
             "branch_not_allowed"

    # The branches this machine DOES write stay inside its prefixes.
    assert reason(decide(ctx, %{@dispatch | "branch" => "master"})) == "branch_not_allowed"
  end

  test "reply_draft (:draft) is exempt from the prefixes too, and still held to plain refs",
       ctx do
    # US-48.9: a draft writes no branch at all — loopctl names the base for both refs.
    draft = %{@dispatch | "kind" => "reply_draft", "branch" => "master"}
    assert {:accept, _} = decide(ctx, draft)

    assert reason(decide(ctx, %{draft | "branch" => "loop/../master"})) == "branch_not_allowed"
    assert reason(decide(ctx, %{draft | "base_branch" => "-x"})) == "branch_not_allowed"
  end

  test "wall clock and turns over this runner's own limits are refused", ctx do
    assert reason(decide(ctx, %{@dispatch | "wall_clock_seconds" => 3601})) ==
             "wall_clock_exceeds_limit"

    assert reason(decide(ctx, %{@dispatch | "max_turns" => 201})) == "max_turns_exceeds_limit"

    assert {:accept, _} =
             decide(ctx, %{@dispatch | "wall_clock_seconds" => 3600, "max_turns" => 200})
  end

  test "a configured token budget refuses a larger budget and a dispatch with none", ctx do
    limited = %{max_token_budget: 1_000_000}
    assert {:accept, _} = decide(ctx, %{@dispatch | "token_budget" => 500_000}, @ready, limited)

    assert reason(decide(ctx, %{@dispatch | "token_budget" => 2_000_000}, @ready, limited)) ==
             "token_budget_exceeds_limit"

    assert reason(decide(ctx, @dispatch, @ready, limited)) == "token_budget_exceeds_limit"
    # With no limit configured, a dispatch without a budget is fine.
    assert {:accept, _} = decide(ctx)
  end

  test "the config reads accepts_dispatches as a strict boolean, false when absent" do
    base = %{
      "url" => "wss://loopctl.example/runner/socket/websocket",
      "runner_id" => "3781bee6-2b97-4df0-9664-7f01a492630f",
      "machine" => "minis",
      "token_file" => "/tmp/token",
      "repos" => ["mkreyman/home_care_billing"],
      "max_sessions" => 1
    }

    assert {:ok, %ControlConfig{accepts_dispatches: false, max_token_budget: nil}} =
             ControlConfig.from_map(base)

    assert {:ok, %ControlConfig{accepts_dispatches: true}} =
             ControlConfig.from_map(Map.put(base, "accepts_dispatches", true))

    assert {:error, _} = ControlConfig.from_map(Map.put(base, "accepts_dispatches", "yes"))
    assert {:error, _} = ControlConfig.from_map(Map.put(base, "max_token_budget", 0))
  end

  describe "delivery_mode/1" do
    test "pr, after a byte-order mark, whitespace and case are set aside" do
      for raw <- ["pr", "PR\n", "\uFEFF pr ", "  Pr \r\n"] do
        assert DispatchPolicy.delivery_mode({:ok, raw}) == {:ok, "pr"}, inspect(raw)
      end
    end

    test "thread is refused as retired, however it is spelled" do
      # loopctl retired change threads in contract 1.23.0: nothing merges a thread session's pushes.
      for raw <- ["thread", "thread\n", "  Thread \r\n", "\uFEFFthread\n", "THREAD"] do
        assert {:refuse, "other", detail} = DispatchPolicy.delivery_mode({:ok, raw}), inspect(raw)
        assert detail =~ "delivery mode thread in .loopctl/mode was retired"
        assert detail =~ "set it to pr"
      end
    end

    test "no file refuses: pr merges unattended, and a repository that never opted in did not ask" do
      assert DispatchPolicy.delivery_mode(:absent) ==
               {:refuse, "other", "repository has no .loopctl/mode"}
    end

    test "an empty file refuses too: only an explicit pr runs" do
      for raw <- ["", "\n", "\uFEFF  \n"] do
        assert {:refuse, "other", detail} = DispatchPolicy.delivery_mode({:ok, raw}), inspect(raw)
        assert detail =~ "malformed delivery mode \"\" in .loopctl/mode"
      end
    end

    test "any other value refuses, naming what was found, never falling back to pr" do
      for raw <- ["threads", "thread pr", "yolo\n", "prr"] do
        assert {:refuse, "other", detail} = DispatchPolicy.delivery_mode({:ok, raw})
        assert detail =~ "malformed delivery mode #{inspect(String.trim(raw))}", inspect(raw)
      end

      assert {:refuse, "other", "malformed delivery mode in .loopctl/mode: not UTF-8 text"} =
               DispatchPolicy.delivery_mode({:ok, <<0xFF, 0xFE>>})
    end

    test "a mode that could not be read refuses too" do
      assert {:refuse, "other", detail} = DispatchPolicy.delivery_mode({:error, "too large"})
      assert detail =~ "could not be read: too large"
    end
  end
end
