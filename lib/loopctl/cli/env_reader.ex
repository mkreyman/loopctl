defmodule Loopctl.CLI.EnvReader do
  @moduledoc """
  Behaviour for reading a single OS environment variable, so `Loopctl.CLI.Config`
  can resolve its env-override source through config-based DI
  (`Application.get_env(:loopctl, :cli_env_reader, ...)`) rather than a function
  argument.

  Production resolves to `Loopctl.CLI.SystemEnvReader` (a thin `System.get_env/1`
  wrapper); `config/test.exs` points at a Mox mock so env overrides can be
  exercised WITHOUT `System.put_env`, which mutates BEAM-global OS env shared by
  every process (a flake in an `async: true` suite — two tests overriding
  `LOOPCTL_SERVER` would race).
  """

  @callback get_env(String.t()) :: String.t() | nil
end
