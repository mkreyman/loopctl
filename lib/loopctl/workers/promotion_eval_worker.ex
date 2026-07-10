defmodule Loopctl.Workers.PromotionEvalWorker do
  @moduledoc """
  Daily promotion-compile-quality eval (Epic 29 / US-29.5). Fans out over active tenants
  and records `Loopctl.Memory.PromotionEval.run/1` — precision & recall of the promotion
  COMPILER against the committed labeled dataset — as a per-tenant snapshot + telemetry.

  Calibration/observability ONLY: it never gates promotion (the gate stays the US-29.1
  confidence threshold) and never re-judges production memories with an LLM. Additive /
  idempotent (upsert per tenant/dataset_version/day).

  Scheduled daily via the Oban Cron plugin, alongside `RetrievalMetricsWorker`.
  """

  use Oban.Worker,
    queue: :knowledge,
    max_attempts: 3,
    unique: [fields: [:worker, :args], period: 300]

  require Logger

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Memory.PromotionEval
  alias Loopctl.Tenants.Tenant

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "all_tenants"}}) do
    from(t in Tenant, where: t.status == :active, select: t.id)
    |> AdminRepo.all()
    |> Enum.each(fn tenant_id ->
      %{"tenant_id" => tenant_id} |> __MODULE__.new() |> Oban.insert()
    end)

    :ok
  end

  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id}}) do
    case PromotionEval.run(tenant_id: tenant_id) do
      {:ok, snap} ->
        Logger.info(
          "PromotionEvalWorker: tenant=#{tenant_id} dataset=#{snap.dataset_version} " <>
            "day=#{snap.day} tp=#{snap.true_positives} fp=#{snap.false_positives} " <>
            "fn=#{snap.false_negatives} precision=#{Float.round(snap.precision, 3)} " <>
            "recall=#{Float.round(snap.recall, 3)}"
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
