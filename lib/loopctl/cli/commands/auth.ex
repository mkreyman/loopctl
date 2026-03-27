defmodule Loopctl.CLI.Commands.Auth do
  @moduledoc """
  CLI commands for authentication and tenant management.

  Commands:
  - `loopctl auth login --server <url> --key <key>` -- configure credentials
  - `loopctl auth whoami` -- show current identity
  - `loopctl tenant register --name <name> --email <email>` -- register tenant
  - `loopctl tenant info` -- current tenant info
  - `loopctl tenant update --setting <key>=<value>` -- update settings
  """

  alias Loopctl.CLI.Output

  @doc false
  @spec run(String.t(), [String.t()], keyword()) :: :ok
  def run(_command, _args, _opts) do
    Output.error("Auth commands not yet implemented")
  end
end
