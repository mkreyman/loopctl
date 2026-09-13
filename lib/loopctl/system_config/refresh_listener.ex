defmodule Loopctl.SystemConfig.RefreshListener do
  @moduledoc """
  Carries the per-minute `Loopctl.SystemConfig` refresh to every node of a cluster.

  The cache is node-local (`:persistent_term`), and the `SystemConfigRefreshWorker` cron is
  run by ONE node per tick — whichever Oban picks — so on its own a peer adopts a
  `system_configs` change only when the job happens to land there, which can be many ticks
  later. The worker therefore broadcasts `{:system_config_refresh, origin_node}` after
  refreshing its own node, and this process re-reads the table on every OTHER node.

  Where the guarantee ends: a node that is not connected when the broadcast goes out — a
  netsplit, a peer still booting, a machine on another release (rel/env.sh.eex) — misses
  that tick and takes the next one it receives, or the cron itself. Nothing here retries;
  the next minute is the retry, as it is for the worker.
  """

  use GenServer

  alias Loopctl.SystemConfig

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    :ok = Phoenix.PubSub.subscribe(Loopctl.PubSub, SystemConfig.refresh_topic())
    {:ok, %{}}
  end

  # The origin node refreshed before it broadcast; only its peers need to.
  @impl true
  def handle_info({:system_config_refresh, origin}, state) when origin != node() do
    SystemConfig.refresh()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
