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
      add :embedding, :vector, size: 1536, null: true
      add :embedding_content_hash, :string, null: true
      add :confidence, :float, null: false, default: 1.0
      add :source, :string, null: false, default: "explicit"
      add :source_session_id, :string, null: true
      add :tags, {:array, :string}, null: false, default: []

      add :superseded_by, references(:memories, type: :binary_id, on_delete: :nilify_all),
        null: true

      timestamps(type: :utc_datetime_usec)
    end

    # Backs (tenant_id, subject_id) scope filtering on the OLTP path.
    create index(:memories, [:tenant_id, :subject_id])

    enable_rls(:memories)
  end
end
