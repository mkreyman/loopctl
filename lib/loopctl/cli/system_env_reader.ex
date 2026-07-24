defmodule Loopctl.CLI.SystemEnvReader do
  @moduledoc """
  Default `Loopctl.CLI.EnvReader` implementation: reads a single OS environment
  variable via `System.get_env/1`. Used in production; tests swap in a Mox mock
  via `config/test.exs`.
  """

  @behaviour Loopctl.CLI.EnvReader

  @impl true
  def get_env(name), do: System.get_env(name)
end
