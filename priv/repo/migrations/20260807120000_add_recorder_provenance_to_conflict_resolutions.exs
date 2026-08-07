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
      server-side. The executor applies only verdicts recorded by a role that is
      allowed to authorize an unattended retirement.
    * `requested_confidence` — what the caller asked for, kept when the grant was
      lower, so a capped verdict is auditable rather than silently rewritten.

  Both are nullable: rows written before this migration carry no recorder
  provenance, and an unknown recorder is not an authorized one — those rows are
  closed as dismissed by the executor's unexecutable sweep (both articles retained)
  instead of being applied on an authorization nobody can evidence.
  """

  def change do
    alter table(:conflict_resolutions) do
      add :annotated_by_role, :string
      add :requested_confidence, :string
    end
  end
end
