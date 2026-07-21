defmodule Loopctl.Egress.Allowlist.Config do
  @moduledoc """
  Production allowlist source: `config :loopctl, :local_endpoint_allowlist`,
  populated from the `LOCAL_ENDPOINT_ALLOWLIST` deployment env var in
  `config/runtime.exs`.
  """

  @behaviour Loopctl.Egress.Allowlist.Behaviour

  @impl true
  def raw_entries do
    :loopctl
    |> Application.get_env(:local_endpoint_allowlist, [])
    |> List.wrap()
  end
end
