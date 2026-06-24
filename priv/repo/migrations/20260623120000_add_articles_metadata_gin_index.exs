defmodule Loopctl.Repo.Migrations.AddArticlesMetadataGinIndex do
  use Ecto.Migration

  @moduledoc """
  GIN index on `articles.metadata` so the agent-memory scoped-context filters
  (`metadata @> '{"memory_type": ...}'` / `agent_id` / `conversation_id`) use the
  index instead of a sequential scan at scale (#151).
  """

  def change do
    create index(:articles, [:metadata], using: :gin)
  end
end
