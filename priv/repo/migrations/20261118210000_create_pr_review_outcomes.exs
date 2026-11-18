defmodule Loopctl.Repo.Migrations.CreatePrReviewOutcomes do
  @moduledoc """
  US-50.4: `pr_review_outcomes`, one row per merged pull request on a repository with an intake
  source: the PR body's `## Review findings` section, parsed
  (`Loopctl.Changes.PrReviewOutcomes`). A re-run replaces the row, so `(tenant_id, repo,
  pr_number)` is unique. `repo` is the canonical key, held by a CHECK as on `change_events`.

  A new table and nothing else, so the code running before this release keeps working during
  Fly's rolling deploy.
  """

  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def up do
    create table(:pr_review_outcomes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :source_id, references(:intake_sources, type: :binary_id, on_delete: :delete_all),
        null: false

      add :repo, :string, null: false
      add :pr_number, :integer, null: false
      add :merged_at, :utc_datetime_usec
      add :merge_sha, :string
      add :has_review_section, :boolean, null: false
      add :findings, {:array, :map}, null: false, default: []
      add :unparsed, {:array, :text}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:pr_review_outcomes, [:tenant_id, :repo, :pr_number])
    create index(:pr_review_outcomes, [:tenant_id, :merged_at])

    create constraint(:pr_review_outcomes, :pr_review_outcomes_repo_canonical,
             check: "repo = lower(repo)"
           )

    create constraint(:pr_review_outcomes, :pr_review_outcomes_pr_number_positive,
             check: "pr_number >= 1"
           )

    enable_rls(:pr_review_outcomes)
  end

  def down do
    drop table(:pr_review_outcomes)
  end
end
