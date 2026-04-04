defmodule Loopctl.TokenUsage.DefaultArchival do
  @moduledoc """
  Default implementation of `Loopctl.TokenUsage.ArchivalBehaviour`.

  Performs batch soft-delete of old token usage reports, hard-delete of
  expired soft-deleted reports, and archival of old cost anomalies.

  All data operations use `Loopctl.Repo.with_tenant/2` (RLS-enforced, NOT
  AdminRepo) per AC-21.14.9.

  ## Batch approach

  Because Ecto's `update_all` and `delete_all` do not support `LIMIT`, we use
  a PostgreSQL subquery with `WHERE id IN (SELECT id ... LIMIT @batch_size)` to
  process records in bounded batches and avoid long-running transactions.
  """

  @behaviour Loopctl.TokenUsage.ArchivalBehaviour

  require Logger

  import Ecto.Query

  alias Loopctl.Repo
  alias Loopctl.TokenUsage.CostAnomaly
  alias Loopctl.TokenUsage.Report

  @batch_size 1000
  # 30-day hard-delete recovery window
  @hard_delete_grace_days 30

  @impl Loopctl.TokenUsage.ArchivalBehaviour
  def soft_delete_old_reports(tenant_id, retention_days)
      when is_integer(retention_days) and retention_days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)
    do_soft_delete_batch(tenant_id, cutoff, 0)
  end

  @impl Loopctl.TokenUsage.ArchivalBehaviour
  def hard_delete_expired_reports(tenant_id) do
    grace_cutoff = DateTime.add(DateTime.utc_now(), -@hard_delete_grace_days * 86_400, :second)
    do_hard_delete_batch(tenant_id, grace_cutoff, 0)
  end

  @impl Loopctl.TokenUsage.ArchivalBehaviour
  def archive_old_anomalies(tenant_id, retention_days)
      when is_integer(retention_days) and retention_days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)

    result =
      Repo.with_tenant(tenant_id, fn ->
        {count, _} =
          CostAnomaly
          |> where([a], a.tenant_id == ^tenant_id)
          |> where([a], a.inserted_at < ^cutoff)
          |> where([a], a.archived == false)
          |> Repo.update_all(set: [archived: true])

        count
      end)

    case result do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Private batch helpers ---

  # Soft-delete pass: loop until 0 rows affected.
  # Uses a subquery (WHERE id IN (...)) to apply batched update since
  # Ecto update_all does not support LIMIT.
  defp do_soft_delete_batch(tenant_id, cutoff, total_deleted) do
    now = DateTime.utc_now()

    result =
      Repo.with_tenant(tenant_id, fn ->
        # Subquery: select up to @batch_size report IDs that qualify
        subq =
          from(r in Report,
            where: r.tenant_id == ^tenant_id,
            where: r.inserted_at < ^cutoff,
            where: is_nil(r.deleted_at),
            select: r.id,
            limit: @batch_size
          )

        {count, _} =
          from(r in Report, where: r.id in subquery(subq))
          |> Repo.update_all(set: [deleted_at: now])

        count
      end)

    case result do
      {:ok, 0} ->
        {:ok, total_deleted}

      {:ok, count} ->
        do_soft_delete_batch(tenant_id, cutoff, total_deleted + count)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Hard-delete pass: permanently remove reports deleted > grace_days ago.
  # Uses a subquery (WHERE id IN (...)) to apply batched delete.
  defp do_hard_delete_batch(tenant_id, grace_cutoff, total_deleted) do
    result =
      Repo.with_tenant(tenant_id, fn ->
        subq =
          from(r in Report,
            where: r.tenant_id == ^tenant_id,
            where: not is_nil(r.deleted_at),
            where: r.deleted_at < ^grace_cutoff,
            select: r.id,
            limit: @batch_size
          )

        {count, _} =
          from(r in Report, where: r.id in subquery(subq))
          |> Repo.delete_all()

        count
      end)

    case result do
      {:ok, 0} ->
        {:ok, total_deleted}

      {:ok, count} ->
        do_hard_delete_batch(tenant_id, grace_cutoff, total_deleted + count)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
