defmodule LoopctlRunner.StoryTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.Story
  alias Mix.Tasks.Loopctl.Run, as: LoopctlRun
  import LoopctlRunner.TestSupport

  setup do
    root = tmp_dir!("story")
    {:ok, config: config!(root), root: root}
  end

  test "a story inside the allow-list resolves its repo path", %{config: config, root: root} do
    assert {:ok, %Story{} = story} = Story.from_map(story_map(%{"model" => "haiku"}), config)
    assert story.repo_path == Path.join(root, "repo")
    assert story.model == "haiku"
  end

  test "loads from a file", %{config: config, root: root} do
    path = Path.join(root, "story.json")
    File.write!(path, JSON.encode!(story_map()))
    assert {:ok, %Story{id: "s1"}} = Story.load(path, config)
  end

  test "decodes from JSON text, and refuses what is not a JSON object", %{config: config} do
    assert {:ok, %Story{id: "s1"}} = Story.from_json(JSON.encode!(story_map()), config)
    assert {:error, "story is not valid JSON" <> _} = Story.from_json("{", config)
    assert {:error, "story must be a JSON object"} = Story.from_json("[]", config)
  end

  test "mix loopctl.run - reads the story from what it is handed, as bytes", %{config: config} do
    json = JSON.encode!(story_map())
    assert {:ok, %Story{id: "s1"}} = LoopctlRun.load_story("-", config, fn -> json end)

    assert {:error, "no story on standard input"} =
             LoopctlRun.load_story("-", config, fn -> :eof end)

    assert {:error, "cannot read the story from standard input: :terminated"} =
             LoopctlRun.load_story("-", config, fn -> {:error, :terminated} end)
  end

  describe "refuses by default" do
    test "an unconfigured repo", %{config: config} do
      assert {:error, "story repo \"loopctl\" is not in the runner allow-list"} =
               Story.from_map(story_map(%{"repo" => "loopctl"}), config)
    end

    test "a branch outside the allowed prefixes", %{config: config} do
      assert {:error, "story branch master is outside the allowed prefixes"} =
               Story.from_map(story_map(%{"branch" => "master"}), config)
    end

    test "a budget above the ceiling", %{config: config} do
      assert {:error, "story wall_clock_s 61 exceeds the runner ceiling 60"} =
               Story.from_map(story_map(%{"wall_clock_s" => 61}), config)

      assert {:error, "story max_turns 11 exceeds the runner ceiling 10"} =
               Story.from_map(story_map(%{"max_turns" => 11}), config)
    end

    test "an id that could escape the worktrees directory", %{config: config} do
      for id <- ["../x", "a/b", "", "UPPER", "a..b"] do
        assert {:error, "story id is missing or malformed"} =
                 Story.from_map(story_map(%{"id" => id}), config)
      end
    end

    test "a ref that looks like an option", %{config: config} do
      assert {:error, "story base is missing or malformed"} =
               Story.from_map(story_map(%{"base" => "--upload-pack=x"}), config)
    end

    test "an allowed_tools key is ignored, whatever it holds", %{config: config} do
      # Nothing composes --allowedTools any more, so the key grants nothing and reaches no
      # session: refusing a dispatch over it would tell loopctl this runner will not run the
      # story, for a capability question that does not exist.
      for tools <- [["Bash(mix test:*)"], "Bash", ["Bash", 1]] do
        assert {:ok, %Story{} = story} =
                 Story.from_map(story_map(%{"allowed_tools" => tools}), config)

        refute Map.has_key?(Story.to_map(story), :allowed_tools)
      end
    end

    test "a blank prompt", %{config: config} do
      assert {:error, "story prompt must be non-empty"} =
               Story.from_map(story_map(%{"prompt" => "  "}), config)
    end
  end

  test "a deferred prompt is nil until its run builds one; otherwise a missing one is refused", %{
    config: config
  } do
    no_prompt = Map.delete(story_map(), "prompt")

    assert {:ok, %Story{prompt: nil}} = Story.from_map(no_prompt, config, prompt: :deferred)
    assert {:error, "story prompt must be non-empty"} = Story.from_map(no_prompt, config)
  end

  describe "deadline_at (contract 1.19.0)" do
    test "is read as an instant, in UTC; absent is nil; malformed is refused", %{config: config} do
      assert {:ok, %Story{deadline_at: nil}} = Story.from_map(story_map(), config)

      assert {:ok, %Story{deadline_at: deadline}} =
               Story.from_map(story_map(%{"deadline_at" => "2026-09-28T12:00:00+02:00"}), config)

      assert deadline == ~U[2026-09-28 10:00:00Z]

      assert {:error, "story deadline_at is not an ISO-8601 date-time"} =
               Story.from_map(story_map(%{"deadline_at" => "tomorrow"}), config)
    end

    test "the stop comes at the EARLIER of start + wall clock and deadline_at less grace and margin",
         %{config: config} do
      start = ~U[2026-09-28 10:00:00.000Z]

      # A 10 s kill grace and a 5 s skew margin: the session is SIGNALLED 15 s before the deadline,
      # so TERM, the grace and a clock that far behind loopctl's all fit before it.
      stop_after = fn deadline ->
        {:ok, story} =
          Story.from_map(story_map(%{"wall_clock_s" => 30, "deadline_at" => deadline}), config)

        Story.stop_after(story, start, 10, 5)
      end

      # No deadline: the wall clock alone.
      assert stop_after.(nil) == {30_000, :wall_clock}
      # A deadline whose stop comes past the wall clock does not lengthen the session.
      assert stop_after.("2026-09-28T10:05:00Z") == {30_000, :wall_clock}
      # One before it shortens the session to deadline - grace - margin, measured from the START.
      assert stop_after.("2026-09-28T10:00:27.500Z") == {12_500, :deadline}
      # A tie is the wall clock's: the deadline did not bring the stop any earlier.
      assert stop_after.("2026-09-28T10:00:45Z") == {30_000, :wall_clock}
      # One whose stop is already behind the start stops it at once, never a negative timer.
      assert stop_after.("2026-09-28T10:00:10Z") == {0, :deadline}
    end

    test "stop_by is deadline_at less the kill grace and the margin" do
      assert Story.stop_by(nil, 10, 5) == nil
      assert Story.stop_by(~U[2026-09-28 10:00:15Z], 10, 5) == ~U[2026-09-28 10:00:00Z]
    end

    test "work may begin only with min_session_s of session left before stop_by", %{root: root} do
      # Production's minimum, not the suite's: this is the test of the guard itself.
      config = config!(root, %{"kill_grace_s" => 2, "min_session_s" => 60})
      now = ~U[2026-09-28 10:00:00Z]
      # What a session needs past the deadline's stop_by: the grace, the margin, then its minimum.
      room = config.kill_grace_s + Story.deadline_margin_s() + config.min_session_s
      at = fn seconds -> DateTime.add(now, seconds, :second) end

      # A session budget longer than the minimum: the minimum is the floor.
      wall_clock_s = 1800

      assert Story.check_deadline(nil, wall_clock_s, config, now) == :ok
      # Exactly the minimum left: work may begin.
      assert Story.check_deadline(at.(room), wall_clock_s, config, now) == :ok

      # A second short of it: a session started now would be stopped almost at once, so it counts
      # as past — though stop_by itself is still 59 s away.
      assert {:passed, detail} = Story.check_deadline(at.(room - 1), wall_clock_s, config, now)
      assert detail =~ ~r/^deadline_passed: /
      assert detail =~ "less than 60s of session"

      # Inside the grace, and long gone: passed all the same.
      assert {:passed, _} =
               Story.check_deadline(at.(config.kill_grace_s), wall_clock_s, config, now)

      assert {:passed, _} = Story.check_deadline(at.(-60), wall_clock_s, config, now)
    end

    test "the minimum runtime is capped by the session's own wall clock", %{root: root} do
      # A dispatch asking for 20 s of session is asking for exactly that much: measured against the
      # 60 s minimum it would be refused however early it came.
      config = config!(root, %{"kill_grace_s" => 2, "min_session_s" => 60})
      now = ~U[2026-09-28 10:00:00Z]
      at = fn seconds -> DateTime.add(now, seconds, :second) end
      room = config.kill_grace_s + Story.deadline_margin_s() + 20

      assert Story.check_deadline(at.(room), 20, config, now) == :ok
      assert {:passed, detail} = Story.check_deadline(at.(room - 1), 20, config, now)
      assert detail =~ "less than 20s of session"
    end

    test "a dispatch's deadline_at is parsed to an instant; absent is nil" do
      assert Story.deadline!(nil) == nil
      assert Story.deadline!("2026-09-28T12:00:00+02:00") == ~U[2026-09-28 10:00:00Z]
    end

    test "an instant already parsed is kept as it is", %{config: config} do
      # A dispatch's deadline reaches `from_map/3` as the instant `DispatchPolicy.decide/3` parsed.
      assert {:ok, %Story{deadline_at: ~U[2026-09-28 10:00:00Z]}} =
               Story.from_map(story_map(%{"deadline_at" => ~U[2026-09-28 10:00:00Z]}), config)
    end
  end
end
