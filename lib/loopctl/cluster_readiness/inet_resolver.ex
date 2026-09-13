defmodule Loopctl.ClusterReadiness.InetResolver do
  @moduledoc """
  The production `Loopctl.ClusterReadiness.Resolver`: the same A and AAAA lookups
  `DNSCluster` makes (`:inet_res.getbyname/2`), so the readiness signal counts exactly the
  addresses DNSCluster tries to connect to. On Fly `<app>.internal` lists only STARTED
  machines — verified in production on 2026-09-13 with one machine suspended: the AAAA
  lookup returned the started machine's address alone.
  """

  @behaviour Loopctl.ClusterReadiness.Resolver

  require Record

  Record.defrecordp(:hostent, Record.extract(:hostent, from_lib: "kernel/include/inet.hrl"))

  @impl true
  def lookup(query) when is_binary(query) do
    results = for type <- [:a, :aaaa], do: :inet_res.getbyname(String.to_charlist(query), type)
    addresses = for {:ok, hostent(h_addr_list: list)} <- results, address <- list, do: address

    case {addresses, results} do
      {[], [{:error, reason} | _]} -> {:error, reason}
      _ -> {:ok, Enum.uniq(addresses)}
    end
  end
end
