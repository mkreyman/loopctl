defmodule Loopctl.Repo.Migrations.AddChannelPostsSupersededBy do
  use Ecto.Migration

  # US-454 (defect 3): supersession as a REAL, machine-readable terminal state.
  # A post whose successor exists carries superseded_by = the successor's id, so
  # directed-handoff discovery can EXCLUDE retired handoffs (mirroring how a DONE
  # claim gates a handoff out) and the history read can MARK them. Self-FK with
  # nilify_all: hard-deleting (US-39.7) the successor clears the marker rather
  # than dangling.
  def change do
    alter table(:channel_posts) do
      add :superseded_by, references(:channel_posts, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:channel_posts, [:superseded_by],
             where: "superseded_by IS NOT NULL",
             name: :channel_posts_superseded_by_idx
           )
  end
end
