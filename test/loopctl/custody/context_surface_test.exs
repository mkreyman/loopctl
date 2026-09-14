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

  ## Scope limits, stated so this is not over-trusted

  It scans SOURCE TEXT, so a call reached through an alias this regex does not spell, or
  injected by a macro, is invisible to it. It cannot tell an enforced refusal from a call whose
  result is discarded. And it says nothing about whether a context SHOULD be gated — only that
  the declaration and the calls agree. Judging what belongs on the halt surface is
  `LoopctlWeb.CustodySurface`'s moduledoc, and it is a human's call.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Custody.ContextSurface

  # `lib/loopctl/runners.ex` DEFINES `custody_halted?/1` and calls it for `dispatch/3`, which
  # is reached through a route. A definition is not an enforcement, and that call is the web
  # surface's, so the file is excluded rather than declared.
  @scan_glob "lib/loopctl/**/*.ex"
  @definition_source "lib/loopctl/runners.ex"

  # Deliberately anchored on `Runners.` — `Tenants.custody_halted?/1` takes an already-loaded
  # struct and is the MONITOR's read (`Loopctl.Custody.ViolationMonitor`), not a gate: a struct
  # loaded before the halt was armed answers `false` for ever. Matching the bare function name
  # would sweep that in and make the guard assert something it does not mean.
  @call_pattern ~r/(?<![\w.])(Loopctl\.)?Runners\.custody_halted\?\(/

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
    @scan_glob
    |> Path.wildcard()
    |> Enum.reject(&(&1 == @definition_source))
    |> Enum.filter(&calls_halt_check?/1)
    |> Enum.map(&defmodule_name/1)
  end

  defp calls_halt_check?(path), do: path |> File.read!() |> then(&Regex.match?(@call_pattern, &1))

  defp defmodule_name(path) do
    case Regex.run(~r/^defmodule\s+([\w.]+)\s+do/m, File.read!(path)) do
      [_, module] -> module
      nil -> flunk("could not read a defmodule name out of #{path} — widen defmodule_name/1")
    end
  end
end
