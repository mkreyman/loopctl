defmodule Loopctl.Repo.Migrations.CreateChgReviewDispatches do
  @moduledoc """
  US-50.3: `chg_review_dispatches`, one row per review dispatch an intake source minted under
  its chg root for one `(change_id, revision)` (`Loopctl.Changes.ReviewDispatches`).

  Every mint is kept, newest live: a re-mint before any verdict revokes the earlier dispatch
  and adds a row, and a verdict recorded by ANY of a key's dispatches refuses further mints.
  `repo` is the canonical key, held by a CHECK as on `change_events`.

  A new table and nothing else, so the code running before this release keeps working during
  Fly's rolling deploy.
  """

  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def up do
    create table(:chg_review_dispatches, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :source_id, references(:intake_sources, type: :binary_id, on_delete: :delete_all),
        null: false

      add :repo, :string, null: false
      add :change_id, :string, null: false
      add :revision, :integer, null: false

      add :dispatch_id, references(:dispatches, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:chg_review_dispatches, [:tenant_id, :source_id, :repo, :change_id, :revision])
    create unique_index(:chg_review_dispatches, [:dispatch_id])

    create constraint(:chg_review_dispatches, :chg_review_dispatches_repo_canonical,
             check: "repo = lower(repo)"
           )

    create constraint(:chg_review_dispatches, :chg_review_dispatches_revision_positive,
             check: "revision >= 1"
           )

    enable_rls(:chg_review_dispatches)
  end

  def down do
    drop table(:chg_review_dispatches)
  end
end
