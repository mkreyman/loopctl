defmodule Loopctl.Repo.Migrations.CreateCustodyPostureEntries do
  use Ecto.Migration

  import Loopctl.Repo.RlsHelpers

  # US-41.7 (AC-41.7.9): the ONE table this story introduces. It carries
  # `tenant_id` and is protected by `enable_rls/1` (ENABLE, not FORCE).
  #
  # The row is BOTH the outbox and the record (AC-41.7.2 / AC-41.7.7):
  #
  #   * it is INSERTED inside the content transaction, which is what ASSIGNS the
  #     monotonic per-row `operation_sequence` and captures the RESOLVED posture
  #     for that operation (AC-41.7.1 / AC-41.7.3);
  #   * an Oban batch job later appends ONE audit-chain entry per BATCH and flips
  #     the claimed rows to `recorded`, stamping `chain_position` — so the hot
  #     path never makes a per-article AdminRepo chain round-trip (AC-41.7.7).
  #
  # The `(tenant_id, subject_type, subject_id, operation_sequence)` unique index
  # IS the idempotency key AC-41.7.7 names: an Oban retry after a partial success
  # cannot produce a duplicate in an append-only, hash-chained structure.

  def change do
    create table(:custody_posture_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      # The subject row this posture entry is bound to. Deliberately NOT an FK:
      # a custody claim must survive the deletion of the row it describes (the
      # claim is evidence about what loopctl did, not a projection of live state).
      add :subject_type, :string, null: false
      add :subject_id, :binary_id, null: false

      # Monotonic per-(tenant, subject) sequence, assigned in the content
      # transaction. Contiguity from 0..max is what proves COMPLETENESS.
      add :operation_sequence, :integer, null: false
      add :operation, :string, null: false

      # The RESOLVED posture for THIS operation — never re-read later.
      add :posture, :map, null: false, default: %{}
      add :local_endpoints_only, :boolean, null: false, default: false
      add :occurred_at, :utc_datetime_usec, null: false

      # pending -> recorded (chain append flushed) | failed (append dropped).
      add :state, :string, null: false, default: "pending"
      add :batch_id, :binary_id
      add :chain_entry_id, :binary_id
      add :chain_position, :bigint
      add :failure_reason, :string
      add :recorded_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :custody_posture_entries,
             [:tenant_id, :subject_type, :subject_id, :operation_sequence],
             name: :custody_posture_entries_row_sequence_idx
           )

    create index(:custody_posture_entries, [:tenant_id, :state])
    create index(:custody_posture_entries, [:tenant_id, :batch_id])

    create constraint(:custody_posture_entries, :custody_posture_entries_state_check,
             check: "state IN ('pending','recorded','failed')"
           )

    create constraint(:custody_posture_entries, :custody_posture_entries_sequence_check,
             check: "operation_sequence >= 0"
           )

    enable_rls(:custody_posture_entries)

    # AC-41.7.3: the RECORDED FACTS are immutable at the DATABASE, not by
    # convention. Only the outbox/flush columns (state, batch_id, chain_*,
    # failure_reason, recorded_at, updated_at) may ever change; a later settings
    # change can therefore not rewrite what a historical entry says about the
    # endpoints actually used at that operation.
    execute(
      """
      CREATE OR REPLACE FUNCTION custody_posture_entries_immutable()
      RETURNS TRIGGER AS $$
      BEGIN
        IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
           OR NEW.subject_type IS DISTINCT FROM OLD.subject_type
           OR NEW.subject_id IS DISTINCT FROM OLD.subject_id
           OR NEW.operation_sequence IS DISTINCT FROM OLD.operation_sequence
           OR NEW.operation IS DISTINCT FROM OLD.operation
           OR NEW.posture::text IS DISTINCT FROM OLD.posture::text
           OR NEW.local_endpoints_only IS DISTINCT FROM OLD.local_endpoints_only
           OR NEW.occurred_at IS DISTINCT FROM OLD.occurred_at
           OR NEW.inserted_at IS DISTINCT FROM OLD.inserted_at THEN
          RAISE EXCEPTION 'custody posture entries are immutable';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION IF EXISTS custody_posture_entries_immutable()"
    )

    execute(
      """
      CREATE TRIGGER custody_posture_entries_immutable_trigger
      BEFORE UPDATE ON custody_posture_entries
      FOR EACH ROW EXECUTE FUNCTION custody_posture_entries_immutable();
      """,
      "DROP TRIGGER IF EXISTS custody_posture_entries_immutable_trigger ON custody_posture_entries"
    )
  end
end
