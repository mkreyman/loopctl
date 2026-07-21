defmodule Loopctl.Workers.PromotionEvalWorker do
  @moduledoc """
  Daily promotion-compile-quality eval (Epic 29 / US-29.5). Fans out over active tenants
  and records `Loopctl.Memory.PromotionEval.run/1` — precision & recall of the promotion
  COMPILER against the committed labeled dataset — as a per-tenant snapshot + telemetry.

  Calibration/observability ONLY: it never gates promotion (the gate stays the US-29.1
  confidence threshold) and never re-judges production memories with an LLM. Additive /
  idempotent (upsert per tenant/dataset_version/day).

  ## LLM cost containment

  Scoring the REAL compiler means each labeled session runs a real, tenant-scoped
  extraction LLM call on the tenant's BYO key. To avoid spending tokens on tenants who
  never configured extraction, the `all_tenants` fan-out only enqueues tenants that
  have a usable extraction TARGET — an Anthropic key, or (US-41.3) a configured
  `openai_compatible` chat endpoint, which has no Anthropic key at all. The predicate
  mirrors `Loopctl.Llm.resolve(_, :extraction)` in SQL; unconfigured tenants are
  skipped entirely (no wasted job, no error). The cost is BOUNDED (the committed
  dataset's handful of short synthetic sessions, once/day) and OBSERVABLE — the
  extraction call records per-tenant token usage best-effort, and the eval emits a
  per-tenant `[:loopctl, :memory_promotion, :eval]` telemetry event.

  Scheduled daily via the Oban Cron plugin, alongside `RetrievalMetricsWorker`.
  """

  use Oban.Worker,
    queue: :knowledge,
    max_attempts: 3,
    unique: [fields: [:worker, :args], period: 300]

  require Logger

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Llm.TenantLlmSettings
  alias Loopctl.Memory.PromotionEval
  alias Loopctl.Oban.FairShare
  alias Loopctl.Tenants.Tenant

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "all_tenants"}}) do
    Enum.each(eligible_tenant_ids(), fn tenant_id ->
      %{"tenant_id" => tenant_id} |> __MODULE__.new() |> Oban.insert()
    end)

    :ok
  end

  def perform(%Oban.Job{id: id, args: %{"tenant_id" => tenant_id}}) do
    # US-36.2: fair-share gate on the shared :knowledge queue — this is the SEVENTH
    # tenant-scoped :knowledge worker (oban_config.ex enumerates it as a reason to
    # size the lane at width 3), a not-sub-second per-tenant extraction LLM call fanned
    # out over all keyed tenants daily. Gate it consistently with the other six so a
    # tenant's promotion-eval can't exceed its fair share of executing :knowledge slots
    # (the all_tenants dispatcher clause above stays UNGATED — it has no tenant_id).
    # `id` excludes THIS (already-executing) job from its own count — see FairShare.
    case FairShare.gate(tenant_id, :knowledge, id) do
      {:snooze, _n} = snooze -> snooze
      :ok -> run_eval(tenant_id)
    end
  end

  @doc """
  The active tenants the daily fan-out enqueues — those with a usable EXTRACTION
  target.

  Public so the predicate can be asserted directly against
  `Loopctl.Llm.resolve(_, :extraction)` without executing a real per-tenant eval
  (Oban runs `:inline` in tests).
  """
  @spec eligible_tenant_ids() :: [Ecto.UUID.t()]
  def eligible_tenant_ids do
    # Select in ONE round-trip by joining tenant_llm_settings, instead of an N+1
    # `Llm.has_api_key?/1` settings read per tenant.
    #
    # This predicate MIRRORS `Loopctl.Llm.resolve(_, :extraction)` — i.e.
    # `resolve_chat/2` — and must be kept in step with it. `resolve_chat/2` has TWO
    # admitting clauses, and a denormalized copy that knows only about the first one
    # silently drops every tenant matched by the second (no error, no telemetry, no
    # job — the failure mode US-41.3 review caught):
    #
    #   * `chat_provider = 'openai_compatible'` resolves on `chat_base_url` +
    #     `extraction_model` and NEVER reads the Anthropic `api_key` column, which is
    #     nil for exactly the private-tier tenant this epic exists for; or
    #   * a non-null Anthropic `api_key` (always non-empty — the settings changeset
    #     rejects blank keys).
    #
    # Tenants matching neither are skipped (no wasted job, no spent BYO tokens).
    from(t in Tenant,
      join: s in TenantLlmSettings,
      on: s.tenant_id == t.id,
      where:
        t.status == :active and
          ((s.chat_provider == "openai_compatible" and not is_nil(s.chat_base_url) and
              not is_nil(s.extraction_model)) or
             (s.chat_provider != "openai_compatible" and not is_nil(s.api_key)) or
             (is_nil(s.chat_provider) and not is_nil(s.api_key))),
      select: t.id
    )
    |> AdminRepo.all()
  end

  defp run_eval(tenant_id) do
    case PromotionEval.run(tenant_id: tenant_id) do
      {:ok, snap} ->
        Logger.info(
          "PromotionEvalWorker: tenant=#{tenant_id} dataset=#{snap.dataset_version} " <>
            "day=#{snap.day} tp=#{snap.true_positives} fp=#{snap.false_positives} " <>
            "fn=#{snap.false_negatives} precision=#{fmt(snap.precision)} " <>
            "recall=#{fmt(snap.recall)}"
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # precision/recall are nil when the compiler emitted nothing (undefined metric).
  defp fmt(nil), do: "n/a"
  defp fmt(value) when is_float(value), do: value |> Float.round(3) |> Float.to_string()
end
