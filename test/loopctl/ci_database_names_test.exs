defmodule Loopctl.CiDatabaseNamesTest do
  @moduledoc """
  Every database `ci.yml` creates on a fleet-ci host's shared CI Postgres is named per run
  ATTEMPT, not per run (#983).

  A re-run keeps its `github.run_id`. Named from the run id alone, a re-run of an attempt that
  was cancelled before its drop step finds that attempt's database, `mix ecto.create` no-ops
  on it, and the CI database reaper (mkreyman/infra#313), which ages a database by its
  creation time, can drop it in the idle gap between two steps.

  Jobs with their own `services: postgres` container (scale-test, pgbouncer-e2e) start from an
  empty instance each time and are out of scope.
  """
  use ExUnit.Case, async: true

  @ci Path.expand("../../.github/workflows/ci.yml", __DIR__)

  setup_all do
    %{lines: @ci |> File.read!() |> String.split("\n")}
  end

  test "every job-level database name carries the run id and the run attempt", %{lines: lines} do
    names =
      Enum.filter(lines, &Regex.match?(~r/^\s+(MIX_TEST_PARTITION|DEV_DB_NAME):\s/, &1))

    # The test job and retrieval-eval. An empty set would make the loop below vacuous.
    assert length(names) >= 2, "found #{inspect(names)}"

    for line <- names do
      assert line =~ "${{ github.run_id }}", line
      assert line =~ "${{ github.run_attempt }}", line
    end
  end

  test "scale-nightly derives its database from the run id and the run attempt",
       %{lines: lines} do
    derived = Enum.filter(lines, &(&1 =~ ~r/^\s+suffix="\$\{suffix:0:\d+\}_/))

    assert [line] = derived

    assert line =~ "${{ github.run_id }}_${{ github.run_attempt }}"
    assert Enum.any?(lines, &(&1 =~ ~s(echo "SCALE_DB=${db}")))
    assert Enum.any?(lines, &(&1 =~ ~s(echo "MIX_TEST_PARTITION=_sn_${suffix}")))
  end
end
