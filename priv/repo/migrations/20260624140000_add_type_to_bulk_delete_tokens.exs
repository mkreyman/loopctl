defmodule Loopctl.Repo.Migrations.AddTypeToBulkDeleteTokens do
  use Ecto.Migration

  # US-27.12 review round 2: add type field to distinguish frozen-set tokens from
  # oversized reconfirm nonces. Frozen-set tokens have article_ids frozen from the
  # preview and are consumed once on delete. Oversized reconfirm nonces are
  # placeholder rows used to block replays of the re-confirm-on-drift path.
  def change do
    alter table(:knowledge_bulk_delete_tokens) do
      add :type, :string, null: false, default: "frozen_token"
    end

    # Index on (tenant_id, type) for filtering by type
    create index(:knowledge_bulk_delete_tokens, [:tenant_id, :type])
  end
end
