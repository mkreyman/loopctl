defmodule Loopctl.CLI.Commands.Orchestrator do
  @moduledoc """
  CLI commands for orchestrator operations.

  Commands:
  - `loopctl verify <story_number> --result <pass|fail|partial> --summary <text>`
  - `loopctl reject <story_number> --reason <text>`
  - `loopctl pending --project <project>`
  - `loopctl state save --project <project> --data <json>`
  - `loopctl state load --project <project>`
  """

  alias Loopctl.CLI.Output

  @doc false
  @spec run(String.t(), [String.t()], keyword()) :: :ok
  def run(_command, _args, _opts) do
    Output.error("Orchestrator commands not yet implemented")
  end
end
