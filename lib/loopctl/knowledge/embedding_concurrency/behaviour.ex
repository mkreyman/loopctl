defmodule Loopctl.Knowledge.EmbeddingConcurrency.Behaviour do
  @moduledoc """
  DI seam for the per-node outbound-embedding concurrency gate (US-37.2).

  The interactive query path and both Oban embedding workers funnel through
  `Loopctl.Knowledge.run_embedding_task/3`, which `acquire/1`s a slot (for the
  request's `tenant_id`) before spawning the supervised embedding task and
  `release/1`s it afterwards. Resolving the gate through config
  (`Application.get_env(:loopctl, :embedding_concurrency,
  Loopctl.Knowledge.EmbeddingConcurrency)`) lets `config/test.exs` swap in
  `Loopctl.MockEmbeddingConcurrency` so a saturation test can deterministically
  force the `{:error, :rate_limited_local}` branch (asserting the keyword-only
  fallback) WITHOUT holding the real, VM-wide global counter saturated and thereby
  starving unrelated async searches. Production always uses the real GenServer.

  Mirrors the `Loopctl.RateLimiter.Behaviour` DI seam that fronts the sibling
  US-37.1 admission gate.
  """

  @doc """
  Try to reserve one outbound-embedding slot for `tenant_id`, charged to the CALLING
  process.

  Returns `:ok` when the node is under BOTH its global concurrency cap AND the
  tenant's per-tenant sub-cap (the slot is charged to the caller and released by
  `release/1`, or reclaimed if the caller crashes), or
  `{:error, :rate_limited_local}` when EITHER cap is already met. Non-blocking: it
  fails fast at the cap rather than queueing, so the interactive path degrades to
  keyword search instead of blocking.
  """
  @callback acquire(tenant_id :: binary()) :: :ok | {:error, :rate_limited_local}

  @doc """
  Release the slot previously reserved by `acquire/1` for `tenant_id` on the calling
  process.

  Idempotent and crash-safe: releasing without a prior successful acquire (or a
  second time) is a no-op.
  """
  @callback release(tenant_id :: binary()) :: :ok
end
