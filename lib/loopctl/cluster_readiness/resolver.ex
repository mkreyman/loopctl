defmodule Loopctl.ClusterReadiness.Resolver do
  @moduledoc """
  Resolves the clustering DNS query (`DNS_CLUSTER_QUERY`) to the addresses of the
  machines it currently lists. `Loopctl.ClusterReadiness` uses it as evidence of how many
  peers are actually running (config-based DI: `:cluster_dns_resolver`, default
  `Loopctl.ClusterReadiness.InetResolver`).
  """

  @callback lookup(query :: String.t()) :: {:ok, [:inet.ip_address()]} | {:error, term()}
end
