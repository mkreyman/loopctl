defmodule Loopctl.CLI.Commands.Status do
  @moduledoc """
  CLI commands for progress and status queries.

  Commands:
  - `loopctl status --project <project>`
  - `loopctl status --epic <epic_number>`
  - `loopctl status <story_number>`
  - `loopctl next --project <project>`
  - `loopctl blocked --project <project>`
  """

  alias Loopctl.CLI.Output

  @doc false
  @spec run(String.t(), [String.t()], keyword()) :: :ok
  def run(_command, _args, _opts) do
    Output.error("Status commands not yet implemented")
  end
end
