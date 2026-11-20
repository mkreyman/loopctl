defmodule Mix.Tasks.Loopctl.Run do
  @shortdoc "Runs one hand-filed story through a claude -p session in a worktree"

  @moduledoc """
  Build order step 1a: one story, one machine, no network, merging nothing.

      mix loopctl.run STORY.json [--config PATH] [--keep-worktree]

  `STORY.json` may be `-` to read the story from stdin. The config defaults to
  `~/.config/loopctl-runner/runner.json`; see `config/runner.example.json`.

  Prints one JSON summary line on stdout and exits 0 only when the session succeeded.
  Exit 2 is a refusal (bad config or a story outside the allow-list): nothing ran.
  """

  use Mix.Task

  alias LoopctlRunner.{Config, Run, Story}

  @switches [config: :string, keep_worktree: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    with [] <- invalid,
         [story_arg] <- args do
      Mix.Task.run("app.start")
      execute(story_arg, opts)
    else
      _ -> refuse("usage: mix loopctl.run STORY.json [--config PATH] [--keep-worktree]")
    end
  end

  defp execute(story_arg, opts) do
    config_path = Keyword.get(opts, :config, Config.default_path())

    with {:ok, config} <- Config.load(config_path),
         :ok <- Config.warn_if_hook_cannot_see_grants(config),
         {:ok, story} <- load_story(story_arg, config) do
      result = Run.execute(config, story, keep_worktree: Keyword.get(opts, :keep_worktree, false))
      Mix.shell().info(JSON.encode!(summary(result)))
      if result.status != "succeeded", do: exit({:shutdown, 1})
    else
      {:error, reason} -> refuse(reason)
    end
  end

  @doc false
  # The story `arg` names, `-` meaning the JSON on standard input, read by `read` so a test can
  # pass its own. Read as bytes, so a story decodes the same from stdin as from a file.
  def load_story(arg, config, read \\ fn -> IO.binread(:stdio, :eof) end)

  def load_story("-", config, read) do
    case read.() do
      raw when is_binary(raw) ->
        Story.from_json(raw, config)

      :eof ->
        {:error, "no story on standard input"}

      {:error, reason} ->
        {:error, "cannot read the story from standard input: #{inspect(reason)}"}
    end
  end

  def load_story(path, config, _read), do: Story.load(path, config)

  defp summary(result) do
    %{
      "run_id" => result.run_id,
      "run_dir" => result.run_dir,
      "status" => result.status,
      "error" => result.error,
      "session" => result.session && Map.new(result.session, fn {k, v} -> {k, stringify(v)} end),
      "teardown" => result.teardown && Map.new(result.teardown, fn {k, v} -> {k, inspect(v)} end)
    }
  end

  defp stringify(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify(v), do: v

  defp refuse(reason) do
    Mix.shell().error("refused: " <> reason)
    exit({:shutdown, 2})
  end
end
