defmodule Mix.Tasks.Loopctl.Reap do
  @shortdoc "Kills process groups and removes worktrees left by dead runs"

  @moduledoc """
      mix loopctl.reap [--config PATH]

  The same cleanup `mix loopctl.run` performs before every run, on demand.
  """

  use Mix.Task

  alias LoopctlRunner.{Config, Reaper}

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _invalid} = OptionParser.parse(argv, strict: [config: :string])
    Mix.Task.run("app.start")

    case Config.load(Keyword.get(opts, :config, Config.default_path())) do
      {:ok, config} ->
        config.runs_dir
        |> Reaper.reap(config.kill_grace_s * 1000, config.grant_dir,
          projects_dir: config.claude_projects_dir
        )
        |> Enum.each(&Mix.shell().info(JSON.encode!(&1)))

      {:error, reason} ->
        Mix.shell().error("refused: " <> reason)
        exit({:shutdown, 2})
    end
  end
end
