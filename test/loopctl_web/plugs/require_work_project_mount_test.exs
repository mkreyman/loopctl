defmodule LoopctlWeb.Plugs.RequireWorkProjectMountTest do
  @moduledoc """
  Drift guard for the `RequireWorkProject` mounts.

  The `Loopctl.Coordination` #517 kb carve-out (`project_writable_by_agent/4` grants
  tenant-wide write to any `:kb`-kind scope) rests on the invariant that a kb-scope
  can NEVER hold a story — see coordination.ex residual 3. That invariant is enforced
  ONLY at the web boundary by `plug LoopctlWeb.Plugs.RequireWorkProject`, mounted on
  each controller that can attach work-breakdown items (epics / stories / imports /
  ui-tests / orchestrator state) to a project. There is no DB CHECK/FK and no
  context-layer guard, so — unlike `RequireHumanAnchor`, which is source-scan-locked by
  `tier_capabilities_test.exs` — a work-attachment route added or edited WITHOUT the
  plug would silently reopen the invariant the carve-out depends on.

  This test locks the current mounts: it scans SOURCE TEXT under `lib/loopctl_web/**`
  for `plug ... RequireWorkProject` and asserts the mounting-controller set matches an
  explicit expected list, failing in BOTH directions. Removing the plug from a
  work-attachment controller (a regression) or adding a new work-attachment controller
  without it fails CI here. Do NOT relax this test to make a change pass — restore the
  mount (or, when a new work-attachment controller is genuinely added, mount the plug
  AND add it to `@expected` in the same change).

  SCOPE LIMIT (stated so it is not over-trusted, parity with tier_capabilities_test):
  it matches `plug RequireWorkProject` with or without parentheses and with or without
  the full alias. A mount injected by a shared `use`/macro is invisible to it, and it
  does not verify that the plug's `param:` option matches the route's path param.
  """
  use ExUnit.Case, async: true

  @scan_glob "lib/loopctl_web/**/*.ex"
  @plug_source "lib/loopctl_web/plugs/require_work_project.ex"

  # The controllers that attach work-breakdown items to a project and MUST reject a
  # `:kb` scope. Keep this in lockstep with the actual `plug RequireWorkProject` mounts.
  @expected [
    "LoopctlWeb.EpicController",
    "LoopctlWeb.ImportExportController",
    "LoopctlWeb.OrchestratorStateController",
    "LoopctlWeb.StoryController",
    "LoopctlWeb.UiTestController"
  ]

  test "every work-attachment controller mounts RequireWorkProject (no drift)" do
    mounted = mounted_controllers()

    assert Enum.sort(mounted) == Enum.sort(@expected),
           """
           The RequireWorkProject mounts have drifted from the expected set.

           Mounted but not expected: #{inspect(mounted -- @expected)}
           Expected but not mounted:  #{inspect(@expected -- mounted)}

           The #517 kb carve-out (Coordination.project_writable_by_agent/4 grants
           tenant-wide write to any :kb scope) relies on kb-scopes never holding a
           story, enforced ONLY by this plug. Restore the mount — do NOT relax this
           test. If a NEW work-attachment controller was added, mount the plug on it
           and add it to @expected in the same change.
           """
  end

  defp mounted_controllers do
    @scan_glob
    |> Path.wildcard()
    |> Enum.reject(&(&1 == @plug_source))
    |> Enum.filter(&(&1 |> File.read!() |> mounts_work_project?()))
    |> Enum.map(&defmodule_name/1)
  end

  defp mounts_work_project?(source) do
    String.match?(source, ~r/^\s*plug[\s(]+(LoopctlWeb\.Plugs\.)?RequireWorkProject\b/m)
  end

  defp defmodule_name(path) do
    case Regex.run(~r/^defmodule\s+([\w.]+)\s+do/m, File.read!(path)) do
      [_, module] -> module
      nil -> flunk("could not read a defmodule name out of #{path}")
    end
  end
end
