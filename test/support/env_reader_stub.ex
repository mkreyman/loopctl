defmodule Loopctl.Test.EnvReader do
  @moduledoc """
  Test double for `Loopctl.CLI.EnvReader` (wired via `config/test.exs`
  `:cli_env_reader`). By DEFAULT it delegates to the real `System.get_env/1`, so
  every test that transitively reads CLI config behaves exactly as production and
  needs no setup.

  An env-override test injects a PROCESS-LOCAL map with `put_overrides/1`; while
  set, `get_env/1` reads ONLY from that map (returning `nil` for absent keys),
  mirroring the map-backed getter the env-override tests need. Being
  process-scoped (process dictionary, NOT `System.put_env`, which mutates
  BEAM-global OS env shared by every process), it is safe in an `async: true`
  suite — two tests overriding `LOOPCTL_SERVER` cannot race.
  """

  @behaviour Loopctl.CLI.EnvReader

  @overrides_key :cli_env_overrides

  @doc "Install a process-local override map for the current test process."
  @spec put_overrides(%{optional(String.t()) => String.t() | nil}) :: :ok
  def put_overrides(map) when is_map(map) do
    Process.put(@overrides_key, map)
    :ok
  end

  @impl true
  def get_env(name) do
    case Process.get(@overrides_key) do
      nil -> System.get_env(name)
      overrides when is_map(overrides) -> Map.get(overrides, name)
    end
  end
end
