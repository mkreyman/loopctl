defmodule Loopctl.Repo.Migrations.AddDisprovedCountToReviewRecords do
  use Ecto.Migration

  def change do
    alter table(:review_records) do
      add :disproved_count, :integer, default: 0, null: false
    end
  end
end
