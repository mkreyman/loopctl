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
  """

  @type t :: %__MODULE__{
          timeout_count: non_neg_integer(),
          under_fill_count: non_neg_integer(),
          lat_total: non_neg_integer(),
          buckets: [non_neg_integer()]
        }

  defstruct timeout_count: 0, under_fill_count: 0, lat_total: 0, buckets: []
end
