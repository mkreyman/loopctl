defmodule Loopctl.Repo.Migrations.AddChgFindingCycle do
  @moduledoc """
  US-51.6: a person may clear an escalated finding back to `queued` (`Findings.clear/3`), which
  resets its fix attempts so the loop tries again. An action's `generation` is the fix-attempt
  count, so after a clear the next `open`, `reopen` or `escalate` would repeat a generation
  already used and `ON CONFLICT DO NOTHING` would drop it silently: a finding marked filed with
  no issue behind it. `cycle` counts the clears; it is part of the once-per-act key, so every
  cycle acts afresh.
  """

  use Ecto.Migration

  def change do
    alter table(:chg_findings) do
      add :cycle, :integer, null: false, default: 0
    end

    alter table(:chg_finding_actions) do
      add :cycle, :integer, null: false, default: 0
    end

    create constraint(:chg_findings, :chg_findings_cycle, check: "cycle >= 0")
    create constraint(:chg_finding_actions, :chg_finding_actions_cycle, check: "cycle >= 0")

    drop unique_index(:chg_finding_actions, [:finding_id, :action, :generation],
           name: :chg_finding_actions_once_uidx
         )

    create unique_index(:chg_finding_actions, [:finding_id, :cycle, :action, :generation],
             name: :chg_finding_actions_once_uidx
           )
  end
end
