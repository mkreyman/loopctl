defmodule Loopctl.Repo.Migrations.CreateSessionPromotions do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  # Epic 29 (Agent Memory, Part 2 / auto-promotion), US-29.2.
  #
  # `session_promotions` is the promotion WATERMARK: one row per
  # (tenant_id, subject_id, session_id) recording the content hash the session was
  # last compiled at. Both promotion triggers (the explicit per-session job and the
  # cross-tenant cron sweep) skip a session whose CURRENT content hash equals the
  # stored watermark's — so an unchanged session is never re-compiled (kills the
  # re-LLM-every-tick + paraphrase-drift problems). It is upserted on EVERY compile
  # run, including zero-survivor runs.
  #
  # The PARTIAL UNIQUE INDEX on `memories` gives the exact-dedupe backstop: two
  # concurrent promotion workers writing the same candidate text (same
  # `embedding_content_hash`) for the same (tenant, subject) cannot double-insert a
  # `:promoted` row. `embedding_content_hash` already exists on `memories`
  # (20260709000000) — only the index is new here. `source` is stored as text
  # (Ecto.Enum → `:string`), so the partial predicate is `source = 'promoted'`.

  def change do
    create table(:session_promotions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :subject_id, :string, null: false
      add :session_id, :string, null: false
      add :session_content_hash, :string, null: false
      add :last_turn_inserted_at, :utc_datetime_usec, null: true
      add :promoted_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # The watermark identity: one row per session in a subject's scope. Upserts
    # (ON CONFLICT ... DO UPDATE) target this index.
    create unique_index(:session_promotions, [:tenant_id, :subject_id, :session_id],
             name: :session_promotions_scope_session_uniq_idx
           )

    # Backs the per-tenant compiles/hour budget count (rows with recent promoted_at).
    create index(:session_promotions, [:tenant_id, :promoted_at])

    enable_rls(:session_promotions)

    # Exact-dedupe backstop for promoted memories (AC-29.2.3): a partial UNIQUE index
    # over (tenant_id, subject_id, embedding_content_hash) restricted to promoted rows,
    # so `ON CONFLICT DO NOTHING` on the promotion write path is race-safe against a
    # concurrent explicit+sweep double-insert. Explicit (`:explicit`) memories are NOT
    # constrained (a user may legitimately store the same text twice).
    create unique_index(:memories, [:tenant_id, :subject_id, :embedding_content_hash],
             where: "source = 'promoted'",
             name: :memories_promoted_content_hash_uniq_idx
           )
  end
end
