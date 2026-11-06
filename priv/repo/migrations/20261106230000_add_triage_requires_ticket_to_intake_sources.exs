defmodule Loopctl.Repo.Migrations.AddTriageRequiresTicketToIntakeSources do
  @moduledoc """
  `intake_sources.triage_requires_ticket`: when true, only issues whose intake record carries a
  `ticket_ref` (an issue HomeCareBilling filed from a support ticket) are sent to triage. False
  keeps every existing source triaging everything, as before.

  NOT NULL with a constant default: on PostgreSQL 11+ that is a catalog-only change, so it
  rewrites nothing and takes only a brief ACCESS EXCLUSIVE lock on a small table.
  """
  use Ecto.Migration

  def change do
    alter table(:intake_sources) do
      add :triage_requires_ticket, :boolean, null: false, default: false
    end
  end
end
