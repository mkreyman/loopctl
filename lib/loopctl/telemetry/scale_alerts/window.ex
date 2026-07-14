defmodule Loopctl.Telemetry.ScaleAlerts.Window do
  @moduledoc """
  A single tumbling-window snapshot read out of the `ScaleAlerts` ETS counters.

  Holds the per-window counts the `Loopctl.Telemetry.ScaleAlerts` evaluator turns into
  rates and a bucketed p95. Carries COUNTS ONLY — no tenant ids, vectors, bodies, or SQL
  ever reach this struct (the source telemetry events are already id/measurement-only).

    * `:timeout_count` — `db_statement_timeout` events this window.
    * `:under_fill_count` — vector-search under-fill events this window.
    * `:lat_total` — heavy-read latency samples this window.
    * `:buckets` — per-bucket sample counts, indexed to match
      `Loopctl.Telemetry.ScaleAlerts.buckets/0` plus a trailing `+Inf` overflow bucket.
    * `:qt_total` (US-34.3) — primary Repo checkout `queue_time` samples this window.
    * `:qt_buckets` (US-34.3) — per-bucket `queue_time` sample counts, SAME bucket
      layout as `:buckets` (a separate set so it never collides with the heavy-read
      histogram).
    * `:oban_discard_count` (US-34.3) — fleet-wide `[:oban, :job, :exception]` events
      this window (retry failures + exhausted-to-discard transitions).
    * `:provider_error_count` (US-34.3) — genuine LLM/embedding provider failures
      (`[:loopctl, :llm, :provider_error]`) this window.
  """

  @type t :: %__MODULE__{
          timeout_count: non_neg_integer(),
          under_fill_count: non_neg_integer(),
          lat_total: non_neg_integer(),
          buckets: [non_neg_integer()],
          qt_total: non_neg_integer(),
          qt_buckets: [non_neg_integer()],
          oban_discard_count: non_neg_integer(),
          provider_error_count: non_neg_integer()
        }

  defstruct timeout_count: 0,
            under_fill_count: 0,
            lat_total: 0,
            buckets: [],
            qt_total: 0,
            qt_buckets: [],
            oban_discard_count: 0,
            provider_error_count: 0
end
