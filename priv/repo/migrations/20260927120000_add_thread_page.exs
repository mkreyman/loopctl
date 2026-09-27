defmodule Loopctl.Repo.Migrations.AddThreadPage do
  @moduledoc """
  US-45.7, the thread page (Epic 45 PRD §6.1).

  1. A HUMAN finding. PRD §6: Mark writes `finding` entries through the thread page as the
     tenant's human principal, and a human finding has the same standing as an agent's. A
     human is not a placed review dispatch, so its finding has no `thread_reviews` row. The
     judgement-shape CHECK required one of every finding; it now admits a finding with no
     review ONLY when its author is `human:webauthn`, the principal the WebAuthn-authenticated
     browser session writes as (`Loopctl.Threads.human_principal/0`). No API key can produce
     that label (`LoopctlWeb.ActorLabel` gives `agent:` or `api_key:`), so the relaxation
     opens nothing to a key.

  2. `thread_issue_links`: the outbox for the comment that links a story's intake issue to its
     thread page (AC-45.7.4). One row per story, written in the transaction that records the
     thread's FIRST checkpoint and drained by `Loopctl.Workers.ThreadIssueLinkWorker` with nothing
     held across the forge call — the shape `intake_issue_closures` has, for the same reasons.
     Threads that already have a checkpoint get their row ONCE, here (`backfill_sql/0`), and
     only while the work is still in flight: a link posted on an issue whose story merged,
     shipped or was abandoned long ago tells its reporter nothing and wakes them for nothing.

  3. `browser_sessions`: the server side of a thread-page login (`Loopctl.WebAuthn.BrowserLogin`).
     The cookie names a row; logout REVOKES it, so a copied cookie stops working at once rather
     than when it expires. Deleting the authenticator that asserted, or the tenant, deletes its
     sessions (`ON DELETE CASCADE`), which is how a revoked authenticator ends a session.

  4. Usernameless login. `webauthn_login_challenges` holds the challenge a login is issued BEFORE
     anyone is identified, so it has no tenant: the assertion's credential id identifies the
     authenticator, and the authenticator the tenant. That makes a credential id a GLOBAL key,
     so it gets a global unique index — without it, a credential id enrolled in two tenants would
     leave a login choosing between them.
  """

  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  @human "human:webauthn"

  def up do
    drop constraint(:thread_entries, :thread_entries_judgement_shape)

    create constraint(:thread_entries, :thread_entries_judgement_shape,
             check: judgement_shape("(review_id IS NOT NULL OR author_principal = '#{@human}')")
           )

    create table(:thread_issue_links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false
      add :repo_full_name, :text, null: false
      add :issue_number, :integer, null: false
      add :status, :text, null: false, default: "pending"
      add :commented_at, :utc_datetime_usec, null: true
      add :attempts, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime_usec, null: true
      add :last_error, :text, null: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:thread_issue_links, [:tenant_id, :story_id],
             name: :thread_issue_links_story_uidx
           )

    create index(:thread_issue_links, [:inserted_at, :id],
             where: "status = 'pending'",
             name: :thread_issue_links_due_idx
           )

    create constraint(:thread_issue_links, :thread_issue_links_status,
             check: "status IN ('pending', 'commented', 'abandoned')"
           )

    create constraint(:thread_issue_links, :thread_issue_links_shape,
             check:
               "(status = 'commented') = (commented_at IS NOT NULL) AND issue_number > 0 AND " <>
                 "attempts >= 0 AND octet_length(repo_full_name) <= 200 AND " <>
                 "(last_error IS NULL OR char_length(last_error) <= 2000)"
           )

    enable_rls(:thread_issue_links)

    create table(:browser_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :authenticator_id,
          references(:tenant_root_authenticators, type: :binary_id, on_delete: :delete_all),
          null: false

      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec, null: true

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:browser_sessions, [:tenant_id, :expires_at])
    create index(:browser_sessions, [:authenticator_id])

    enable_rls(:browser_sessions)

    create unique_index(:tenant_root_authenticators, [:credential_id],
             name: :tenant_root_authenticators_credential_id_uidx
           )

    # Not tenant-scoped, and deliberately without RLS: nothing identifies a tenant until the
    # assertion is verified. Only `AdminRepo` reads or writes it (`Loopctl.WebAuthn.Reauth`).
    create table(:webauthn_login_challenges, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :challenge, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :used_at, :utc_datetime_usec, null: true

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:webauthn_login_challenges, [:expires_at])

    execute(backfill_sql())
  end

  @doc """
  The one-time backfill of `thread_issue_links`: intake stories whose thread already has a
  claimant checkpoint, whose stage is IN FLIGHT, whose source is connected and whose issue is
  not known to be closed. The in-flight stages are `Loopctl.Delivery.StageMachine`'s
  `@in_flight` as of this migration (claimed, worktree, implementing, reviewing, pr_open, ci);
  a migration may not read application code that changes after it. Public so the query is
  tested (`Loopctl.Threads.IssueLinksBackfillTest`).
  """
  def backfill_sql do
    """
    INSERT INTO thread_issue_links
      (id, tenant_id, story_id, repo_full_name, issue_number, status, attempts,
       inserted_at, updated_at)
    SELECT gen_random_uuid(), s.tenant_id, s.id, src.repo_full_name, r.issue_number,
           'pending', 0, now(), now()
    FROM stories s
    JOIN intake_records r ON r.id = s.intake_record_id AND r.tenant_id = s.tenant_id
    JOIN intake_sources src ON src.id = r.source_id AND src.tenant_id = r.tenant_id
    JOIN story_stages st ON st.tenant_id = s.tenant_id AND st.story_id = s.id
    WHERE src.revoked_at IS NULL
      AND r.issue_number > 0
      AND r.issue_state IS DISTINCT FROM 'closed'
      AND st.stage IN ('claimed', 'worktree', 'implementing', 'reviewing', 'pr_open', 'ci')
      AND EXISTS (
        SELECT 1 FROM thread_checkpoints c
        WHERE c.tenant_id = s.tenant_id AND c.story_id = s.id AND c.kind = 'checkpoint'
      )
    ON CONFLICT DO NOTHING
    """
  end

  def down do
    drop table(:webauthn_login_challenges)

    drop index(:tenant_root_authenticators, [:credential_id],
           name: :tenant_root_authenticators_credential_id_uidx
         )

    drop table(:browser_sessions)
    drop table(:thread_issue_links)

    drop constraint(:thread_entries, :thread_entries_judgement_shape)

    create constraint(:thread_entries, :thread_entries_judgement_shape,
             check: judgement_shape("review_id IS NOT NULL")
           )
  end

  defp judgement_shape(finding_origin) do
    """
    CASE kind
      WHEN 'finding' THEN #{finding_origin} AND severity IS NOT NULL
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
  end
end
