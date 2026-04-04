defmodule Loopctl.TokenUsage.ArchivalBehaviour do
  @moduledoc """
  Behaviour for token data archival operations.

  Defines the contract for soft-deleting old token usage reports and
  archiving old cost anomalies based on per-tenant retention policies.

  Used by `Loopctl.Workers.TokenDataArchivalWorker` via compile-time DI.
  """

  @doc """
  Soft-deletes old token usage reports for a tenant.

  Reports older than `retention_days` days (by `inserted_at`) that are
  not already soft-deleted are marked with `deleted_at = NOW()`.

  Processes in batches of 1000 to avoid long transactions.

  ## Returns

  `{:ok, count}` where `count` is the total number of reports soft-deleted,
  or `{:error, term()}` on failure.
  """
  @callback soft_delete_old_reports(tenant_id :: Ecto.UUID.t(), retention_days :: pos_integer()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Hard-deletes reports that have been soft-deleted for more than 30 days.

  Permanently removes reports where `deleted_at < NOW() - 30 days`.
  Processes in batches of 1000.

  ## Returns

  `{:ok, count}` where `count` is the total number of reports permanently
  deleted, or `{:error, term()}` on failure.
  """
  @callback hard_delete_expired_reports(tenant_id :: Ecto.UUID.t()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Archives old cost anomalies for a tenant.

  Anomalies older than `retention_days` days (by `inserted_at`) that are
  not already archived are marked as `archived = true`.

  Processes in a single batch (anomalies are small in number compared to reports).

  ## Returns

  `{:ok, count}` where `count` is the total number of anomalies archived,
  or `{:error, term()}` on failure.
  """
  @callback archive_old_anomalies(tenant_id :: Ecto.UUID.t(), retention_days :: pos_integer()) ::
              {:ok, non_neg_integer()} | {:error, term()}
end
