defmodule Loopctl.Repo.Migrations.CreateThreadReviews do
  @moduledoc """
  Review dispatches on a change thread (US-45.3, Epic 45 PRD §6). No backfill and no manual
  step; the table starts empty and the new `thread_entries` columns are NULL on every
  existing row, which is what a `message` or `checkpoint` entry carries.

  A `thread_reviews` row is written only by loopctl when it places a review: the dispatch it
  minted for the reviewer, the checkpoint that review reads and the round it was placed for.
  It is the ONE thing a `finding` or `verdict` author is checked against. The author is never
  inferred from the calling key's agent or lineage (#901).

  `dispatch_id` carries no foreign key, as `thread_entries.dispatch_id` does not: dispatches
  are written on `AdminRepo` and this table on the RLS `Repo`. The context reads the dispatch
  by the key that authenticated, so the id never comes from the wire.

  A round is completed by its review's ONE `verdict` entry (partial unique index below), and
  the round count and the ceiling are computed from `thread_entries` alone.

  RLS is ENABLED (not FORCE): the production role owns the table without BYPASSRLS.
  """

  use Ecto.Migration

  def up do
    create table(:thread_reviews, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :story_id, :binary_id, null: false
      add :dispatch_id, :binary_id, null: false
      add :agent_id, :binary_id, null: false

      add :checkpoint_id,
          references(:thread_checkpoints, type: :binary_id, on_delete: :nothing),
          null: false

      add :round, :integer, null: false
      add :placed_by, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:thread_reviews, [:tenant_id, :dispatch_id])
    create index(:thread_reviews, [:tenant_id, :story_id])
    create index(:thread_reviews, [:checkpoint_id])

    create constraint(:thread_reviews, :thread_reviews_round, check: "round BETWEEN 1 AND 3")

    alter table(:thread_entries) do
      add :review_id, references(:thread_reviews, type: :binary_id, on_delete: :nothing)
      add :severity, :string
      add :location, :string, size: 1024
      add :introduced_by, :string
      add :finding_ids, {:array, :binary_id}
    end

    create index(:thread_entries, [:review_id])

    # ONE verdict per review dispatch: the verdict IS the completed round.
    create unique_index(:thread_entries, [:review_id],
             where: "kind = 'verdict'",
             name: :thread_entries_one_verdict_per_review_uidx
           )

    create constraint(:thread_entries, :thread_entries_severity,
             check: "severity IS NULL OR severity IN ('critical', 'high', 'medium', 'low')"
           )

    create constraint(:thread_entries, :thread_entries_introduced_by,
             check:
               "introduced_by IS NULL OR introduced_by = 'none' OR " <>
                 "introduced_by ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'"
           )

    # The judgement kinds carry what makes them judgements; nothing else carries any of it.
    create constraint(:thread_entries, :thread_entries_judgement_shape,
             check: """
             CASE kind
               WHEN 'finding' THEN review_id IS NOT NULL AND severity IS NOT NULL
                 AND checkpoint_id IS NOT NULL AND finding_ids IS NULL
               WHEN 'verdict' THEN review_id IS NOT NULL AND checkpoint_id IS NOT NULL
                 AND severity IS NULL AND introduced_by IS NULL AND finding_ids IS NULL
               WHEN 'fix' THEN review_id IS NULL AND checkpoint_id IS NOT NULL
                 AND cardinality(finding_ids) >= 1 AND severity IS NULL
                 AND introduced_by IS NULL
               WHEN 'escalation' THEN severity IS NULL AND introduced_by IS NULL
                 AND finding_ids IS NULL
               ELSE review_id IS NULL AND severity IS NULL AND introduced_by IS NULL
                 AND finding_ids IS NULL AND location IS NULL
             END
             """
           )

    execute("ALTER TABLE thread_reviews ENABLE ROW LEVEL SECURITY")

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'thread_reviews' AND policyname = 'tenant_isolation'
      ) THEN
        EXECUTE 'CREATE POLICY tenant_isolation ON thread_reviews USING (tenant_id = current_tenant_id())';
      END IF;
    END $$;
    """)
  end

  def down do
    drop constraint(:thread_entries, :thread_entries_judgement_shape)
    drop constraint(:thread_entries, :thread_entries_introduced_by)
    drop constraint(:thread_entries, :thread_entries_severity)
    drop index(:thread_entries, [:review_id], name: :thread_entries_one_verdict_per_review_uidx)
    drop index(:thread_entries, [:review_id])

    alter table(:thread_entries) do
      remove :finding_ids
      remove :introduced_by
      remove :location
      remove :severity
      remove :review_id
    end

    execute("DROP POLICY IF EXISTS tenant_isolation ON thread_reviews")
    drop table(:thread_reviews)
  end
end
