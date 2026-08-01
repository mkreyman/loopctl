defmodule Loopctl.CiScaleNightlyCronTest do
  @moduledoc """
  The scale-nightly matrix is started by ONE literal cron string written TWICE: in
  `on.schedule` and in the job's own `if:` (which must not match the 02:00 nightly cron
  the ordinary jobs run on). GitHub Actions has no anchor to share the literal, so this
  is the guard: if the two drift, the matrix silently stops running on any schedule,
  every CI run stays green, and the only automatic run of the 80k prod-floor plan gate
  is gone. Same class as the matrix/tagged-file set-equality guard in
  test/loopctl/knowledge/scale_verification_runbook_test.exs.
  """
  use ExUnit.Case, async: true

  @ci ".github/workflows/ci.yml"

  test "the cron the scale-nightly job matches on is declared in `on.schedule`" do
    scheduled = scheduled_crons()
    matched = scale_nightly_if_cron()

    assert scheduled != [], "#{@ci} must declare at least one `on.schedule` cron"

    assert matched in scheduled,
           "scale-nightly gates on github.event.schedule == '#{matched}', which is not an " <>
             "`on.schedule` cron (#{inspect(scheduled)}) — the matrix would never run on a " <>
             "schedule again. Update both sites in #{@ci}."
  end

  defp scheduled_crons do
    ~r/^\s*- cron:\s*"([^"]+)"/m
    |> Regex.scan(File.read!(@ci))
    |> Enum.map(fn [_line, cron] -> cron end)
  end

  # Scoped to the scale-nightly job block (its keys are indented deeper than the 2-space
  # job key), so an `if:` belonging to any other job cannot satisfy the guard.
  defp scale_nightly_if_cron do
    lines = @ci |> File.read!() |> String.split("\n")
    start = Enum.find_index(lines, &(&1 =~ ~r/^  scale-nightly:\s*$/))

    refute is_nil(start), "#{@ci} must declare the scale-nightly job"

    block =
      lines
      |> Enum.drop(start + 1)
      |> Enum.take_while(&(not (&1 =~ ~r/^  \S/)))
      |> Enum.join("\n")

    case Regex.run(~r/^\s*if:.*github\.event\.schedule\s*==\s*'([^']+)'/m, block) do
      [_line, cron] ->
        cron

      nil ->
        flunk(
          "scale-nightly must gate its schedule arm on an exact cron string " <>
            "(github.event.schedule == '...'), or the 02:00 nightly cron starts the matrix"
        )
    end
  end
end
