defmodule Loopctl.Repo.TriageDispatchBackfillMigrationTest do
  @moduledoc """
  Epic 44, US-44.2 round 3, finding 1 — the BACKFILL in
  `20260923130000_add_story_stages_triage_dispatch_id.exs`.

  A row triaged before `story_stages.triage_dispatch_id` existed can never leave `triaged`
  unbound: `Stages.advance/4` refuses a session dispatch the row does not name. The backfill
  binds a row past `detected` to its story's ONE recorded verdict, and leaves NULL every row
  whose decider the data does not name.

  Driven the way `Loopctl.Repo.RunnerAgentBackfillMigrationTest` drives its migration: loaded at
  runtime and run with `Ecto.Migration.Runner.run/9` in THIS process, so the DDL sits inside the
  sandbox transaction and the down -> up sequence is rolled back on exit. Rows are seeded while
  the column still exists and `down` then takes it away, which leaves exactly the pre-column
  world the backfill runs against.
  """

  use ExUnit.Case, async: false

  import Loopctl.Fixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migration.Runner
  alias Loopctl.AdminRepo

  @version 20_260_923_130_000
  @migrations_dir Path.join([File.cwd!(), "priv", "repo", "migrations"])

  migration_file = Path.wildcard(Path.join(@migrations_dir, "#{@version}_*.exs")) |> hd()
  Code.require_file(migration_file)

  alias Loopctl.Repo.Migrations.AddStoryStagesTriageDispatchId

  setup do
    pid = Sandbox.start_owner!(AdminRepo)
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  test "binds a triaged row to its ONE verdict's dispatch, and nothing else" do
    tenant = fixture(:tenant)

    one = stage_row(tenant, :triaged, verdicts: 1)
    queued = stage_row(tenant, :queued, verdicts: 1)
    detected = stage_row(tenant, :detected, verdicts: 1)
    several = stage_row(tenant, :triaged, verdicts: 2)
    none = stage_row(tenant, :triaged, verdicts: 0)

    migrate(:down)
    migrate(:up)

    assert bound(one) == hd(one.dispatches)
    assert bound(queued) == hd(queued.dispatches)

    # Still at `detected`: its triage step is ahead of it, and that step writes the binding.
    assert bound(detected) == nil

    # Which of two verdicts decided it is not in the data; a guess could hand Gate A a loser's.
    assert bound(several) == nil

    # No verdict decided it — the dispatcher's too-large route, among others.
    assert bound(none) == nil
  end

  test "a verdict in ANOTHER tenant for the same story id binds nothing" do
    tenant = fixture(:tenant)
    other = fixture(:tenant)
    row = stage_row(tenant, :triaged, verdicts: 0)

    fixture(:triage_verdict, %{
      tenant_id: other.id,
      story_id: row.story_id,
      repo: AdminRepo,
      bind: false
    })

    migrate(:down)
    migrate(:up)

    assert bound(row) == nil
  end

  defp stage_row(tenant, stage, verdicts: count) do
    story = fixture(:story, %{tenant_id: tenant.id})

    fixture(:story_stage, %{
      tenant_id: tenant.id,
      story_id: story.id,
      stage: stage,
      repo: AdminRepo
    })

    dispatches =
      for _ <- 1..count//1 do
        fixture(:triage_verdict, %{
          tenant_id: tenant.id,
          story_id: story.id,
          repo: AdminRepo,
          bind: false
        }).dispatch_id
      end

    %{story_id: story.id, dispatches: dispatches}
  end

  defp bound(%{story_id: story_id}) do
    %{rows: [[dispatch_id]]} =
      AdminRepo.query!("SELECT triage_dispatch_id FROM story_stages WHERE story_id = $1::uuid", [
        Ecto.UUID.dump!(story_id)
      ])

    case dispatch_id do
      nil -> nil
      raw -> Ecto.UUID.load!(raw)
    end
  end

  defp migrate(direction) do
    Runner.run(
      AdminRepo,
      AdminRepo.config(),
      @version,
      AddStoryStagesTriageDispatchId,
      :forward,
      direction,
      direction,
      log: false
    )
  end
end
