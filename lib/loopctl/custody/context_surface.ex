defmodule Loopctl.Custody.ContextSurface do
  @moduledoc """
  THE list of CONTEXT modules that enforce the custody halt themselves, because no route
  reaches them (#803).

  ## Why this exists as a second declaration rather than a wider first one

  `LoopctlWeb.CustodySurface` is the halt's surface and it is complete for what it covers:
  `test/loopctl_web/custody_surface_test.exs` walks `LoopctlWeb.Router.__routes__/0`, so a new
  story-lifecycle ACTION cannot silently escape the halt. Every non-controller caller of
  `Loopctl.Progress.claim_story/3` before #803 — `bulk_operations.ex`, `coordination.ex`,
  `delivery/stages.ex` — is reached through a route that walk covers.

  `Loopctl.Delivery.Placement` is the first custody-progressing entry point with **no route at
  all**: an Oban worker or an MCP tool calls it directly. A ROUTE WALK is structurally
  incapable of seeing that, so the guard meant to make a halt bypass impossible could not have
  reported this one. Widening the route walk to reach contexts would give it two jobs and one
  of them badly; this is the second half instead, and
  `test/loopctl/custody/context_surface_test.exs` scans `lib/loopctl/**` in BOTH directions —
  a context that claims the halt gate and does not enforce it, and one that enforces it without
  being claimed here.

  **This is the same blind spot as the tier gate's**, one gate along.
  `Loopctl.Tenants.TierCapabilities.gated_controllers/0` scans `lib/loopctl_web` and cannot see
  a context-layer human-anchor gate either, which is why `gated_contexts/0` is a separate map
  scanned against `lib/loopctl`. Every gate in this codebase that binds itself with a drift
  test binds itself by scanning ONE tree; the delivery loop is introducing entry points in the
  other.

  ## What counts as enforcing it

  Calling `Loopctl.Runners.custody_halted?/1` — the FRESH, tenant-id read — and refusing. Not
  `Loopctl.Tenants.custody_halted?/1`, which takes an already-loaded struct and is a read for
  monitoring (`Loopctl.Custody.ViolationMonitor`), not a gate: a struct loaded before the halt
  was armed answers `false` for ever.

  Adding a context here without the call, or the call without the entry, fails the scan. Add
  the enforcement; never relax the test to make a module pass.
  """

  # Module names as STRINGS, mirroring `TierCapabilities`' two maps — the scan compares them
  # against `defmodule` lines in source text, and a compile-time reference would make this
  # module depend on every context it lists.
  @halt_enforcing_contexts ["Loopctl.Delivery.Placement"]

  @doc """
  Context modules that enforce the custody halt themselves. Bound to the modules that actually
  call `Loopctl.Runners.custody_halted?/1` by `context_surface_test.exs`, in both directions.
  """
  @spec halt_enforcing_contexts() :: [String.t()]
  def halt_enforcing_contexts, do: @halt_enforcing_contexts
end
