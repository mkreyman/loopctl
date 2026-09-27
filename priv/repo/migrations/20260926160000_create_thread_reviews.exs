defmodule Loopctl.Repo.Migrations.CreateThreadReviews do
  @moduledoc """
  Review dispatches on a change thread (US-45.3, Epic 45 PRD §6). No backfill and no manual
  step; the table starts empty and the new `thread_entries` columns are NULL on every
  existing row, which is what a `message` or `checkpoint` entry carries.

  A `thread_reviews` row is written only by loopctl when it places a review as a RUNNER
  dispatch of kind `review` (`Loopctl.Delivery.Placement.place_review/4`): the dispatch id the
  runner ledger carries, the runner and its agent, the claim epoch and checkpoint the review
  reads, and the round it was placed for. It is the ONE thing a `finding` or `verdict` is
  bound to: a judgement arrives over the runner socket naming this `dispatch_id`, from the
  runner holding it (#901 and #905 inferred the judge from an API key; no key exists here).

  `dispatch_id` and `runner_id` carry no foreign key: the ledger row is written after this
  one, by `Loopctl.Runners.dispatch/3`, and a refused push leaves this row inert rather than
  dangling a reference the ledger never wrote.

  A round is completed by its review's ONE `verdict` entry (partial unique index below), and
  the round count and the ceiling are computed from `thread_entries` alone.

  `placed_at_seq` is the thread's last entry `seq` when the review was placed: a fix counts
  toward a third round only if the thread recorded it by then, so nothing written while round
  2 is under way can reopen the decision it is making.

  `runner_dispatches_kind` admits `review` (runner contract 1.21.0), so the ledger can record
  a review dispatch. ROLLING BACK REFUSES while any review exists — a `thread_reviews` row or a
  `review` ledger row — and drops nothing then. With none, it drops `thread_reviews` and the
  judgement columns of `thread_entries` (every one NULL, since a judgement needs a review),
  and restores the per-author idempotency index and the kind CHECK.

  RLS is ENABLED (not FORCE): the production role owns the table without BYPASSRLS.
  """

  use Ecto.Migration

  def up do
    drop constraint(:runner_dispatches, :runner_dispatches_kind)

    create constraint(:runner_dispatches, :runner_dispatches_kind,
             check: "kind IN ('triage', 'implement', 'review')"
           )

    create table(:thread_reviews, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :story_id, :binary_id, null: false
      add :dispatch_id, :binary_id, null: false
      add :runner_id, :binary_id, null: false
      add :agent_id, :binary_id, null: false
      add :claim_epoch, :integer, null: false

      add :checkpoint_id,
          references(:thread_checkpoints, type: :binary_id, on_delete: :nothing),
          null: false

      add :round, :integer, null: false
      add :placed_at_seq, :integer, null: false
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

    # A judgement's idempotency key is scoped to its REVIEW, not its author: one reviewer agent
    # placed for two rounds may reuse a key, and its round-2 verdict is not a replay of round
    # 1's. Every other entry keeps the per-author scope US-45.1 gave it.
    drop index(:thread_entries, [:tenant_id, :story_id, :author_principal, :idempotency_key],
           name: :thread_entries_idempotency_uidx
         )

    create unique_index(
             :thread_entries,
             [:tenant_id, :story_id, :author_principal, :idempotency_key],
             where: "review_id IS NULL",
             name: :thread_entries_idempotency_uidx
           )

    create unique_index(:thread_entries, [:tenant_id, :review_id, :idempotency_key],
             where: "review_id IS NOT NULL",
             name: :thread_entries_review_idempotency_uidx
           )

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
                 AND finding_ids IS NOT NULL AND cardinality(finding_ids) >= 1 AND severity IS NULL
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
    # Down refuses while ANY review exists, rather than drop a review, its judgements (thread
    # entries are append-only and hash-chained) or a ledger row the kind CHECK would no longer
    # admit. With none, every judgement column is NULL and the per-author key index it restores
    # can be rebuilt, because only judgements were ever split out of it.
    %{rows: [[reviews]]} =
      repo().query!("""
      SELECT (SELECT count(*) FROM thread_reviews) +
             (SELECT count(*) FROM runner_dispatches WHERE kind = 'review')
      """)

    if reviews > 0 do
      raise Ecto.MigrationError,
        message:
          "cannot roll back #{__MODULE__}: #{reviews} review row(s) exist (thread_reviews or " <>
            "review-kind runner_dispatches). Rolling back would drop reviews and their " <>
            "judgements, which are append-only; it refuses and drops nothing."
    end

    drop constraint(:thread_entries, :thread_entries_judgement_shape)
    drop constraint(:thread_entries, :thread_entries_introduced_by)
    drop constraint(:thread_entries, :thread_entries_severity)
    drop index(:thread_entries, [:review_id], name: :thread_entries_one_verdict_per_review_uidx)

    drop index(:thread_entries, [:tenant_id, :review_id, :idempotency_key],
           name: :thread_entries_review_idempotency_uidx
         )

    drop index(:thread_entries, [:tenant_id, :story_id, :author_principal, :idempotency_key],
           name: :thread_entries_idempotency_uidx
         )

    create unique_index(
             :thread_entries,
             [:tenant_id, :story_id, :author_principal, :idempotency_key],
             name: :thread_entries_idempotency_uidx
           )

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

    drop constraint(:runner_dispatches, :runner_dispatches_kind)

    create constraint(:runner_dispatches, :runner_dispatches_kind,
             check: "kind IN ('triage', 'implement')"
           )
  end
end
