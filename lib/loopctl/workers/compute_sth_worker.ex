defmodule Loopctl.Workers.ComputeSthWorker do
  @moduledoc """
  US-26.1.2 — Computes Signed Tree Heads for tenant audit chains.

  Runs periodically to sign the current state of each tenant's audit chain.
  Idempotent: if no new entries exist since the last STH, does nothing.

  ## Scheduling

  Configured via Oban Cron to run every minute in `all_tenants` mode,
  which enqueues individual per-tenant jobs.
  """

  use Oban.Worker,
    queue: :audit,
    max_attempts: 3,
    unique: [fields: [:worker, :args], period: 30]

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.Tenants.Tenant

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "all_tenants"}}) do
    import Ecto.Query

    tenants =
      from(t in Tenant, where: t.status == :active, select: t.id)
      |> AdminRepo.all()

    for tenant_id <- tenants do
      %{"tenant_id" => tenant_id}
      |> __MODULE__.new()
      |> Oban.insert()
    end

    :ok
  end

  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id}}) do
    if AuditChain.sth_needed?(tenant_id) do
      case AuditChain.sign_and_store_tree_head(tenant_id) do
        {:ok, sth} ->
          Logger.info(
            "ComputeSthWorker: signed STH for tenant #{tenant_id} at position #{sth.chain_position}"
          )

          :ok

        {:error, :empty_chain} ->
          :ok

        {:error, reason} ->
          Logger.warning("ComputeSthWorker: failed for tenant #{tenant_id}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      :ok
    end
  end
end
