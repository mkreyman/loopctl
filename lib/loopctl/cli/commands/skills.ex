defmodule Loopctl.CLI.Commands.Skills do
  @moduledoc """
  CLI commands for skill management.

  Commands:
  - `loopctl skill list`
  - `loopctl skill get <name>`
  - `loopctl skill create --name <name> --file <path>`
  - `loopctl skill update <name> --file <path>`
  - `loopctl skill stats <name>`
  - `loopctl skill history <name>`
  - `loopctl skill import <directory> --project <project>`
  - `loopctl skill archive <name>`
  """

  alias Loopctl.CLI.Output

  @doc false
  @spec run(String.t(), [String.t()], keyword()) :: :ok
  def run(_command, _args, _opts) do
    Output.error("Skill commands not yet implemented")
  end
end
