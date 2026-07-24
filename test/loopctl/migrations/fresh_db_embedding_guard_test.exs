defmodule Loopctl.Migrations.FreshDbEmbeddingGuardTest do
  @moduledoc """
  #495: fresh-DB / no-pgvector migration tolerance.

  Proves the pin migration `20260721000300` no longer raises `42703 column
  a.embedding does not exist` when the legacy `articles.embedding` column was
  skipped by the pgvector guard on a non-superuser install, and that the heal
  migration `20260724180000` re-adds it once pgvector is available. The column is
  dropped INSIDE the sandbox transaction and restored on rollback.

  `async: false` — it takes an ACCESS EXCLUSIVE DDL lock on `articles`.
  """
  use Loopctl.DataCase, async: false

  alias Loopctl.AdminRepo

  # Mirrors the `articles` branch of the guarded UPDATE in
  # `20260721000300_pin_existing_tenant_embedding_dimensions.exs`. The
  # information_schema guard is what must make it a no-op when the column is absent.
  @pin_articles_guarded_sql """
  DO $$
  BEGIN
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_name = 'articles' AND column_name = 'embedding'
    ) THEN
      UPDATE tenants t
         SET tenant_embedding_dimension = 1536
       WHERE t.tenant_embedding_dimension IS NULL
         AND EXISTS (SELECT 1 FROM articles a WHERE a.tenant_id = t.id AND a.embedding IS NOT NULL);
    END IF;
  END $$;
  """

  # Mirrors the `articles` branch of `20260724180000_heal_skipped_legacy_embedding_columns.exs`.
  @heal_articles_sql """
  DO $$
  BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector') THEN
      IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'articles' AND column_name = 'embedding'
      ) THEN
        ALTER TABLE articles ADD COLUMN embedding vector(1536);
      END IF;
    END IF;
  END $$;
  """

  defp embedding_column_exists? do
    %{rows: [[n]]} =
      AdminRepo.query!(
        "SELECT count(*) FROM information_schema.columns WHERE table_name = $1 AND column_name = $2",
        ["articles", "embedding"]
      )

    n == 1
  end

  test "the pin guard is a no-op when articles.embedding is absent (no 42703 crash)" do
    AdminRepo.query!("ALTER TABLE articles DROP COLUMN embedding CASCADE")
    refute embedding_column_exists?()

    # Pre-#495 this raised `42703 column a.embedding does not exist`.
    assert %Postgrex.Result{} = AdminRepo.query!(@pin_articles_guarded_sql)
  end

  test "the heal migration re-adds articles.embedding when pgvector is present" do
    AdminRepo.query!("ALTER TABLE articles DROP COLUMN embedding CASCADE")
    refute embedding_column_exists?()

    AdminRepo.query!(@heal_articles_sql)
    assert embedding_column_exists?()
  end

  test "the guarded pin migration still runs cleanly when the column IS present (no regression)" do
    assert embedding_column_exists?()
    assert %Postgrex.Result{} = AdminRepo.query!(@pin_articles_guarded_sql)
  end
end
