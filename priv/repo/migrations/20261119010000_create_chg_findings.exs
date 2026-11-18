defmodule Loopctl.Repo.Migrations.CreateChgFindings do
  @moduledoc """
  US-51.1: the chg feedback loop's findings and their forge outbox.

  - `chg_findings` — one row per problem the nightly sweep derived from the chg ledger, keyed
    by `(tenant_id, kind, fingerprint)`. A repeat sighting updates the row; it never makes a
    second one, which is what keeps one problem at one GitHub issue. The row carries the
    problem's lifecycle (`queued`, `filed`, `fixed`, `closed`, `escalated`) and the guards
    chg#22 names: `fix_attempts` (two failed fixes, then a person) and `loop_depth` (a
    finding about the loop's own change escalates at depth 2).
  - `chg_finding_actions` — the OUTBOX for every outward act a finding needs (open, close,
    reopen, escalate), drained by `Loopctl.Workers.ChgFindingActionWorker` with nothing held,
    exactly as `change_revert_issues` is. One row per `(finding, action, generation)`, where
    the generation is the finding's `fix_attempts` when the act was decided, so a sweep that
    runs twice decides each act once.

  Two new tables, so the code running before this release is untouched during Fly's rolling
  deploy.
  """

  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def up do
    create table(:chg_findings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :kind, :text, null: false
      add :fingerprint, :text, null: false
      # The repository that owns the fix, `owner/name` as the intake source spells it: where
      # the issue is filed.
      add :repo_full_name, :text, null: false
      add :evidence, :map, null: false, default: %{}

      add :state, :text, null: false, default: "queued"
      add :occurrences, :integer, null: false, default: 1
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false

      add :loop_depth, :integer, null: false, default: 0
      add :fix_attempts, :integer, null: false, default: 0

      add :issue_number, :integer, null: true
      add :filed_at, :utc_datetime_usec, null: true
      add :fix_merge_sha, :text, null: true
      add :fixed_at, :utc_datetime_usec, null: true
      add :closed_at, :utc_datetime_usec, null: true
      add :escalated_at, :utc_datetime_usec, null: true
      add :escalated_reason, :text, null: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:chg_findings, [:tenant_id, :kind, :fingerprint],
             name: :chg_findings_fingerprint_uidx
           )

    # The cap's read (filed today per repository) and the queue's (oldest-first by weight).
    create index(:chg_findings, [:tenant_id, :repo_full_name, :state, :filed_at],
             name: :chg_findings_repo_state_idx
           )

    # The intake exemption (US-51.3) asks: does a finding of this tenant hold this issue?
    create unique_index(:chg_findings, [:tenant_id, :repo_full_name, :issue_number],
             where: "issue_number IS NOT NULL",
             name: :chg_findings_issue_uidx
           )

    create constraint(:chg_findings, :chg_findings_state,
             check: "state IN ('queued', 'filed', 'fixed', 'closed', 'escalated')"
           )

    create constraint(:chg_findings, :chg_findings_counts,
             check:
               "occurrences >= 1 AND loop_depth >= 0 AND fix_attempts >= 0 AND " <>
                 "(issue_number IS NULL OR issue_number > 0)"
           )

    # An escalated finding always says why, and only an escalated one does.
    create constraint(:chg_findings, :chg_findings_escalated_shape,
             check: "(state = 'escalated') = (escalated_reason IS NOT NULL)"
           )

    create constraint(:chg_findings, :chg_findings_text_bounds,
             check:
               "char_length(kind) BETWEEN 1 AND 64 AND " <>
                 "char_length(fingerprint) BETWEEN 1 AND 512 AND " <>
                 "char_length(repo_full_name) BETWEEN 3 AND 200 AND " <>
                 "(fix_merge_sha IS NULL OR fix_merge_sha ~ '^[0-9a-f]{40}([0-9a-f]{24})?$') AND " <>
                 "(escalated_reason IS NULL OR char_length(escalated_reason) <= 500) AND " <>
                 "octet_length(evidence::text) <= 32768"
           )

    enable_rls(:chg_findings)

    create table(:chg_finding_actions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :finding_id, references(:chg_findings, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source_id, references(:intake_sources, type: :binary_id, on_delete: :delete_all),
        null: false

      add :action, :text, null: false
      add :generation, :integer, null: false

      add :repo_full_name, :text, null: false
      add :title, :text, null: true
      add :body, :text, null: true
      # The issue a close, reopen or escalate acts on; for an open, the issue it opened.
      add :issue_number, :integer, null: true

      add :status, :text, null: false, default: "pending"
      add :done_at, :utc_datetime_usec, null: true
      add :attempts, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime_usec, null: true
      add :last_error, :text, null: true
      add :abandoned_reason, :text, null: true

      timestamps(type: :utc_datetime_usec)
    end

    # THE at-most-once guarantee: one act per finding, action and generation.
    create unique_index(:chg_finding_actions, [:finding_id, :action, :generation],
             name: :chg_finding_actions_once_uidx
           )

    create index(:chg_finding_actions, [:inserted_at, :id],
             where: "status = 'pending'",
             name: :chg_finding_actions_due_idx
           )

    create index(:chg_finding_actions, [:tenant_id, :finding_id],
             name: :chg_finding_actions_finding_idx
           )

    create constraint(:chg_finding_actions, :chg_finding_actions_action,
             check: "action IN ('open', 'close', 'reopen', 'escalate')"
           )

    create constraint(:chg_finding_actions, :chg_finding_actions_status,
             check: "status IN ('pending', 'done', 'abandoned')"
           )

    # An open carries its text; every other act names the issue it acts on.
    create constraint(:chg_finding_actions, :chg_finding_actions_shape,
             check:
               "(action = 'open') = (title IS NOT NULL) AND " <>
                 "(action <> 'open' OR body IS NOT NULL) AND " <>
                 "(action = 'open' OR issue_number IS NOT NULL) AND " <>
                 "(status = 'done') = (done_at IS NOT NULL) AND " <>
                 "(status = 'abandoned') = (abandoned_reason IS NOT NULL) AND " <>
                 "(action <> 'open' OR status <> 'done' OR issue_number IS NOT NULL)"
           )

    create constraint(:chg_finding_actions, :chg_finding_actions_counts,
             check:
               "attempts >= 0 AND generation >= 0 AND (issue_number IS NULL OR issue_number > 0)"
           )

    create constraint(:chg_finding_actions, :chg_finding_actions_text_bounds,
             check:
               "char_length(repo_full_name) BETWEEN 3 AND 200 AND " <>
                 "(title IS NULL OR char_length(title) BETWEEN 1 AND 256) AND " <>
                 "(body IS NULL OR octet_length(body) BETWEEN 1 AND 65536) AND " <>
                 "(last_error IS NULL OR char_length(last_error) <= 2000) AND " <>
                 "(abandoned_reason IS NULL OR char_length(abandoned_reason) <= 2000)"
           )

    enable_rls(:chg_finding_actions)
  end

  def down do
    drop table(:chg_finding_actions)
    drop table(:chg_findings)
  end
end
