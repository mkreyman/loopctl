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
  requested `k` candidates AND above-threshold (near) neighbors the inner ANN
  surfaced were hidden by the already-linked anti-join — `above_threshold >
  returned`. NOT fired for a genuinely-sparse region whose whole ANN pool is
  below the similarity threshold (correct emptiness, not recall loss, so
  `above_threshold == returned`). Emitted at most ONCE per request.

  ## Payload (id-only — NEVER a vector literal or article body, AC-27.6b.5)

    * `measurements`: `%{requested, returned, pool, ann_candidates,
      above_threshold, excluded_by_link}` where
        - `pool` = the REQUESTED over-fetch ceiling (`pool_size/2`).
        - `ann_candidates` = how many rows the inner ANN actually delivered —
          bounded by `LIMIT pool` AND, under HNSW, by `~ef_search` (~40), so it
          is typically `< pool`. A recall-BREADTH diagnostic, NOT a pool-full
          gate (an `ann_candidates >= pool` check is degenerate under HNSW).
        - `above_threshold` = how many of `ann_candidates` clear the similarity
          bar — the near neighbors that actually exist.
        - `excluded_by_link` = `above_threshold - returned` — the above-threshold
          neighbors the already-linked anti-join HID. Because the signal only
          fires when `returned < limit` (so the outer LIMIT never bound and every
          unlinked above-threshold candidate WAS returned), this is an
          UN-CONFLATED recall-loss count — purely anti-join drops, with the
          below-threshold (sparse) drops already excluded. No extra read is
          needed to disentangle the two.
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
