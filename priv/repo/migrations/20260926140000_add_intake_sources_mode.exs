defmodule Loopctl.Repo.Migrations.AddIntakeSourcesMode do
  @moduledoc """
  US-45.4 (Epic 45, change threads): how a repository's changes reach its base branch.

  `pr` is the route every source has always taken — a pull request the merge gate reads from
  GitHub by number. `thread` is the change-thread route: the gate reads the story's latest
  RECORDED checkpoint instead, and needs no pull request at all (PRD §3, §4).

  DEFAULT 'pr' and NOT NULL, so every existing source keeps exactly the behaviour it had and
  nothing ever has to guess for a missing value. `PATCH /api/v1/intake/sources/:id` and the
  `intake_source_update` MCP tool set it.

  No backfill and no manual step.
  """

  use Ecto.Migration

  def up do
    alter table(:intake_sources) do
      add :mode, :string, null: false, default: "pr", size: 16
    end

    create constraint(:intake_sources, :intake_sources_mode, check: "mode IN ('pr', 'thread')")
  end

  def down do
    drop constraint(:intake_sources, :intake_sources_mode)

    alter table(:intake_sources) do
      remove :mode
    end
  end
end
