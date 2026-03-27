defmodule Loopctl.CLI.Commands.Tenants do
  @moduledoc """
  CLI commands for tenant management.

  Commands:
  - `loopctl tenant register --name <name> --email <email>`
  - `loopctl tenant info`
  - `loopctl tenant update --setting <key>=<value>`
  """

  alias Loopctl.CLI.Output

  @doc false
  @spec run(String.t(), [String.t()], keyword()) :: :ok
  def run(_command, _args, _opts) do
    Output.error("Tenant commands not yet implemented")
  end
end
