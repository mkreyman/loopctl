defmodule Loopctl.Repo.Migrations.CreateEmbeddingSideTables do
  use Ecto.Migration

  import Loopctl.Repo.RlsHelpers

  @moduledoc """
  US-41.1 AC-41.1.1 / AC-41.1.4.

  Moves the embedding vector off the fixed-width `articles.embedding` /
  `memories.embedding` columns (both `vector(1536)`) and onto DIMENSION-TAGGED
  side tables, so a tenant may run an embedding model whose native dimension is
  not 1536 (nomic-embed 768, bge 1024, text-embedding-3-large 3072) on the SAME
  shared hosted instance.

  ## Why a side table and not a second column

  The dimension is pinned by the COLUMN TYPE. `:embedding_dimensions` is a
  changeset validation only. A per-tenant dimension therefore needs a relation
  whose vector column is UNCONSTRAINED (`vector`, no typmod) plus an explicit
  `dim` discriminator; the per-dimension ANN index is then an expression index
  over an explicit cast (see the companion index migration).

  ## Uniqueness — `(tenant_id, article_id, dim)`, NOT `(article_id)`

  AC-41.1.1 requires two dimensions to COEXIST for the same row (the US-41.2
  re-embed window and the system corpus), so `dim` is part of the key. The
  `tenant_id` leg is the AC-41.1.7 reconciliation: system-scoped articles
  (`articles.tenant_id IS NULL`, `scope = :system`) are embedded ON DEMAND PER
  TENANT with that tenant's own BYO credential and written as ordinary rows
  carrying the REQUESTING tenant's `tenant_id`. Two tenants materializing the
  same system article at the same dim are two legitimate rows, so a bare
  `(article_id, dim)` unique index would make the chosen design unimplementable.
  For a tenant-scoped article `tenant_id` is functionally determined by
  `article_id`, so the two forms are equivalent there.

  ## `live_denorm` is synced BY TRIGGER (mandatory)

  The US-28.2 partial HNSW index predicate (`WHERE superseded_by IS NULL`) is not
  expressible across tables, so the live marker is denormalized onto the
  embedding row. `update_all`, raw SQL, migration backfills and future
  graduation/merge paths all bypass application code, and a desynchronized marker
  silently either lets superseded rows occupy ANN pool slots (the US-28.2
  regression) or drops live rows from recall. The enforcing mechanism is
  therefore a PL/pgSQL trigger pair per table (the repo's existing convention for
  this class of invariant — see the audit chain). An application-level write is
  permitted only as a convenience, never as the sole mechanism.

  * `memory_embeddings.live_denorm` mirrors `memories.superseded_by IS NULL`.
  * `article_embeddings.live_denorm` mirrors `articles.status <> 'superseded'` —
    articles have NO `superseded_by` column; supersession is the `:superseded`
    status value (`Loopctl.Knowledge.Article` `@status_values`).

  ## Length enforcement at the DB

  A CHECK constraint ties `vector_dims(embedding)` to `dim`, so a wrong-length
  vector can never be silently stored even if it bypasses the changeset.
  """

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS article_embeddings (
      id uuid PRIMARY KEY,
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
      article_id uuid NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
      dim integer NOT NULL,
      embedding vector NOT NULL,
      live_denorm boolean NOT NULL DEFAULT true,
      embedding_content_hash text,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL,
      CONSTRAINT article_embeddings_dim_positive CHECK (dim > 0),
      CONSTRAINT article_embeddings_dim_matches_vector
        CHECK (vector_dims(embedding) = dim)
    )
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS memory_embeddings (
      id uuid PRIMARY KEY,
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
      memory_id uuid NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
      subject_id text NOT NULL,
      dim integer NOT NULL,
      embedding vector NOT NULL,
      live_denorm boolean NOT NULL DEFAULT true,
      embedding_content_hash text,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL,
      CONSTRAINT memory_embeddings_dim_positive CHECK (dim > 0),
      CONSTRAINT memory_embeddings_dim_matches_vector
        CHECK (vector_dims(embedding) = dim)
    )
    """)

    create_if_not_exists(
      unique_index(:article_embeddings, [:tenant_id, :article_id, :dim],
        name: :article_embeddings_tenant_article_dim_index
      )
    )

    create_if_not_exists(
      unique_index(:memory_embeddings, [:tenant_id, :memory_id, :dim],
        name: :memory_embeddings_tenant_memory_dim_index
      )
    )

    # Reconciliation / backfill scan support (AC-41.1.8(i), AC-41.1.9): find the
    # rows of a tenant at a dimension without touching the vector.
    create_if_not_exists(index(:article_embeddings, [:tenant_id, :dim]))
    create_if_not_exists(index(:memory_embeddings, [:tenant_id, :dim]))
    # `guard_memory!/3`'s outermost subject equality (AC-41.1.6) is served here.
    create_if_not_exists(index(:memory_embeddings, [:tenant_id, :subject_id, :dim]))

    enable_rls(:article_embeddings)
    enable_rls(:memory_embeddings)

    # --- live_denorm: parent -> side table (BEFORE INSERT/UPDATE on the side table) ---

    execute("""
    CREATE OR REPLACE FUNCTION article_embeddings_set_live_denorm() RETURNS trigger AS $$
    DECLARE
      parent_status text;
    BEGIN
      SELECT a.status INTO parent_status FROM articles a WHERE a.id = NEW.article_id;
      NEW.live_denorm := COALESCE(parent_status, 'draft') <> 'superseded';
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION memory_embeddings_set_live_denorm() RETURNS trigger AS $$
    DECLARE
      parent_superseded_by uuid;
      parent_exists boolean;
    BEGIN
      SELECT m.superseded_by, true INTO parent_superseded_by, parent_exists
      FROM memories m WHERE m.id = NEW.memory_id;
      NEW.live_denorm := COALESCE(parent_exists, false) AND parent_superseded_by IS NULL;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("DROP TRIGGER IF EXISTS article_embeddings_live_denorm_trg ON article_embeddings")

    execute("""
    CREATE TRIGGER article_embeddings_live_denorm_trg
      BEFORE INSERT OR UPDATE ON article_embeddings
      FOR EACH ROW EXECUTE FUNCTION article_embeddings_set_live_denorm();
    """)

    execute("DROP TRIGGER IF EXISTS memory_embeddings_live_denorm_trg ON memory_embeddings")

    execute("""
    CREATE TRIGGER memory_embeddings_live_denorm_trg
      BEFORE INSERT OR UPDATE ON memory_embeddings
      FOR EACH ROW EXECUTE FUNCTION memory_embeddings_set_live_denorm();
    """)

    # --- live_denorm: parent status change -> side table (AFTER UPDATE on the parent) ---
    #
    # Row-level AFTER triggers fire for `Repo.update_all` and raw SQL too, which is
    # exactly why the invariant lives here and not in application code (TC-41.1.6).

    execute("""
    CREATE OR REPLACE FUNCTION articles_propagate_live_denorm() RETURNS trigger AS $$
    BEGIN
      UPDATE article_embeddings ae
        SET live_denorm = (NEW.status <> 'superseded'), updated_at = ae.updated_at
        WHERE ae.article_id = NEW.id
          AND ae.live_denorm IS DISTINCT FROM (NEW.status <> 'superseded');
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION memories_propagate_live_denorm() RETURNS trigger AS $$
    BEGIN
      UPDATE memory_embeddings me
        SET live_denorm = (NEW.superseded_by IS NULL), updated_at = me.updated_at
        WHERE me.memory_id = NEW.id
          AND me.live_denorm IS DISTINCT FROM (NEW.superseded_by IS NULL);
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("DROP TRIGGER IF EXISTS articles_live_denorm_propagate_trg ON articles")

    execute("""
    CREATE TRIGGER articles_live_denorm_propagate_trg
      AFTER UPDATE OF status ON articles
      FOR EACH ROW
      WHEN (OLD.status IS DISTINCT FROM NEW.status)
      EXECUTE FUNCTION articles_propagate_live_denorm();
    """)

    execute("DROP TRIGGER IF EXISTS memories_live_denorm_propagate_trg ON memories")

    execute("""
    CREATE TRIGGER memories_live_denorm_propagate_trg
      AFTER UPDATE OF superseded_by ON memories
      FOR EACH ROW
      WHEN (OLD.superseded_by IS DISTINCT FROM NEW.superseded_by)
      EXECUTE FUNCTION memories_propagate_live_denorm();
    """)

    # --- AC-41.1.4: the tenant's recorded embedding dimension ---
    #
    # NULL = "not explicitly recorded": `Loopctl.Embeddings.active_dimension/1`
    # derives it from the tenant's `embedding_model` via the static model table and
    # falls back to `:embedding_dimensions` (1536). Stored ON THE TENANT (not on
    # `tenant_llm_settings`) because the dimension governs the SHAPE of every stored
    # vector for that tenant, which outlives any single model/credential row.
    alter table(:tenants) do
      add_if_not_exists(:tenant_embedding_dimension, :integer)
    end

    execute("""
    ALTER TABLE tenants
      DROP CONSTRAINT IF EXISTS tenants_embedding_dimension_positive
    """)

    execute("""
    ALTER TABLE tenants
      ADD CONSTRAINT tenants_embedding_dimension_positive
      CHECK (tenant_embedding_dimension IS NULL OR tenant_embedding_dimension > 0)
    """)
  end

  def down do
    execute("""
    ALTER TABLE tenants
      DROP CONSTRAINT IF EXISTS tenants_embedding_dimension_positive
    """)

    alter table(:tenants) do
      remove_if_exists(:tenant_embedding_dimension, :integer)
    end

    execute("DROP TRIGGER IF EXISTS articles_live_denorm_propagate_trg ON articles")
    execute("DROP TRIGGER IF EXISTS memories_live_denorm_propagate_trg ON memories")
    execute("DROP FUNCTION IF EXISTS articles_propagate_live_denorm()")
    execute("DROP FUNCTION IF EXISTS memories_propagate_live_denorm()")
    execute("DROP TABLE IF EXISTS article_embeddings")
    execute("DROP TABLE IF EXISTS memory_embeddings")
    execute("DROP FUNCTION IF EXISTS article_embeddings_set_live_denorm()")
    execute("DROP FUNCTION IF EXISTS memory_embeddings_set_live_denorm()")
  end
end
