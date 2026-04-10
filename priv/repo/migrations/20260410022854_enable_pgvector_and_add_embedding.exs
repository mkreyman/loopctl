defmodule Loopctl.Repo.Migrations.EnablePgvectorAndAddEmbedding do
  use Ecto.Migration

  def up do
    # pgvector requires superuser to CREATE EXTENSION. On Fly.io Managed Postgres,
    # file a support ticket to enable it, then re-run migrations.
    # This migration skips gracefully if the extension is not available.
    execute """
    DO $$
    BEGIN
      CREATE EXTENSION IF NOT EXISTS vector;
    EXCEPTION
      WHEN insufficient_privilege THEN
        RAISE WARNING 'pgvector: insufficient privilege to CREATE EXTENSION vector. Skipping embedding column. File a Fly.io support ticket to enable pgvector.';
        RETURN;
    END $$;
    """

    # Only add the column if the extension was successfully created
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector') THEN
        IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'articles' AND column_name = 'embedding') THEN
          ALTER TABLE articles ADD COLUMN embedding vector(1536);
        END IF;
      END IF;
    END $$;
    """
  end

  def down do
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'articles' AND column_name = 'embedding') THEN
        ALTER TABLE articles DROP COLUMN embedding;
      END IF;
    END $$;
    """
  end
end
