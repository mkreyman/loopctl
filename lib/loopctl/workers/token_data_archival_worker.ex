defmodule Loopctl.Workers.TokenDataArchivalWorker do
  @moduledoc """
  Oban worker that enforces per-tenant token data retention policies.

  Runs weekly at 03:00 UTC on Sundays via Oban Cron (`0 3 * * 0`).

  For each active tenant with a `token_data_retention_days` policy set,
  the worker performs three passes in order:

  1. **Soft-delete pass** (AC-21.14.2): Soft-deletes `token_usage_reports`
     older than `retention_days` days that are not already deleted.
     Processes in batches of 1000.

  2. **Hard-delete pass** (AC-21.14.3): Permanently removes reports that
     have been soft-deleted for more than 30 days. 30-day recovery window.
     Processes in batches of 1000.

  3. **Anomaly archive pass** (AC-21.14.5): Marks `cost_anomalies` older than
     `retention_days` as `archived = true`. Archived anomalies are excluded
     from the default list but available via `?include_archived=true`.

  Tenants with `token_data_retention_days = NULL` are skipped for the
  soft-delete and anomaly archive passes but still get the hard-delete pass
  to clean up any previously soft-deleted reports within the grace window.

  Cost summaries are NOT subject to retention (AC-21.14.4).

  ## DI

  Uses compile-time DI:

      @archival_service Application.compile_env(:loopctl, :token_archival, Loopctl.TokenUsage.DefaultArchival)

  In test, `config/test.exs` maps to `Loopctl.MockTokenArchival`.

  ## Audit logging (AC-21.14.7)

  Logs the count of soft-deleted and hard-deleted reports, and archived
  anomalies per tenant to the audit log.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Tenants.Tenant

  @archival_service Application.compile_env(
                      :loopctl,
                      :token_archival,
                      Loopctl.TokenUsage.DefaultArchival
                    )

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    tenants = list_active_tenants(args)
    Logger.info("TokenDataArchivalWorker: processing #{length(tenants)} tenants")

    Enum.each(tenants, &process_tenant/1)

    :ok
  end

  # --- Private helpers ---

  defp process_tenant(%Tenant{id: tenant_id, token_data_retention_days: retention_days}) do
    # Hard-delete pass runs for ALL tenants (clears previously soft-deleted reports)
    hard_deleted = run_hard_delete(tenant_id)

    if retention_days do
      # Soft-delete old reports
      soft_deleted = run_soft_delete(tenant_id, retention_days)

      # Archive old anomalies
      archived = run_archive_anomalies(tenant_id, retention_days)

      if soft_deleted > 0 or hard_deleted > 0 or archived > 0 do
        log_archival_results(tenant_id, retention_days, soft_deleted, hard_deleted, archived)
      end
    else
      if hard_deleted > 0 do
        log_archival_results(tenant_id, nil, 0, hard_deleted, 0)
      end
    end
  end

  defp run_soft_delete(tenant_id, retention_days) do
    case @archival_service.soft_delete_old_reports(tenant_id, retention_days) do
      {:ok, count} ->
        count

      {:error, reason} ->
        Logger.warning(
          "TokenDataArchivalWorker: soft-delete failed for tenant #{tenant_id}: #{inspect(reason)}"
        )

        0
    end
  end

  defp run_hard_delete(tenant_id) do
    case @archival_service.hard_delete_expired_reports(tenant_id) do
      {:ok, count} ->
        count

      {:error, reason} ->
        Logger.warning(
          "TokenDataArchivalWorker: hard-delete failed for tenant #{tenant_id}: #{inspect(reason)}"
        )

        0
    end
  end

  defp run_archive_anomalies(tenant_id, retention_days) do
    case @archival_service.archive_old_anomalies(tenant_id, retention_days) do
      {:ok, count} ->
        count

      {:error, reason} ->
        Logger.warning(
          "TokenDataArchivalWorker: anomaly archive failed for tenant #{tenant_id}: #{inspect(reason)}"
        )

        0
    end
  end

  # AC-21.14.7: Log archival counts to audit log
  defp log_archival_results(tenant_id, retention_days, soft_deleted, hard_deleted, archived) do
    Logger.info(
      "TokenDataArchivalWorker: tenant=#{tenant_id} " <>
        "retention_days=#{inspect(retention_days)} " <>
        "soft_deleted=#{soft_deleted} hard_deleted=#{hard_deleted} anomalies_archived=#{archived}"
    )

    case Audit.create_log_entry(tenant_id, %{
           entity_type: "token_data_archival",
           entity_id: tenant_id,
           action: "archival_run",
           actor_type: "system",
           new_state: %{
             "retention_days" => retention_days,
             "reports_soft_deleted" => soft_deleted,
             "reports_hard_deleted" => hard_deleted,
             "anomalies_archived" => archived
           },
           metadata: %{
             "retention_days" => retention_days,
             "reports_soft_deleted" => soft_deleted,
             "reports_hard_deleted" => hard_deleted,
             "anomalies_archived" => archived
           }
         }) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "TokenDataArchivalWorker: audit log failed for tenant #{tenant_id}: #{inspect(reason)}"
        )
    end
  end

  defp list_active_tenants(%{"tenant_ids" => ids}) when is_list(ids) and ids != [] do
    Tenant
    |> where([t], t.status == :active and t.id in ^ids)
    |> AdminRepo.all()
  end

  defp list_active_tenants(_args) do
    Tenant
    |> where([t], t.status == :active)
    |> AdminRepo.all()
  end
end
