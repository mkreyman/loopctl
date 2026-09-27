defmodule Loopctl.Repo.Migrations.AddThreadPage do
  @moduledoc """
  US-45.7, the thread page (Epic 45 PRD §6.1). Two changes.

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
     thread's FIRST checkpoint, drained by `Loopctl.Workers.ThreadIssueLinkWorker` with
     nothing held across the forge call — the shape `intake_issue_closures` has, for the same
     reasons.
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
  end

  def down do
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
