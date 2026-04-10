defmodule Loopctl.Repo.Migrations.EnablePgvectorAndAddEmbedding do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    alter table(:articles) do
      add :embedding, :"vector(1536)", null: true
    end
  end

  def down do
    alter table(:articles) do
      remove :embedding
    end

    execute "DROP EXTENSION IF EXISTS vector"
  end
end
