defmodule Loopctl.Repo.Migrations.AddRecorderProvenanceToConflictResolutions do
  use Ecto.Migration

  @moduledoc """
  Records WHO recorded a conflict verdict, so the nightly executor can decide
  whether that verdict may retire an article unattended.

  `confidence` was previously taken verbatim from request params, and the nightly
  executor applies `:supersede` at `confidence == :high` with no human in the loop.
  The recorded confidence is now the trust the SERVER grants a verdict rather than
  the trust its author claims, and that decision needs the author's role to be a
  persisted fact rather than a value recomputed at read time:

    * `annotated_by_role` — the role of the key that recorded the verdict, derived
      server-side. The executor applies a `:supersede` only when its recorder may
      authorize an unattended retirement.
    * `requested_confidence` — what the caller asked for, kept when the grant was
      lower, so a capped verdict is auditable rather than silently rewritten.

  `annotated_by_role` is BACKFILLED for existing rows. `annotated_by` has carried
  `"<role>:<name>"` since `LoopctlWeb.AuditContext.from_conn/1`, so the recorder of
  a pre-migration verdict is mechanically recoverable — reading it is what keeps a
  pending `:supersede` an orchestrator actually recorded from being treated as
  unattributed. Bounded to the four known roles; anything else stays NULL.

  A row left NULL is not an authorization, so its `:supersede` is not applied. It is
  not dismissed either: `Knowledge.conflict_unresolved_subquery/0` settles a pair
  only on a verdict the executor will act on, so such a pair stays in
  `GET /knowledge/conflicts` for an orchestrator+ key to re-record.

  This migration was renumbered from `20260807120000` while the branch was unmerged, so a
  database that migrated the earlier version already carries both columns and has no record
  of THIS version — a plain `add` would run again and raise `duplicate_column`.
  `add_if_not_exists` converges those boxes here instead, the same way
  `20260807140000_add_consumed_at_to_custody_violations` does. The backfill is idempotent
  (it only rewrites `annotated_by_role` from a value already on the row).
  """

  def change do
    alter table(:conflict_resolutions) do
      add_if_not_exists :annotated_by_role, :string
      add_if_not_exists :requested_confidence, :string
    end

    execute(
      """
      UPDATE conflict_resolutions
         SET annotated_by_role = split_part(annotated_by, ':', 1)
       WHERE annotated_by IS NOT NULL
         AND split_part(annotated_by, ':', 1)
             IN ('superadmin', 'user', 'orchestrator', 'agent')
      """,
      "SELECT 1"
    )
  end
end
