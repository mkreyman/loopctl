defmodule Loopctl.TelemetryEvents do
  @moduledoc """
  Defines telemetry event names for key operations in loopctl.

  All application-level telemetry events are defined here as constants
  to prevent typos and enable grep-ability. Use `:telemetry.execute/3`
  with these event names and appropriate measurements/metadata.

  ## Event naming convention

  Events follow the pattern `[:loopctl, <domain>, <action>]`.

  ## Usage

      :telemetry.execute(
        Loopctl.TelemetryEvents.api_request_stop(),
        %{duration: duration},
        %{route: route, status: status, tenant_id: tenant_id}
      )
  """

  @doc "API request started"
  def api_request_start, do: [:loopctl, :api, :request, :start]

  @doc "API request completed"
  def api_request_stop, do: [:loopctl, :api, :request, :stop]

  @doc "API request raised an exception"
  def api_request_exception, do: [:loopctl, :api, :request, :exception]

  @doc "Story agent_status or verified_status changed"
  def story_status_changed, do: [:loopctl, :story, :status_changed]

  @doc "Webhook delivery attempted"
  def webhook_delivery_start, do: [:loopctl, :webhook, :delivery, :start]

  @doc "Webhook delivery completed"
  def webhook_delivery_stop, do: [:loopctl, :webhook, :delivery, :stop]

  @doc "Webhook delivery failed"
  def webhook_delivery_exception, do: [:loopctl, :webhook, :delivery, :exception]

  @doc "Audit log entry written"
  def audit_log_write, do: [:loopctl, :audit, :write]

  @doc """
  A vector-search read under-filled (US-27.6b): it returned fewer than the
  requested `k` candidates DESPITE the inner ANN pool being filled to its cap —
  i.e. the post-ANN filters (already-linked anti-join / similarity threshold)
  cut the full pool below `k`, not a genuinely-small corpus. Emitted at most
  ONCE per request.

  ## Payload (id-only — NEVER a vector literal or article body, AC-27.6b.5)

    * `measurements`: `%{requested, returned, pool, available, excluded_total}`
      where `excluded_total = pool - returned` is the **TOTAL** post-ANN
      exclusion count — the anti-join drops and the below-threshold drops
      COMBINED, NOT a per-reason split. A per-reason breakdown (anti-join vs
      threshold) is intentionally **deferred to US-27.15** (the metrics
      aggregation that consumes this event): computing the two components
      separately would cost an ADDITIONAL bounded read per request, which the
      AC-27.6b.5 one-bounded-read cost bound discourages.
    * `metadata`: `%{tenant_id, endpoint}` — `tenant_id` is an id, not content.

  Aggregated by US-27.15 metrics/alerting.
  """
  def vector_search_under_fill, do: [:loopctl, :knowledge, :vector_search, :under_fill]

  @doc "Returns all defined event names for attachment"
  def all_events do
    [
      api_request_start(),
      api_request_stop(),
      api_request_exception(),
      story_status_changed(),
      webhook_delivery_start(),
      webhook_delivery_stop(),
      webhook_delivery_exception(),
      audit_log_write(),
      vector_search_under_fill()
    ]
  end
end
