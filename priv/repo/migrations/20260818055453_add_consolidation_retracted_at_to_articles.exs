defmodule Loopctl.Repo.Migrations.AddConsolidationRetractedAtToArticles do
  @moduledoc """
  A DURABLE marker that the nightly consolidation pass retracted an article.

  `DraftDuplicateSweepWorker` must not re-archive a draft that consolidation deliberately
  unpublished, and the only record of that authorship was the `audit_log` — which is
  retention-bounded (`:audit_retention_days`, 90 by default, enforced by
  `AuditPartitionWorker`). Past the horizon the evidence is simply gone, so the sweep could
  not tell "consolidation retracted this" from "a human drafted this", and the safe reading
  of an absent record is the wrong one in one direction: it would archive consolidation's
  own work through a one-way door.

  The review of 2026-08-18 made the sweep fail CLOSED past that horizon, which is correct
  and costs a real thing: a draft older than the window is never a candidate again. This
  column shrinks what that bound has to cover, from "every aged draft" to "only those
  retracted before this migration ran AND already past retention".

  ## Why a COLUMN and not a `metadata` key

  Exactly the `stories.lifecycle_entered_at` precedent. `metadata` is cast and
  whole-map-REPLACED by `PATCH /api/v1/knowledge/:id`, so one ordinary update erases the
  marker and hands the sweep back the ambiguity this exists to remove. A column cannot be
  cleared by a caller that does not know it is there.

  **Never add `:consolidation_retracted_at` to a changeset `cast` list.** It is written
  programmatically by `Loopctl.Knowledge.Consolidation` and by nothing else.

  Nullable with no default, so the ALTER is catalog-only on PG11+ — no table rewrite, unlike
  `20260817212906`.
  """

  use Ecto.Migration

  def up do
    alter table(:articles) do
      add :consolidation_retracted_at, :utc_datetime_usec
    end

    # Partial: only retracted rows are ever looked up by it, and they are a small minority.
    create index(:articles, [:tenant_id, :consolidation_retracted_at],
             where: "consolidation_retracted_at IS NOT NULL",
             name: :articles_consolidation_retracted_idx
           )

    # BACKFILL, and it has to happen HERE rather than being left to accrue forward.
    #
    # The marker can only be stamped from now on, so without this every article
    # consolidation has already retracted stays provable only through the audit_log — and
    # that evidence keeps expiring, partition by partition. Converting it while it still
    # exists is a one-time opportunity: after the next drop those rows are unprovable
    # forever, and the sweep's horizon is the only thing standing between them and a
    # terminal archive.
    #
    # The audit entry's `inserted_at` IS the retraction time, which is what the marker
    # means. `DISTINCT ON` because an article may carry more than one such entry; the most
    # recent is the one that left it a draft.
    execute("""
    UPDATE articles a
    SET consolidation_retracted_at = src.retracted_at
    FROM (
      SELECT DISTINCT ON (al.tenant_id, al.entity_id)
             al.tenant_id, al.entity_id, al.inserted_at AS retracted_at
      FROM audit_log al
      WHERE al.entity_type = 'article'
        AND al.action = 'article.unpublished'
        AND al.actor_label = 'worker:consolidation'
      ORDER BY al.tenant_id, al.entity_id, al.inserted_at DESC
    ) src
    WHERE a.tenant_id = src.tenant_id
      AND a.id = src.entity_id
      AND a.consolidation_retracted_at IS NULL
    """)
  end

  def down do
    drop_if_exists index(:articles, [:tenant_id, :consolidation_retracted_at],
                     name: :articles_consolidation_retracted_idx
                   )

    alter table(:articles) do
      remove :consolidation_retracted_at
    end
  end
end
