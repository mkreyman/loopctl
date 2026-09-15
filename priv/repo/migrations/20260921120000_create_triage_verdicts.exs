defmodule Loopctl.Repo.Migrations.CreateTriageVerdicts do
  @moduledoc """
  One triage verdict per dispatch (issue #803, runner contract 1.9.0). No backfill, no manual
  step; the table starts empty because nothing emits a verdict yet.

  ## The unique index is the feature, not an optimisation

  A triage session records exactly one verdict per run and cannot restate it — the runner
  hard-links the file deliberately, so a session that has stopped cannot change its mind. The
  consequence for this side is that when a verdict push is refused for anything transient
  (rate limited, a rejoin mid-push, an internal error) the runner's only correct move is to
  resend the same bytes until they land. That REQUIRES idempotency here rather than on the
  runner, and `triage_verdicts_dispatch_uidx` is where it lives: the first write wins, a
  byte-identical resend finds the row and is answered `ok`, and a resend carrying DIFFERENT
  bytes is refused rather than overwriting.

  Idempotency matters more here than it usually does, because the transition a verdict drives
  is not undoable. A `reject` takes the story `triaged -> failed` on the `:triage_reject`
  edge, which is what earns the reporter a `not_actionable` resolution and CLOSES her ticket
  (`Loopctl.Delivery.Resolution`). A double apply is a second close on a real person's
  support ticket, so "apply exactly once" is a correctness property with an outside effect,
  not bookkeeping.

  ## What is stored, and why the whole payload

  `outcome` and `incomplete_reason` are the two fields control DECIDES on, lifted out so the
  routing reads a column rather than parsing json. The rest of the verdict is kept whole in
  `payload`, because it is the session's reasoning — evidence, contradictions, missing
  information, the drafted story — and an operator reading an escalation needs what the
  session actually said, not the one field that moved the machine.

  `payload_digest` is what makes "the same bytes" checkable without comparing json documents
  whose key order is not stable across encoders. It is a sha256 over the canonical form the
  application computes; a resend whose digest matches is the same verdict.

  ## UNTRUSTED CONTENT, stored as data

  Every string in `payload` was composed by a session whose whole job was to read
  attacker-controllable reporter text, so the drafted story fields in particular are
  potentially shaped by that text. This table RECORDS them. Nothing here executes them, and
  anything that later puts them in a prompt fences them exactly as reporter text is fenced
  (`Loopctl.Delivery.Untrusted`). `jsonb` rather than `text` so the shape is queryable
  without re-parsing, and NOT NULL on the digest so a row can always be compared.

  ## Isolation

  `tenant_id` on every row, RLS ENABLED (not FORCE — the production role owns the table
  without BYPASSRLS), and every read goes through `Repo.with_tenant/2` so the policy applies.

  THERE IS NO FOREIGN KEY ON `dispatch_id` OR `story_id`, deliberately, and an earlier draft
  of this note claimed composite tenant-carrying ones that do not exist — which would have
  left a later reader auditing cross-tenant reachability satisfied by a paragraph instead of
  by the schema. The reason there is none is the same reason `story_id` is denormalised here:
  this row is the record of what triage DECIDED, and it has to outlive the dispatch, which is
  pruned. A reference would either block that pruning or delete the record with it.

  What stands in for the FK is that neither id is ever taken from the wire: `dispatch_id` is
  resolved through `DispatchLedger.accepted_session/3`, which is scoped to the tenant AND the
  runner, and `story_id` is read off that session rather than supplied. A row naming another
  tenant's dispatch cannot be produced by the only path that writes one.
  """

  use Ecto.Migration

  def up do
    create table(:triage_verdicts, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      # The dispatch this verdict answers. It names the story on this side; a story id is
      # never taken from the wire, which is why the envelope does not carry one.
      add :dispatch_id, :binary_id, null: false

      # Denormalised from the dispatch so an operator reading this table does not need a join
      # to know which story a verdict was about, and so the row survives as a record of what
      # was decided even if the dispatch is later pruned.
      add :story_id, :binary_id, null: false

      # EXACTLY ONE of these is set, mirroring the message's own rule. The CHECK below is
      # what keeps that true in the table rather than only in the cast.
      add :outcome, :string
      add :incomplete_reason, :string

      add :confidence, :string

      # The session's whole verdict, or null for an `incomplete` message that carried none.
      add :payload, :map

      # Operator-facing note beside an `incomplete` reason. Bounded on the wire at 300.
      add :detail, :text

      # sha256 over the canonical form of what arrived. "The same bytes" is decided on this,
      # never on comparing two json documents whose key order no encoder guarantees.
      add :payload_digest, :string, null: false

      add :claim_epoch, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # THE IDEMPOTENCY KEY. See the moduledoc: this is what lets a runner resend the same
    # bytes safely, which is its only correct move on a transient refusal.
    create unique_index(:triage_verdicts, [:tenant_id, :dispatch_id],
             name: :triage_verdicts_dispatch_uidx
           )

    # An operator listing what triage decided for a story, newest first.
    create index(:triage_verdicts, [:tenant_id, :story_id])

    create constraint(:triage_verdicts, :triage_verdicts_exactly_one_result,
             check: "(outcome IS NULL) <> (incomplete_reason IS NULL)"
           )

    # A verdict carries a payload and a confidence; an incomplete report carries neither.
    create constraint(:triage_verdicts, :triage_verdicts_verdict_shape,
             check:
               "(outcome IS NULL) = (payload IS NULL) AND (outcome IS NULL) = (confidence IS NULL)"
           )

    execute(
      "ALTER TABLE triage_verdicts ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE triage_verdicts DISABLE ROW LEVEL SECURITY"
    )

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'triage_verdicts' AND policyname = 'tenant_isolation'
      ) THEN
        EXECUTE 'CREATE POLICY tenant_isolation ON triage_verdicts USING (tenant_id = current_tenant_id())';
      END IF;
    END $$;
    """)
  end

  def down do
    execute("DROP POLICY IF EXISTS tenant_isolation ON triage_verdicts")
    drop table(:triage_verdicts)
  end
end
