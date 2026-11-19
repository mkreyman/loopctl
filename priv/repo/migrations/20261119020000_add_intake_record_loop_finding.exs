defmodule Loopctl.Repo.Migrations.AddIntakeRecordLoopFinding do
  @moduledoc """
  US-51.3: `intake_records.loop_finding_id` — the chg finding whose loop issue this record
  is, set when the record is promoted on a `triage_requires_ticket` source by the lookup in
  `Loopctl.Changes.Findings.loop_finding_for/1`. Never from anything in the issue.

  A nullable column with no default, so the code running before this release ignores it
  during Fly's rolling deploy. A finding deleted with its tenant takes the mark with it.
  """

  use Ecto.Migration

  def change do
    alter table(:intake_records) do
      add :loop_finding_id,
          references(:chg_findings, type: :binary_id, on_delete: :nilify_all),
          null: true
    end
  end
end
