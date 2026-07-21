defmodule Loopctl.Test.AllowlistSource do
  @moduledoc """
  PROCESS-LOCAL allowlist source used only in the test env (US-41.4).

  The operator deployment allowlist is deployment configuration with no API
  writer by design, so a test that must exercise an operator carve-out would
  otherwise reach for `Application.put_env` — forbidden by the project's test
  conventions AND a global race under `async: true`. This source reads the
  calling process's own value instead, so two async tests can hold different
  allowlists at the same instant without interfering.

  Wired via `config :loopctl, :local_allowlist_source` in `config/test.exs`
  (config-based DI, never opts-based). Falls back to the real deployment config
  when a test has set nothing, so the default (empty) posture is what an
  unconfigured test sees.
  """

  alias Loopctl.Egress.Allowlist

  @behaviour Loopctl.Egress.Allowlist.Behaviour

  @key :loopctl_test_local_endpoint_allowlist

  @doc "Sets the allowlist for the CALLING process only, for the rest of the test."
  @spec put([String.t()]) :: :ok
  def put(entries) when is_list(entries) do
    Process.put(@key, entries)
    :ok
  end

  @doc "Clears the calling process's allowlist override."
  @spec clear() :: :ok
  def clear do
    Process.delete(@key)
    :ok
  end

  @impl true
  def raw_entries do
    case Process.get(@key) do
      nil -> Allowlist.Config.raw_entries()
      entries -> entries
    end
  end
end
