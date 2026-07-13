defmodule Loopctl.Telemetry.ObanStatsTest do
  @moduledoc """
  US-34.1 (AC-34.1.1/.2): `Loopctl.Telemetry.ObanStats` is the real `oban_jobs`
  read behind the US-34.1 observability poll — the per-(state, queue) count query
  and the `:executing` orphan-age query. `oban_jobs` is a GLOBAL infra table (no
  `tenant_id`, no RLS), so these tests seed via `fixture(:oban_job, ...)` (which
  inserts through `Loopctl.Repo`, matching the module under test) rather than the
  usual `AdminRepo`-backed fixtures.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.Telemetry.ObanStats

  describe "job_state_counts/0 (AC-34.1.1, TC-34.1.1)" do
    test "returns one {state, queue, count} tuple per seeded (state, queue) group" do
      fixture(:oban_job, state: "available", queue: "default")
      fixture(:oban_job, state: "available", queue: "default")
      fixture(:oban_job, state: "completed", queue: "webhooks")

      counts = ObanStats.job_state_counts()

      assert {"available", "default", 2} in counts
      assert {"completed", "webhooks", 1} in counts
      assert length(counts) == 2
    end

    test "returns an empty list when oban_jobs has no rows" do
      assert ObanStats.job_state_counts() == []
    end
  end

  describe "executing_orphan_count/1 (AC-34.1.2, TC-34.1.2)" do
    test "counts only :executing jobs whose attempted_at is older than the threshold" do
      stale_attempted_at = DateTime.add(DateTime.utc_now(), -35 * 60, :second)
      recent_attempted_at = DateTime.add(DateTime.utc_now(), -5 * 60, :second)

      fixture(:oban_job, state: "executing", attempted_at: stale_attempted_at)
      fixture(:oban_job, state: "executing", attempted_at: recent_attempted_at)
      # A non-executing job, even with a stale attempted_at, must never count.
      fixture(:oban_job, state: "completed", attempted_at: stale_attempted_at)

      assert ObanStats.executing_orphan_count(30) == 1
    end

    test "returns 0 when no executing job is stale" do
      fixture(:oban_job, state: "executing", attempted_at: DateTime.utc_now())

      assert ObanStats.executing_orphan_count(30) == 0
    end

    test "returns 0 when oban_jobs has no rows at all" do
      assert ObanStats.executing_orphan_count(30) == 0
    end
  end
end
