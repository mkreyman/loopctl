defmodule Loopctl.CLI.Commands.Admin do
  @moduledoc """
  CLI commands for superadmin operations.

  Commands:
  - `loopctl admin tenants`
  - `loopctl admin tenant <id>`
  - `loopctl admin suspend <tenant_id>`
  - `loopctl admin activate <tenant_id>`
  - `loopctl admin stats`
  - `loopctl admin impersonate <tenant_id> -- <command>`
  """

  alias Loopctl.CLI.Output

  @doc false
  @spec run(String.t(), [String.t()], keyword()) :: :ok
  def run(_command, _args, _opts) do
    Output.error("Admin commands not yet implemented")
  end
end
