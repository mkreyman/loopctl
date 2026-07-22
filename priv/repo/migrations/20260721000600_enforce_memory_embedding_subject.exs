defmodule Loopctl.Repo.Migrations.EnforceMemoryEmbeddingSubject do
  use Ecto.Migration

  @moduledoc """
  US-41.1 AC-41.1.6 (review) — make the DENORMALIZED `memory_embeddings.subject_id`
  an ENFORCED copy of `memories.subject_id`.

  Agent-memory subject isolation is checked by `Loopctl.HeavyRead.guard_memory!/3`,
  which requires a conjunctive `subject_id` equality on the OUTERMOST query's binding
  0. The side-table recall satisfies that with `c.subject_id == ^scope.subject_id` on
  the `memory_embeddings` subquery while SELECTing the memory columns from the JOINED
  `memories` binding — so the guard validates the DENORMALIZED copy, not the returned
  rows' own subject.

  `live_denorm` is trigger-enforced in both directions precisely because `update_all`,
  raw SQL and backfills bypass changesets; `subject_id` had NO such enforcement — no
  trigger, no composite FK, no CHECK. Nothing mutates `memories.subject_id` today, so
  it is not exploitable now, but any future graduation/merge/repair path that does
  would silently convert a cross-subject leak into a GUARD-PASSING query.

  The invariant is therefore moved into the database:

    * a unique index on `memories (id, subject_id)` — the referencable target;
    * a COMPOSITE FK `memory_embeddings (memory_id, subject_id)` -> that target,
      `ON UPDATE CASCADE` (a subject move propagates instead of desynchronizing) and
      `ON DELETE CASCADE` (matching the existing single-column FK, which would
      otherwise conflict with a NO ACTION composite on delete).

  A supporting `(memory_id, subject_id)` index keeps the cascade lookups indexed —
  the existing indexes all lead with `tenant_id`.
  """

  def up do
    create_if_not_exists(
      unique_index(:memories, [:id, :subject_id], name: :memories_id_subject_id_index)
    )

    create_if_not_exists(
      index(:memory_embeddings, [:memory_id, :subject_id],
        name: :memory_embeddings_memory_subject_index
      )
    )

    # Repair any pre-existing drift before the constraint is added, so the migration
    # cannot fail on a row an earlier bypass path desynchronized.
    execute("""
    UPDATE memory_embeddings me
       SET subject_id = m.subject_id
      FROM memories m
     WHERE m.id = me.memory_id
       AND me.subject_id IS DISTINCT FROM m.subject_id
    """)

    execute("""
    ALTER TABLE memory_embeddings
      DROP CONSTRAINT IF EXISTS memory_embeddings_memory_subject_fkey
    """)

    execute("""
    ALTER TABLE memory_embeddings
      ADD CONSTRAINT memory_embeddings_memory_subject_fkey
      FOREIGN KEY (memory_id, subject_id) REFERENCES memories (id, subject_id)
      ON UPDATE CASCADE ON DELETE CASCADE
    """)
  end

  def down do
    execute("""
    ALTER TABLE memory_embeddings
      DROP CONSTRAINT IF EXISTS memory_embeddings_memory_subject_fkey
    """)

    drop_if_exists(
      index(:memory_embeddings, [:memory_id, :subject_id],
        name: :memory_embeddings_memory_subject_index
      )
    )

    drop_if_exists(
      unique_index(:memories, [:id, :subject_id], name: :memories_id_subject_id_index)
    )
  end
end
