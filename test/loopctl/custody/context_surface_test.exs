defmodule Loopctl.Custody.ContextSurfaceTest do
  @moduledoc """
  Issue #803 — the drift guard for the halt gate on the CONTEXT side.

  `test/loopctl_web/custody_surface_test.exs` walks the router, which is right for every
  custody operation that has a route and structurally blind to one that does not.
  `Loopctl.Delivery.Placement` is the first with no route at all, so the halt slipped past a
  guard designed to make exactly that impossible. This is the other half: a scan of
  `lib/loopctl/**` for modules that call `Loopctl.Runners.custody_halted?/1`, compared against
  `ContextSurface.halt_enforcing_contexts/0` in BOTH directions.

  The direction that matters more is "claimed but does not enforce": the declaration would then
  assert a gate that is not there, which is worse than an unclaimed enforcement.

  ## It parses; it does not grep

  The first version matched raw file text, and a `#` comment satisfied it — a module declared
  as enforcing the halt that only MENTIONED `Runners.custody_halted?(` in prose passed, in the
  direction this guard's own failure message calls the dangerous one. `Loopctl.SourceScan` walks
  the AST instead, and a comment cannot produce a call node.

  ## Scope limits, stated so this is not over-trusted

  It matches the module's last alias segment, so `Runners.custody_halted?(...)` and the fully
  qualified form both count; a call through a RENAMED alias, one built by a macro, and
  `apply/3` are invisible to it. It cannot tell an enforced refusal from a call whose result is
  discarded. And it says nothing about whether a context SHOULD be gated — only that the
  declaration and the calls agree. Judging what belongs on the halt surface is
  `LoopctlWeb.CustodySurface`'s moduledoc, and it is a human's call.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Custody.ContextSurface
  alias Loopctl.SourceScan

  # Deliberately anchored on the `Runners` MODULE — `Tenants.custody_halted?/1` takes an
  # already-loaded struct and is the MONITOR's read (`Loopctl.Custody.ViolationMonitor`), not a
  # gate: a struct loaded before the halt was armed answers `false` for ever. Matching the bare
  # function name would sweep that in and make the guard assert something it does not mean.
  #
  # `lib/loopctl/runners.ex` is NOT excluded, and the exclusion it used to carry was inert:
  # that file's own call is UNQUALIFIED (`if custody_halted?(tenant_id)`), so it never matched
  # a module-qualified scan and the exclusion removed nothing — while standing ready to hide a
  # real routeless halt gate added there later. If a qualified self-call ever appears in it,
  # this guard will report it and somebody will have to decide whether it belongs on the map.
  @scan_glob "lib/loopctl/**/*.ex"

  test "the declared halt-enforcing contexts are exactly the ones that call the check" do
    declared = Enum.sort(ContextSurface.halt_enforcing_contexts())
    found = Enum.sort(halt_enforcing_modules())

    assert declared == Enum.uniq(declared),
           "a context is declared twice: #{inspect(declared -- Enum.uniq(declared))}"

    assert declared == found,
           """
           Loopctl.Custody.ContextSurface.halt_enforcing_contexts/0 has drifted from the
           modules that actually call Loopctl.Runners.custody_halted?/1.

           Enforces the halt but undeclared: #{inspect(found -- declared)}
           Declared but does NOT enforce:    #{inspect(declared -- found)}

           The second list is the dangerous one — the declaration would claim a halt gate
           that is not there. Add the enforcement; do NOT relax this test.
           """
  end

  test "every declared context is a module that exists" do
    for module <- ContextSurface.halt_enforcing_contexts() do
      assert Code.ensure_loaded?(Module.concat([module])),
             "#{module} is declared on the halt surface but is not a module"
    end
  end

  defp halt_enforcing_modules do
    SourceScan.callers(@scan_glob, :Runners, :custody_halted?)
  end
end
