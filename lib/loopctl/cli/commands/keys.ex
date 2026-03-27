defmodule Loopctl.CLI.Commands.Keys do
  @moduledoc """
  CLI commands for API key management.

  Commands:
  - `loopctl keys create --name <name> --role <role>`
  - `loopctl keys list`
  - `loopctl keys revoke <key_id>`
  - `loopctl keys rotate <key_id>`
  """

  alias Loopctl.CLI.Output

  @doc false
  @spec run(String.t(), [String.t()], keyword()) :: :ok
  def run(_command, _args, _opts) do
    Output.error("Keys commands not yet implemented")
  end
end
