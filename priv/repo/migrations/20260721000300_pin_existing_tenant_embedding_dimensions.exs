defmodule Loopctl.Repo.Migrations.PinExistingTenantEmbeddingDimensions do
  @moduledoc """
  US-41.1 review #6 — PIN `tenants.tenant_embedding_dimension` for every tenant that
  already has a corpus.

  `Loopctl.Embeddings.active_dimension/1` resolves
  `recorded || model_table || default`. The column shipped NULL with no backfill, so
  for every pre-41.1 tenant the MODEL TABLE was authoritative: editing
  `tenant_llm_settings.embedding_model` to e.g. `nomic-embed-text` immediately moved
  the active dimension to 768 while the entire stored corpus was still 1536. Recall
  then queried dim 768 against a 1536 corpus and returned nothing, and the
  `total_count` was computed at the new dimension too, so nothing flagged it.

  Pinning the recorded value makes the corpus's ACTUAL shape authoritative and
  reduces the model table to what it is: a hint for a tenant that has not embedded
  anything yet. Moving a pinned tenant to a new dimension is then exactly one
  supported operation — the AC-41.1.10 re-embed, which flips the pin only after the
  whole corpus is present at the target.

  ## Fresh-DB / no-pgvector tolerance (#495)

  On a fresh install where `CREATE EXTENSION vector` was unavailable at
  `20260410022854` (migrations run as the non-superuser `loopctl_admin`), the early
  guard SKIPPED the legacy `articles.embedding` / `memories.embedding` columns and
  marked itself done, so they never exist when this migration runs. Referencing them
  unconditionally raised `42703 column a.embedding does not exist` and wedged the
  whole chain. Each corpus source is now probed for existence first, so a missing
  legacy column or side table simply contributes no rows — which is CORRECT: a tenant
  with no such storage has no corpus to pin, and on a fresh DB there is nothing to pin
  at all. The `20260724180000` heal migration re-adds the legacy columns once pgvector
  becomes available.
  """

  use Ecto.Migration

  def up do
    # One guarded UPDATE per corpus source. Splitting the original single OR into
    # independent, existence-guarded statements is equivalent (each is idempotent:
    # SET ... WHERE tenant_embedding_dimension IS NULL) while tolerating a source
    # whose column/table the pgvector guard skipped on this deployment.
    execute("""
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

      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'memories' AND column_name = 'embedding'
      ) THEN
        UPDATE tenants t
           SET tenant_embedding_dimension = 1536
         WHERE t.tenant_embedding_dimension IS NULL
           AND EXISTS (SELECT 1 FROM memories m WHERE m.tenant_id = t.id AND m.embedding IS NOT NULL);
      END IF;

      IF to_regclass('public.article_embeddings') IS NOT NULL THEN
        UPDATE tenants t
           SET tenant_embedding_dimension = 1536
         WHERE t.tenant_embedding_dimension IS NULL
           AND EXISTS (SELECT 1 FROM article_embeddings ae WHERE ae.tenant_id = t.id AND ae.dim = 1536);
      END IF;

      IF to_regclass('public.memory_embeddings') IS NOT NULL THEN
        UPDATE tenants t
           SET tenant_embedding_dimension = 1536
         WHERE t.tenant_embedding_dimension IS NULL
           AND EXISTS (SELECT 1 FROM memory_embeddings me WHERE me.tenant_id = t.id AND me.dim = 1536);
      END IF;
    END $$;
    """)
  end

  # Irreversible by design: the pin records a FACT about the stored corpus, and
  # un-pinning would hand authority back to the mutable model table — the exact
  # failure this migration closes. `down` is a no-op rather than a data-losing
  # `SET NULL`.
  def down, do: :ok
end
