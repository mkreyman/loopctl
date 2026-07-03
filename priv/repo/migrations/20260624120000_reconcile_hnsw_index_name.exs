defmodule Loopctl.Repo.Migrations.ReconcileHnswIndexName do
  use Ecto.Migration

  # NO @disable_ddl_transaction — `ALTER INDEX ... RENAME` is metadata-only
  # (a brief ACCESS EXCLUSIVE lock, no table rewrite), so it WANTS the DDL
  # transaction. The rename + the idempotency guard run atomically.
  #
  # NO @disable_migration_lock either — and that is deliberate, not an
  # oversight. This migration runs inside Ecto's default
  # `pg_advisory_xact_lock` migration lock, which is acceptable here because:
  #
  #   1. On PROD the canonical `articles_embedding_hnsw_idx` already exists,
  #      so the up-step RETURNs at the idempotency guard BEFORE any DDL — no
  #      lock is ever held against the live ~76k-row index.
  #   2. Where it DOES fire (e.g. the test DB renaming `articles_embedding_idx`),
  #      `ALTER INDEX ... RENAME` is metadata-only: a brief ACCESS EXCLUSIVE
  #      lock with no rewrite, so holding the migration lock for its duration
  #      is cheap and safe.
  #
  # (Contrast: the CONCURRENT-recreate path — only needed if NO hnsw index
  # exists — would FORBID the transaction and require
  # `@disable_ddl_transaction true` / `@disable_migration_lock true`. Prod
  # was inspected before writing this migration: it already has a single
  # hnsw index named `articles_embedding_hnsw_idx`, so the RENAME path is
  # the correct, cheap, no-rewrite choice on the ~76k-row index.)

  @moduledoc """
  US-27.14 — Reconcile the HNSW index-name drift between the migration and prod.

  ## The problem

  Migration `20260410022906_add_embedding_hnsw_index.exs` creates the HNSW
  index on `articles(embedding)` as `articles_embedding_idx`. In PROD the
  live index was created out-of-band as `articles_embedding_hnsw_idx`. Three
  sibling stories tolerated this with name-agnostic detection
  (`articles_embedding(_hnsw)?_idx`), which masked a latent rollback bug:
  the old migration's down-step `DROP INDEX IF EXISTS articles_embedding_idx`
  silently NO-OPs against prod's differently-named index.

  ## The decision (USER sign-off 2026-06-24): RECONCILE to ONE canonical name

  Canonical name = `articles_embedding_hnsw_idx` (= whatever prod already
  uses, so the common path is a cheap, metadata-only RENAME and the live
  ~76k-row index is never rebuilt).

  This migration is **idempotent**:

    * If the canonical `articles_embedding_hnsw_idx` already exists → no-op
      (the prod case, and the case where this migration was already applied).
    * Else, if ANY hnsw index on `articles(embedding)` exists under a
      non-canonical name (e.g. the test DB, where the old migration created
      `articles_embedding_idx`) → `ALTER INDEX ... RENAME TO` the canonical
      name. Detection is by `am.amname = 'hnsw'`, NOT by a hard-coded name.
    * Else (no hnsw index at all, e.g. a build without pgvector) → no-op.

  After this lands, US-27.1/27.2/27.5 tighten the `(_hnsw)?_idx` tolerance to
  the single canonical name (still asserting `amname = 'hnsw'`).

  ## Canonical detection snippet (AC-27.14.4)

  Robust, name-independent detection of the HNSW index on `articles`:

      -- Simplest (by index definition):
      SELECT indexname
      FROM pg_indexes
      WHERE tablename = 'articles' AND indexdef ILIKE '%hnsw%';

      -- Or by access method (what this migration uses), exact and
      -- schema-qualified to the public `articles`:
      SELECT i.relname
      FROM pg_index x
      JOIN pg_class i ON i.oid = x.indexrelid
      JOIN pg_class t ON t.oid = x.indrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      JOIN pg_am    am ON am.oid = i.relam
      WHERE t.relname = 'articles' AND n.nspname = 'public' AND am.amname = 'hnsw';
  """

  # The capability-based (amname='hnsw'), `public`-schema-qualified reconcile SQL
  # — including the tightened idempotency guard (matches only an hnsw index of
  # the canonical NAME, so an unrelated relation squatting the name cannot
  # short-circuit reconciliation) and the name-agnostic RENAME — lives in
  # `Loopctl.Repo.HnswIndex.reconcile_sql/1`, parameterized by table name. For
  # `"articles"` it emits exactly the SQL this migration always ran; the shared
  # module lets the migration-behaviour test exercise the same logic against a
  # per-test throwaway table instead of the live `articles_embedding_hnsw_idx`.
  def up do
    execute(Loopctl.Repo.HnswIndex.reconcile_sql("articles"))
  end

  # The reconcile is a forward-only normalization; there is no destructive
  # rollback. Renaming the canonical index back to the old migration name
  # would only re-introduce the drift this story exists to remove, and the
  # old name is no longer referenced anywhere after AC-27.14.3. So `down` is
  # a deliberate no-op. (The orphaned-index / silent-no-op hazard that this
  # story fixes lives in the OLD migration's down-step, which is patched
  # separately per AC-27.14.2.)
  def down, do: :ok
end
