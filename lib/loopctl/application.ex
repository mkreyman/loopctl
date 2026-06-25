defmodule Loopctl.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Loopctl.Telemetry.SlowQueryLogger

  @impl true
  def start(_type, _args) do
    Loopctl.TenantKeys.init_cache()

    # US-27.4: uniform slow-query logging across all repos via one telemetry handler.
    SlowQueryLogger.attach()

    children = [
      LoopctlWeb.Telemetry,
      Loopctl.Vault,
      Loopctl.Repo,
      Loopctl.AdminRepo,
      Loopctl.HeavyReadRepo,
      {DNSCluster, query: Application.get_env(:loopctl, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Loopctl.PubSub},
      {Task.Supervisor, name: Loopctl.TaskSupervisor},
      {Oban, Application.fetch_env!(:loopctl, Oban)},
      Loopctl.RateLimiter.Server,
      LoopctlWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Loopctl.Supervisor]
    result = Supervisor.start_link(children, opts)

    # US-27.11 (AC-27.11.5): warn if the actual configured pools would exceed the live
    # DB max_connections at the expected node count. Prod only (dev/test pools differ),
    # log-only, never blocks boot.
    if Application.get_env(:loopctl, :env) == :prod, do: Loopctl.DbCapacity.warn_if_over_budget()

    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LoopctlWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
