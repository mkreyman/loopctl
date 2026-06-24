defmodule Loopctl.Repo.Migrations.AddArticlesMetadataGinIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  GIN index on `articles.metadata` so the agent-memory scoped-context filters
  (`metadata @> '{"memory_type": ...}'` / `agent_id` / `conversation_id`) use the
  index instead of a sequential scan at scale (#151). Built concurrently to avoid
  blocking writes to articles during the build.
  """

  def change do
    create index(:articles, [:metadata], using: :gin, concurrently: true)
  end
end
