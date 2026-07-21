defmodule Loopctl.Repo.Migrations.HardenCustodyPostureEntries do
  use Ecto.Migration

  import Loopctl.Repo.RlsHelpers

  # US-41.7 review hardening.
  #
  # Three defects in the first cut are structural and need schema support:
  #
  # 1. COMPLETENESS WAS MEASURED AGAINST THE SURVIVING ROWS. `claim_state/2` took
  #    `max(operation_sequence)` over the entries it could still see, so losing
  #    the LAST entry of a sequence (0,1,2 -> lose 2) left a contiguous 0..1 and
  #    the claim flipped back to a satisfied attestation. Worse, the
  #    `MAX(operation_sequence) + 1` allocator then REUSED the erased number,
  #    destroying the evidence. `custody_row_sequences` persists the per-row
  #    HIGH-WATER MARK independently of the entries, so tail loss is a gap and a
  #    number is never handed out twice.
  #
  # 2. THE SEQUENCE WAS ALLOCATED AFTER THE PROVIDER CALL on the embed paths, so
  #    a call that egressed and then failed (5xx, timeout, node death) wrote
  #    nothing and left the surviving sequence contiguous — reporting
  #    no-third-party-egress for a row whose body did leave. Allocation now
  #    happens BEFORE the outbound call and `outcome` is patched afterwards.
  #    `outcome` is bookkeeping, so it is mutable — but only monotonically, from
  #    `in_flight` to a terminal value, enforced by the immutability trigger.
  #
  # 3. NOTHING BOUND AN ENTRY TO THE MERKLE LEAF the inclusion proof proves.
  #    `chain_entry_hash` records the leaf hash of the batch that carried this
  #    entry, so a third party can match the claim against
  #    `GET /audit/sth/:tenant/inclusion/:position` end to end.
  #
  # Plus the invariants the raw-SQL write path had no changeset to enforce:
  # `subject_type` and `operation` were completely unvalidated, so a bad value
  # persisted a permanently unreadable entry that still consumed a sequence
  # number (and therefore silently satisfied contiguity).

  def change do
    create table(:custody_row_sequences, primary_key: false) do
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :subject_type, :string, null: false
      add :subject_id, :binary_id, null: false

      # The NEXT sequence number to hand out. `next_sequence - 1` is the HIGHEST
      # ASSIGNED number AC-41.7.2 requires contiguity to be proven up to — a fact
      # that must survive the deletion of every entry it counted.
      add :next_sequence, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :custody_row_sequences,
             [:tenant_id, :subject_type, :subject_id],
             name: :custody_row_sequences_row_idx
           )

    create constraint(:custody_row_sequences, :custody_row_sequences_next_check,
             check: "next_sequence >= 0"
           )

    enable_rls(:custody_row_sequences)

    alter table(:custody_posture_entries) do
      # in_flight -> succeeded | failed. Recorded BEFORE the provider call, so a
      # call that egressed and then died is still a recorded operation.
      add :outcome, :string, null: false, default: "in_flight"
      # The merkle LEAF hash of the chain entry carrying this posture, so the
      # claim binds to the inclusion proof rather than to a bare position.
      add :chain_entry_hash, :binary
    end

    create constraint(:custody_posture_entries, :custody_posture_entries_outcome_check,
             check: "outcome IN ('in_flight','succeeded','failed')"
           )

    create constraint(:custody_posture_entries, :custody_posture_entries_subject_type_check,
             check: "subject_type IN ('article','memory')"
           )

    create constraint(:custody_posture_entries, :custody_posture_entries_operation_check,
             check: "operation IN ('create','embed','reembed','classify','merge')"
           )

    # The stale-pending reaper and the pending failure surface both scan
    # (tenant, state, updated_at).
    create index(:custody_posture_entries, [:tenant_id, :state, :updated_at])

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

        -- `outcome` is bookkeeping, but only MONOTONIC: once an operation has a
        -- terminal outcome it can never be rewritten (least of all back to a
        -- rosier one).
        IF OLD.outcome <> 'in_flight' AND NEW.outcome IS DISTINCT FROM OLD.outcome THEN
          RAISE EXCEPTION 'custody posture outcome is terminal and immutable';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
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
      """
    )
  end
end
