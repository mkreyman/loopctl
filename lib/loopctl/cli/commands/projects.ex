defmodule Loopctl.CLI.Commands.Projects do
  @moduledoc """
  CLI commands for project management and import/export.

  Commands:
  - `loopctl project create <name> --repo <url>`
  - `loopctl project list`
  - `loopctl project info <project>`
  - `loopctl project archive <project>`
  - `loopctl import <path> --project <project>`
  - `loopctl export --project <project>`
  """

  alias Loopctl.CLI.Output

  @doc false
  @spec run(String.t(), [String.t()], keyword()) :: :ok
  def run(_command, _args, _opts) do
    Output.error("Project commands not yet implemented")
  end
end
