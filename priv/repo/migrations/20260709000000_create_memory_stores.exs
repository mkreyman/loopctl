defmodule Loopctl.Repo.Migrations.CreateMemoryStores do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  # Epic 28 (Agent Memory, Part 1). Creates the two memory persistence tables,
  # kept strictly separate from the Knowledge Wiki `articles` table.
  #
  # Both Ecto.Enum-backed columns (`role`, `source`) are plain `:string` in the
  # DB — Ecto.Enum stores the value as text and creates NO Postgres enum type,
  # so there is no orphaned enum type to drop on rollback (AC-28.1.7).
  #
  # The HNSW index on `memories.embedding` is created in a SEPARATE migration
  # (`AddMemoriesEmbeddingHnswIndex`) because it must run with
  # `@disable_ddl_transaction`, whereas this CREATE TABLE + btree + RLS work runs
  # inside a transaction.

  def change do
    # --- session_memories: short-term, append-only, expiring (no embedding) ---
    create table(:session_memories, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: true

      add :session_id, :string, null: false
      add :subject_id, :string, null: false
      add :role, :string, null: true
      add :content, :text, null: false
      add :metadata, :map, null: false, default: %{}
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    # Chronological read of a session's log within a tenant.
    create index(:session_memories, [:tenant_id, :session_id, :inserted_at])

    # Backs the US-28.2 prune worker (delete where expires_at < now()).
    create index(:session_memories, [:expires_at])

    enable_rls(:session_memories)

    # --- memories: long-term, embedded (vector populated async in US-28.2) ---
    create table(:memories, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      # nilify_all (NOT delete_all): a long-term memory is a durable, semantically
      # recalled fact. Deleting its project must NOT destroy it — it falls back to
      # tenant-wide scope (project_id = NULL), matching the schema's documented
      # `null = tenant-wide` semantics. (session_memories keeps delete_all: those
      # rows are short-lived and expire regardless.)
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all), null: true

      add :subject_id, :string, null: false
      add :text, :text, null: false
      # `embedding vector(1536)` is added in a SEPARATE, pgvector-guarded step
      # below — NOT inline here — so this CREATE TABLE stays runnable on a DB
      # without the pgvector extension (see the guarded execute after this block).
      add :embedding_content_hash, :string, null: true
      add :confidence, :float, null: false, default: 1.0
      add :source, :string, null: false, default: "explicit"
      add :source_session_id, :string, null: true
      add :tags, {:array, :string}, null: false, default: []

      add :superseded_by, references(:memories, type: :binary_id, on_delete: :nilify_all),
        null: true

      timestamps(type: :utc_datetime_usec)
    end

    # --- embedding column: pgvector-guarded, graceful degradation ---
    #
    # The `vector` type only exists where the pgvector extension is installed.
    # An inline `add :embedding, :vector` inside CREATE TABLE would raise
    # `type "vector" does not exist` and abort the WHOLE migration on any
    # environment that lacks the extension (Fly.io Managed Postgres pre-ticket,
    # DR restore, self-host, a fresh region). We mirror the established
    # graceful-degradation pattern from
    # `20260410022854_enable_pgvector_and_add_embedding.exs`: only add the
    # column when `pg_extension` shows `vector` is present. Where it is absent
    # the table stays migratable and the column simply doesn't exist yet — the
    # async embedding worker (US-28.2) already tolerates a missing/NULL embedding
    # and the HNSW index migration is likewise capability-gated. Once pgvector is
    # enabled, a follow-up migration adds the column + backfills.
    #
    # execute/2 supplies both directions so `change/0` stays reversible: the down
    # side drops the column if it exists (the table drop that follows on rollback
    # would remove it anyway, but this keeps the step self-consistent).
    execute(
      """
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector') THEN
          IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name = 'memories' AND column_name = 'embedding'
          ) THEN
            ALTER TABLE memories ADD COLUMN embedding vector(1536);
          END IF;
        END IF;
      END $$;
      """,
      """
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_name = 'memories' AND column_name = 'embedding'
        ) THEN
          ALTER TABLE memories DROP COLUMN embedding;
        END IF;
      END $$;
      """
    )

    # Backs (tenant_id, subject_id) scope filtering on the OLTP path.
    create index(:memories, [:tenant_id, :subject_id])

    enable_rls(:memories)
  end
end
