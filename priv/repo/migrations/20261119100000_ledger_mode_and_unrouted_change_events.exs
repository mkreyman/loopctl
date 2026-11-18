defmodule Loopctl.Repo.Migrations.LedgerModeAndUnroutedChangeEvents do
  @moduledoc """
  Issue #1047: a repository may SEND chg ledger rows and change events without the change
  protocol being its merge route.

  - `intake_sources_mode` widens to `('pr', 'chg', 'ledger')`. `ledger` is the mode of a source
    on a `:kb` scope: it authenticates the chg ledger and change events and nothing else. It is
    never a dispatch binding, never a merge route and never receives a GitHub delivery
    (`Loopctl.Intake`).
  - `intake_sources_chg_requires_credentials` now covers `ledger` too: a `ledger` source that no
    signed request could authenticate to would be a row with no purpose.
  - `change_events.routed`: whether the event was applied under a `chg` source, so its stage
    and custody effects ran. An event a `pr` or `ledger` source delivers is stored, ordered and
    audited like any other, but it moves nothing and is evidence for no gate
    (`Loopctl.Changes.Events`). NOT NULL DEFAULT true, which is what every existing row is:
    until now only a `chg` source could deliver one. A constant default is a catalog-only
    change on PostgreSQL 11+, so the table is not rewritten.

  No new table, so no RLS change: both tables already ENABLE ROW LEVEL SECURITY.
  """

  use Ecto.Migration

  def up do
    drop constraint(:intake_sources, :intake_sources_mode)

    create constraint(:intake_sources, :intake_sources_mode,
             check: "mode IN ('pr', 'chg', 'ledger')"
           )

    drop constraint(:intake_sources, :intake_sources_chg_requires_credentials)

    create constraint(:intake_sources, :intake_sources_chg_requires_credentials,
             check:
               "mode NOT IN ('chg', 'ledger') OR " <>
                 "(change_events_secret IS NOT NULL AND chg_root_dispatch_id IS NOT NULL)"
           )

    alter table(:change_events) do
      add :routed, :boolean, null: false, default: true
    end
  end

  def down do
    alter table(:change_events) do
      remove :routed
    end

    # A `ledger` source has no meaning once the mode is gone, and it can never be `pr`: it sits on
    # a `:kb` scope, which no dispatch or merge route may bind. Revoked rather than converted.
    execute(
      "UPDATE intake_sources SET revoked_at = now() WHERE mode = 'ledger' AND revoked_at IS NULL"
    )

    execute("UPDATE intake_sources SET mode = 'pr' WHERE mode = 'ledger'")

    drop constraint(:intake_sources, :intake_sources_chg_requires_credentials)

    create constraint(:intake_sources, :intake_sources_chg_requires_credentials,
             check:
               "mode <> 'chg' OR " <>
                 "(change_events_secret IS NOT NULL AND chg_root_dispatch_id IS NOT NULL)"
           )

    drop constraint(:intake_sources, :intake_sources_mode)
    create constraint(:intake_sources, :intake_sources_mode, check: "mode IN ('pr', 'chg')")
  end
end
