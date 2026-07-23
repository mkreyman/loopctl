defmodule Loopctl.MemoryUsage do
  @moduledoc """
  Pluggable memory-measurement behaviour for bounded-memory export verification
  (US-27.16, AC-27.16.1).

  The default implementation (`Loopctl.MemoryUsage.Default`) measures RETAINED
  memory — the O(N) signal that grows if articles accumulate in the producer
  process — by summing:

    * refc binary bytes: off-heap binaries the process retains (article bodies
      > 64 bytes live in the SHARED binary heap, NOT the process heap), and
    * ETS buffer bytes: the deflate buffer held in the writer's ETS table.

  This is the correct metric for detecting a MATERIALIZING producer, unlike
  `process_info(:memory)`, which counts only the process heap and misses both
  off-heap refc binaries and ETS — the prior false-green.

  Wired via config:
  `Application.compile_env(:loopctl, :memory_module, Loopctl.MemoryUsage.Default)`.
  The bounded-memory scale test injects a materializing producer (via the
  `Loopctl.Knowledge.StreamingExport.BodyProbe` DI seam) to PROVE the metric is load-bearing
  (the ratio FAILS under the mutation) — mutation testing for AC-27.16.1.
  """

  @callback usage(pid(), :ets.tid()) :: non_neg_integer()
end
