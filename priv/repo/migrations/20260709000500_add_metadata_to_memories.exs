defmodule Loopctl.Repo.Migrations.AddMetadataToMemories do
  use Ecto.Migration

  # US-28.4 review finding (contract/schema drift, silent data loss): the
  # memory_remember MCP tool and the /api/v1/memory HTTP controller
  # (@memory_attr_keys) both advertise/forward a generic `metadata` param, but
  # ONLY `session_memories` had a `metadata` column — the default `long_term`
  # tier silently dropped it (no column, no cast, no render). This adds the
  # same `:map, default: %{}` column to `memories` so the advertised contract
  # holds for BOTH tiers, mirroring `session_memories.metadata`
  # (create_memory_stores.exs).
  def change do
    alter table(:memories) do
      add :metadata, :map, null: false, default: %{}
    end
  end
end
