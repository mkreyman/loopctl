defmodule Loopctl.Repo.Migrations.AddIntakeSourcesRequiredChecks do
  @moduledoc """
  US-45.6 (Epic 45, change threads): the CI checks a thread-mode checkpoint must pass on its
  exact commit before the merge gate allows it.

  A pull request gets its required checks from the base branch's protection, enforced by
  GitHub at merge time. A thread has no pull request, and the loopctl App pushes the squash
  commit to the base itself, so no forge rule can hold the merge to a green checkpoint: the
  gate reads the checks by SHA and needs to know which ones are required. They are named
  here, per repository.

  NOT NULL, default the empty list. A `pr`-mode source never reads the column and is
  unchanged. A `thread`-mode source must name at least one check, which the changeset enforces
  on every write (`Loopctl.Intake.Source.validate_required_checks/1`) and the gate backstops
  by refusing `required_checks_unset`.

  MANUAL STEP for any `thread`-mode source enrolled BEFORE this migration: it has no required
  checks, so every one of its stories is refused `required_checks_unset` until an operator
  names them (`intake_source_update` with `required_checks`). No backfill: loopctl cannot know
  which CI jobs a repository requires.
  """

  use Ecto.Migration

  def change do
    alter table(:intake_sources) do
      add :required_checks, {:array, :string}, null: false, default: []
    end
  end
end
