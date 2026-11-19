defmodule Loopctl.Repo.Migrations.AddDismissalToChgFindings do
  @moduledoc """
  #1064: a person may dismiss a chg finding filed in error (`Loopctl.Changes.Findings.dismiss/4`).
  Two nullable columns on `chg_findings`, set together and only on a closed finding, so a
  dismissal says when and why, and a later sighting never reopens it as a recurrence.

  Additive and nullable: the code running before this release reads neither column.
  """

  use Ecto.Migration

  def change do
    alter table(:chg_findings) do
      add :dismissed_at, :utc_datetime_usec, null: true
      add :dismissed_reason, :text, null: true
    end

    create constraint(:chg_findings, :chg_findings_dismissed_shape,
             check:
               "(dismissed_at IS NULL) = (dismissed_reason IS NULL) AND " <>
                 "(dismissed_at IS NULL OR state = 'closed') AND " <>
                 "(dismissed_reason IS NULL OR char_length(dismissed_reason) BETWEEN 1 AND 500)"
           )
  end
end
