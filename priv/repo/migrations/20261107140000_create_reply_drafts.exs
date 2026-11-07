defmodule Loopctl.Repo.Migrations.CreateReplyDrafts do
  @moduledoc """
  `reply_draft@1` (Epic 48, US-48.9): the first `:draft` spec, and the table its one effect
  writes.

  ## `runner_dispatches_kind` gains `reply_draft`

  The ledger's kind CHECK is one of the lists `Loopctl.Agents.RegistryTest` holds equal to the
  registry and `RunnerContract.Kinds.all/0`, so it widens in the same release that adds the
  spec. Widening a CHECK refuses nothing an older release writes.

  ## `reply_drafts`

  One row per drafted reply to a support ticket triage set aside (rejected or escalated). A
  human reads it and sends it, or not: NOTHING in loopctl sends it anywhere, because a reply
  goes out in the operator's name (Epic 48 PRD, default 2).

  - `status` — `drafted` (the body passed the injection screen) or `refused` (it did not, or
    the ticket was too large to hand a session at all). A refused row is kept so the story
    stops being a candidate and an operator can see why it has no draft.
  - `body` — the drafted reply, SESSION-AUTHORED from a session that read the customer's own
    words: data for a person to read, never executed. NULL on a refused row: a body the
    screen refused is not stored at all, so it cannot be mistaken for a draft or copied out
    of this table.
  - `screen_code` — which screen refused it (`injection_detector_draft`, `payload_too_large`);
    `screen_signals` — the detector's own `"<signal>:<field>"` codes, loopctl's vocabulary,
    never the session's words.
  - `ticket_id` — the intake record's ticket, so a person can find the ticket to answer.
    Required on a `drafted` row; a refused row may lack it.
  - `dispatch_id` — the `reply_draft` dispatch whose result this is; NULL only for a
    dispatch-time refusal (`payload_too_large`), where no dispatch was sent.

  ## The unique indexes are the idempotency

  `(tenant_id, dispatch_id)` makes the effect write once per dispatch, and `(tenant_id,
  story_id)` makes "no draft yet" — the candidate read's `:no_reply_draft` — a property of the
  storage: a late result from an earlier dispatch of the same story finds the row there and
  writes nothing.

  ## Isolation

  `tenant_id` on every row, RLS ENABLED (not FORCE — the production role owns the table without
  BYPASSRLS), with the same `tenant_isolation` policy as its siblings. No foreign key on
  `dispatch_id` (the ledger row is pruned; this record must outlive it, as `triage_verdicts`
  does); `story_id` and `project_id` reference their tables with the tenant.

  No backfill and no manual step: the table starts empty.
  """

  use Ecto.Migration

  def up do
    drop constraint(:runner_dispatches, :runner_dispatches_kind)

    create constraint(:runner_dispatches, :runner_dispatches_kind,
             check: "kind IN ('triage', 'implement', 'reply_draft')"
           )

    create table(:reply_drafts, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false
      add :dispatch_id, :binary_id
      add :ticket_id, :binary_id
      add :status, :string, null: false
      add :body, :text
      add :screen_code, :string
      add :screen_signals, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:reply_drafts, [:tenant_id, :dispatch_id],
             name: :reply_drafts_dispatch_uidx,
             where: "dispatch_id IS NOT NULL"
           )

    create unique_index(:reply_drafts, [:tenant_id, :story_id], name: :reply_drafts_story_uidx)

    # The list endpoint: a project's drafts, newest first, keyset on (inserted_at, id).
    create index(:reply_drafts, [:tenant_id, :project_id, :inserted_at, :id])

    create constraint(:reply_drafts, :reply_drafts_status,
             check: "status IN ('drafted', 'refused')"
           )

    # A draft carries a body and a ticket and no screen; a refusal carries a screen and no body.
    create constraint(:reply_drafts, :reply_drafts_shape,
             check:
               "(status = 'drafted' AND body IS NOT NULL AND ticket_id IS NOT NULL " <>
                 "AND screen_code IS NULL) OR " <>
                 "(status = 'refused' AND body IS NULL AND screen_code IS NOT NULL)"
           )

    execute("ALTER TABLE reply_drafts ENABLE ROW LEVEL SECURITY")

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'reply_drafts' AND policyname = 'tenant_isolation'
      ) THEN
        EXECUTE 'CREATE POLICY tenant_isolation ON reply_drafts USING (tenant_id = current_tenant_id())';
      END IF;
    END $$;
    """)
  end

  def down do
    execute("DROP POLICY IF EXISTS tenant_isolation ON reply_drafts")
    drop table(:reply_drafts)

    execute("DELETE FROM runner_dispatches WHERE kind = 'reply_draft'")
    drop constraint(:runner_dispatches, :runner_dispatches_kind)

    create constraint(:runner_dispatches, :runner_dispatches_kind,
             check: "kind IN ('triage', 'implement')"
           )
  end
end
