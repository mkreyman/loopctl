defmodule Loopctl.CLI.Commands.Agent do
  @moduledoc """
  CLI commands for agent operations.

  Commands:
  - `loopctl agent register --name <name> --type <type>`
  - `loopctl contract <story_number>`
  - `loopctl claim <story_number>`
  - `loopctl start <story_number>`
  - `loopctl report <story_number> --artifact <json>`
  - `loopctl unclaim <story_number>`
  """

  alias Loopctl.CLI.Output

  @doc false
  @spec run(String.t(), [String.t()], keyword()) :: :ok
  def run(_command, _args, _opts) do
    Output.error("Agent commands not yet implemented")
  end
end
