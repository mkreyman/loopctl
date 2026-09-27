defmodule Loopctl.Repo.Migrations.AddIntakeSourcesRequiredChecks do
  @moduledoc """
  US-45.6 (Epic 45, change threads): the CI checks a thread-mode checkpoint must pass on its
  exact commit before the merge gate allows it.

  A pull request gets its required checks from the base branch's protection, enforced by
  GitHub at merge time. A thread has no pull request, and the loopctl App pushes the squash
  commit to the base itself, so no forge rule can hold the merge to a green checkpoint: the
  gate reads the checks by SHA and needs to know which ones are required. They are named
  here, per repository.

  NOT NULL, default the empty list, so every existing source is unchanged: a `pr`-mode source
  never reads the column. A `thread`-mode source must name at least one check, which the
  changeset enforces on every write (`Loopctl.Intake.Source.validate_required_checks/1`) and
  the gate backstops by refusing `required_checks_unset`.

  No backfill and no manual step.
  """

  use Ecto.Migration

  def change do
    alter table(:intake_sources) do
      add :required_checks, {:array, :string}, null: false, default: []
    end
  end
end
