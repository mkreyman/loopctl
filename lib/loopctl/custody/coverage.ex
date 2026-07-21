defmodule Loopctl.Custody.Coverage do
  @moduledoc """
  US-41.7 AC-41.7.6 — the production coverage source.

  ## The over-claim guard

  Coverage is configurable, but the configured set is INTERSECTED with the set of
  paths for which loopctl actually records a per-row posture entry
  (`instrumented_paths/0`). An operator who adds `:webhook_delivery` to the
  config without a recorder therefore gets no coverage widening and no false
  attestation — the surface can only ever narrow relative to what is proven.

  ## Why `webhook_delivery` is not instrumented today

  US-41.5 brought webhook delivery under the SAME fail-closed egress policy, so a
  `local_only` scope cannot POST tenant content to a non-local destination. That
  is an ENFORCEMENT guarantee, not a per-row RECORDED fact: a webhook event is not
  a content-touching operation on an article or memory row, so there is no
  `(row, operation_sequence)` to bind it to. Until a recorder exists, the claim
  lists it under `uncovered_paths` with that reason instead of quietly counting it.
  """

  @behaviour Loopctl.Custody.CoverageBehaviour

  @instrumented [:provider_calls]

  @default_configured [:provider_calls]

  @doc """
  The egress paths for which a per-row posture entry is actually recorded.

  `:provider_calls` covers every model-provider call routed through
  `Loopctl.Provider` — embedding and chat — which is the whole content-carrying
  provider surface for a knowledge article or memory row.
  """
  @spec instrumented_paths() :: [atom()]
  def instrumented_paths, do: @instrumented

  @impl true
  def covered_paths do
    configured =
      :loopctl
      |> Application.get_env(:custody_coverage, [])
      |> Keyword.get(:covered_paths, @default_configured)

    Enum.filter(@instrumented, &(&1 in configured))
  end
end
