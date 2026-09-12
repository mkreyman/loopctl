defmodule LoopctlRunner.StoryTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.Story
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

    test "a tool permission the runner does not allow", %{root: root} do
      config = config!(root, %{"allowed_tools" => ["Bash(mix test:*)"]})

      assert {:ok, %Story{allowed_tools: ["Bash(mix test:*)"]}} =
               Story.from_map(story_map(%{"allowed_tools" => ["Bash(mix test:*)"]}), config)

      assert {:error, "story allowed_tools [\"Bash\"] are not in the runner allow-list"} =
               Story.from_map(
                 story_map(%{"allowed_tools" => ["Bash(mix test:*)", "Bash"]}),
                 config
               )
    end

    test "a blank prompt", %{config: config} do
      assert {:error, "story prompt must be non-empty"} =
               Story.from_map(story_map(%{"prompt" => "  "}), config)
    end
  end
end
