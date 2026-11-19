defmodule Loopctl.Workers.EscalationHandoffWorker do
  @moduledoc """
  Runs `Loopctl.Delivery.EscalationHandoffs.sweep_tenant/2` for every tenant holding an
  escalated story or an open escalation handoff (#1065): each escalated story gets a claimable
  handoff on its repo's channel (#1067), a stalled one is re-posted, and the handoff of a
  resolved story is closed. Mark, 2026-11-19: nothing parks.

  Every five minutes, HARDCODED: the interval is how long an escalation may go unseen by the
  sessions on its repo, and app boot must not gain an env var for it. Not behind
  `:dispatch_driver_enabled`: it starts nothing and spends nothing.

  Retries cannot post twice (each post is a keyed slot, see the module above). One tenant may
  not stop the rest: a raise is logged and counted, and the job fails only when every tenant
  errored.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 240, states: [:available, :scheduled, :executing, :retryable]]

  alias Loopctl.Delivery.EscalationHandoffs
  alias Loopctl.Workers.EscalationDigestWorker

  require Logger

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, {:all_tenants_errored, pos_integer()}}
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    now
    |> EscalationHandoffs.tenants()
    |> Enum.map(&sweep(&1, now))
    |> EscalationDigestWorker.run_result()
  end

  @doc "One tenant's sweep as of `now`: `:ok`, or `:errored` when anything failed. Never raises."
  @spec sweep(Ecto.UUID.t(), DateTime.t()) :: :ok | :errored
  def sweep(tenant_id, %DateTime{} = now) do
    case EscalationHandoffs.sweep_tenant(tenant_id, now) do
      %{errors: []} ->
        :ok

      %{errors: errors} ->
        errored(tenant_id, inspect(errors))
    end
  rescue
    error -> errored(tenant_id, Exception.format(:error, error, __STACKTRACE__))
  catch
    kind, value -> errored(tenant_id, Exception.format(kind, value, __STACKTRACE__))
  end

  defp errored(tenant_id, detail) do
    Logger.error(
      "EscalationHandoffWorker: tenant failed, continuing with the rest: " <>
        "tenant_id=#{tenant_id} detail=#{detail}",
      tenant_id: tenant_id
    )

    :errored
  end
end
