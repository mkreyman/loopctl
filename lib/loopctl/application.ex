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
      # US-27.16: owns the ETS table tracking in-flight streaming-export slots so a
      # crashed exporter's slot is reclaimed (concurrency cap, AC-27.16.6).
      Loopctl.Knowledge.ExportConcurrency,
      # Owns the per-tenant embedding circuit-breaker ETS table so it has a STABLE,
      # long-lived owner (it would otherwise be created by a transient request/job/Task
      # and vanish when that process died — silently resetting the breaker).
      Loopctl.Knowledge.EmbeddingCircuitBreaker,
      LoopctlWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Loopctl.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Prime the SystemConfig :persistent_term cache from the DB now that the repos
    # are started, so the ingestion/extraction hot path reads live values from the
    # first request. refresh/0 is rescue-wrapped (a DB blip logs and no-ops), so a
    # failed prime NEVER blocks boot — the in-code defaults simply apply until the
    # per-minute refresh cron succeeds.
    Loopctl.SystemConfig.refresh()

    # US-27.11 (AC-27.11.5): warn if the actual configured pools would exceed the live
    # DB max_connections at the expected node count. Prod only (dev/test pools differ),
    # log-only, never blocks boot.
    if Application.get_env(:loopctl, :env) == :prod, do: Loopctl.DbCapacity.warn_if_over_budget()

    # US-27.9a: warn if a CONCURRENTLY-built critical index (e.g. the article keyset
    # index) is missing/INVALID after an interrupted build — silent Seq-Scan degradation
    # otherwise. Prod only, log + telemetry, never blocks boot.
    if Application.get_env(:loopctl, :env) == :prod,
      do: Loopctl.IndexHealth.warn_if_invalid_indexes()

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
