defmodule Loopctl.Knowledge.StreamingExport.BodyProbe do
  @moduledoc """
  Injected seam letting a test observe each article body the streaming-export producer
  emits, WITHOUT the producer knowing a test exists (US-27.16, AC-27.16.1).

  This exists for one reason: the bounded-memory scale gate claims the producer's peak
  RETAINED bytes stay ~flat in N. A metric like that is worthless unless it is proven
  LOAD-BEARING — i.e. that a MATERIALIZING producer (one retaining every body) actually
  makes the ratio FAIL. Proving that requires turning the streaming producer into a
  materializing one on demand, which needs a seam in the production path.

  ## Why a closure, not a per-body callback

  `probe/0` is resolved ONCE per export and returns a plain anonymous function that the
  producer then calls per row. The per-row work is therefore an ordinary fun call, not a
  behaviour dispatch — an 80k-article export would otherwise pay 80k Mox dispatches in
  the test env, which is both slow and a strange amount of machinery on a hot loop.

  ## Why this replaced a config flag

  The previous shape read `Application.get_env(:loopctl, :export_force_materialize_for_test)`
  ONCE PER ARTICLE inside the emit loop, and the scale test flipped it with
  `Application.put_env/3`. That was wrong three ways: it put test-only branching in a
  production hot path, it did a global ETS config lookup per row, and it mutated VM-wide
  state from a test (which `CLAUDE.md` forbids outright — every dependency is swapped via
  config-based DI, never `put_env`). Mutating global config is also not safely reversible
  under failure: an exception between `put_env` and its cleanup leaves a materializing
  producer configured for every later export in the VM.

  Now the production impl (`Loopctl.Knowledge.StreamingExport.NoopBodyProbe`) is a no-op
  and the RETAINING behaviour lives entirely in the test's own stub closure. Mox stubs run
  in the CALLING process, so a test stub that retains binaries retains them in the producer
  process — exactly where the memory metric measures — with no production code aware of it.
  """

  @doc """
  Returns the per-body probe function to use for one export.

  Called once per export; the returned fun is invoked with each article body (which may be
  `nil`) as the producer emits it. Implementations must return quickly and must not raise —
  it runs inside the producer's emit loop.
  """
  @callback probe() :: (binary() | nil -> :ok)
end
