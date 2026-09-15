defmodule Loopctl.Repo.Migrations.AddIntakeSourcesBaseBranch do
  @moduledoc """
  Issue #803 review round 1, finding 7: the branch a dispatch is cut FROM, per repository.

  `Loopctl.Delivery.DispatchDriver` hardcoded `"base_branch" => "master"`, and nothing in
  loopctl knew any better — `MergePrecondition.repo_for_story/1` returns a repository name and
  nothing else. GitHub has defaulted new repositories to `main` since 2020, so an unattended
  dispatch into one named a base that does not exist, and the failure arrives after the claim:
  the runner refuses or cuts the worktree from the wrong ref, and the story comes back
  `queued` with `agent_status: :pending`, which no automated path re-contracts.

  It belongs on the SOURCE because it is a fact about a repository and the source is already
  the per-repository row — one per `(tenant, repo_full_name)` while active. A fleet-wide
  config key would be wrong the moment two of a tenant's repositories differ, which is the
  ordinary case for the loop this column serves.

  DEFAULT 'master' and NOT NULL: that is what every dispatch carried before this migration, so
  no existing source changes behaviour, and a value is always present rather than being
  another nil the dispatch builder has to guess for. `PATCH /api/v1/intake/sources/:id` sets
  it — the column is reachable through a documented path from the moment it exists, which is
  the lesson `target_epic_id` cost three review rounds to learn.

  No backfill and no manual step.
  """

  use Ecto.Migration

  def up do
    alter table(:intake_sources) do
      add :base_branch, :string, null: false, default: "master", size: 255
    end

    create constraint(:intake_sources, :intake_sources_base_branch_shape,
             check: "char_length(base_branch) between 1 and 255"
           )
  end

  def down do
    drop constraint(:intake_sources, :intake_sources_base_branch_shape)

    alter table(:intake_sources) do
      remove :base_branch
    end
  end
end
