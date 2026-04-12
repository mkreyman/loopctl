defmodule Loopctl.Repo.Migrations.AddDispatchFieldsToStories do
  use Ecto.Migration

  def change do
    alter table(:stories) do
      add :implementer_dispatch_id, references(:dispatches, type: :binary_id, on_delete: :nothing)
      add :verifier_dispatch_id, references(:dispatches, type: :binary_id, on_delete: :nothing)
      add :verifier_needed, :boolean, default: false
    end

    create index(:stories, [:implementer_dispatch_id])
    create index(:stories, [:verifier_dispatch_id])
  end
end
