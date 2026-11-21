defmodule Loopctl.Repo.Migrations.AddHolderToClaims do
  @moduledoc """
  US-52.14: a claim names its holder.

  `stories.assigned_holder_id` and `channel_claims.claimant_holder_id` record which
  session (a `holders` row, US-52.13) holds the item, so two sessions of one agent are
  told apart. Both nullable with no backfill: a claim made before this release has no
  holder and keeps the agent-id checks. `nilify_all`, because a holder row goes only
  with its tenant, and a claim should never block that delete.
  """
  use Ecto.Migration

  def change do
    alter table(:stories) do
      add :assigned_holder_id, references(:holders, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:channel_claims) do
      add :claimant_holder_id, references(:holders, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:stories, [:assigned_holder_id])
    create index(:channel_claims, [:claimant_holder_id])
  end
end
