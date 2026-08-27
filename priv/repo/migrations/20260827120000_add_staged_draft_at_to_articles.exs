defmodule Loopctl.Repo.Migrations.AddStagedDraftAtToArticles do
  @moduledoc """
  The DURABLE record that a draft was staged ON PURPOSE, rather than abandoned.

  `POST /api/v1/knowledge` with `draft: true` (or `status: "draft"`) and ingestion with
  `publish: false` are ADVERTISED opt-ins into staging. Nothing recorded that they had
  been taken, so `Loopctl.Knowledge.DraftConsumer` — which drains held drafts nightly —
  could not tell a deliberate stage from a capture nobody ever came back for, and had to
  treat every draft the same: an age floor applied blindly to both.

  A column and not `metadata`, for the `stories.lifecycle_entered_at` reason that
  `previous_title` (20260826120000) reached a second time: `metadata` is cast and
  whole-map-REPLACED by `PATCH /api/v1/knowledge/:id`, so one ordinary agent request
  would erase the opt-in while leaving the draft standing — and silently shorten the very
  hold the caller asked for. The `audit_log` cannot stand in either: it is retention-
  bounded, and drafts outlive `:audit_retention_days`.

  **Never add `:staged_draft_at` to a changeset `cast` list.** A caller that could write
  it could hold its own draft out of the drain indefinitely, and the consumer's whole
  premise is that no state has a human as its only exit. It is set programmatically at
  create time by `Loopctl.Knowledge.create_article/3` under an explicit `:staged_draft`
  option, and by `Loopctl.Workers.ContentIngestionWorker` for an unpublished ingest.

  ## It is a longer FLOOR, never a veto

  The consumer reads this to give a deliberate stage a longer hold than an abandoned
  capture gets — not to exempt it. Owner decision 2026-08-27 (KB `837daaa0`): holding is
  TOTAL LOSS, since no read path serves a draft and no human approver exists or will, so
  a marker that stopped the drain outright would be the loss the drain exists to prevent.

  ## No backfill, and that is the correct outcome

  Nothing recorded the opt-in before this migration, so no existing row can be shown to
  have been staged deliberately. Every pre-existing draft therefore stays unmarked and
  keeps the shorter floor it already had — which is what it has been living under since
  it was created. Guessing from `source_type` or age would mark rows nobody staged.

  Nullable with no default, so the ALTER is catalog-only on PG11+ — no table rewrite.
  """

  use Ecto.Migration

  def up do
    alter table(:articles) do
      add :staged_draft_at, :utc_datetime_usec
    end
  end

  def down do
    alter table(:articles) do
      remove :staged_draft_at
    end
  end
end
