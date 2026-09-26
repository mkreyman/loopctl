defmodule Loopctl.Repo.Migrations.CreateThreadLedger do
  @moduledoc """
  The change-thread ledger (US-45.1, Epic 45 PRD §3): the checkpoints a story's thread
  recorded and the entries written around them. No backfill and no manual step; both tables
  start empty.

  A checkpoint is a git commit on the thread branch that the story's CURRENT claimant reported
  under its `claim_epoch`. loopctl never infers one from a branch head, because git cannot see
  a claim epoch and a reclaimed runner can still push (PRD §4 item 2).

  An entry is text a session or a person wrote on purpose — a message, a finding, a fix, a
  verdict — never a transcript. Bodies are UNTRUSTED and fenced wherever they are rendered.

  `story_id` carries no foreign key, as in `triage_verdicts`: the ledger is the record of what
  was said about a change and must outlive anything that prunes a story's working rows. Neither
  id comes from the wire unchecked; the context reads the story under RLS before writing.

  RLS is ENABLED (not FORCE): the production role owns the table without BYPASSRLS.
  """

  use Ecto.Migration

  def up do
    create table(:thread_checkpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :story_id, :binary_id, null: false
      add :seq, :integer, null: false
      add :kind, :string, null: false, default: "checkpoint"
      add :commit_sha, :string, null: false
      add :tree_sha, :string, null: false
      add :parent_checkpoint_id, :binary_id
      add :claim_epoch, :integer, null: false
      add :dispatch_id, :binary_id
      add :merge_commit_sha, :string
      add :gate_evidence, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:thread_checkpoints, [:tenant_id, :story_id, :seq])
    # Keyed by claim: a claimant resuming at a commit an ENDED claim recorded records it again
    # under its own claim, so the fixes it writes can cite a checkpoint of the current claim.
    create unique_index(:thread_checkpoints, [:tenant_id, :story_id, :commit_sha, :claim_epoch])

    create constraint(:thread_checkpoints, :thread_checkpoints_kind,
             check: "kind IN ('checkpoint', 'base_update')"
           )

    create table(:thread_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :story_id, :binary_id, null: false
      add :seq, :integer, null: false
      add :kind, :string, null: false
      add :author_principal, :string, null: false
      add :dispatch_id, :binary_id
      add :idempotency_key, :string, null: false
      add :body, :text, null: false

      add :checkpoint_id,
          # NO ACTION, not RESTRICT: it is checked at the END of the statement, so a tenant
          # delete that cascades into both tables removes the entries before the check runs.
          references(:thread_checkpoints, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:thread_entries, [:tenant_id, :story_id, :seq])

    # The checkpoint's own entry is read by checkpoint_id on every replay, and the foreign key
    # is checked on every checkpoint delete; both would otherwise scan the table.
    create index(:thread_entries, [:checkpoint_id])

    # THE IDEMPOTENCY KEY, per author: a retried write from the same principal finds its row,
    # and two principals never collide on a key only one of them chose.
    create unique_index(
             :thread_entries,
             [:tenant_id, :story_id, :author_principal, :idempotency_key],
             name: :thread_entries_idempotency_uidx
           )

    create constraint(:thread_entries, :thread_entries_kind,
             check:
               "kind IN ('message', 'checkpoint', 'review_requested', 'finding', 'fix', " <>
                 "'verdict', 'escalation', 'merge')"
           )

    for table <- ~w(thread_checkpoints thread_entries) do
      execute("ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY")

      execute("""
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_policies
          WHERE tablename = '#{table}' AND policyname = 'tenant_isolation'
        ) THEN
          EXECUTE 'CREATE POLICY tenant_isolation ON #{table} USING (tenant_id = current_tenant_id())';
        END IF;
      END $$;
      """)
    end
  end

  def down do
    execute("DROP POLICY IF EXISTS tenant_isolation ON thread_entries")
    execute("DROP POLICY IF EXISTS tenant_isolation ON thread_checkpoints")
    drop table(:thread_entries)
    drop table(:thread_checkpoints)
  end
end
