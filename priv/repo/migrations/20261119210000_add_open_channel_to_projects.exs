defmodule Loopctl.Repo.Migrations.AddOpenChannelToProjects do
  @moduledoc """
  US-52.3: a kb scope promoted to a work project (by an intake enrolment or a merge) keeps
  the any-agent channel writes it had as a kb scope (issue #517). `open_channel` records the
  promotion; `Coordination.project_writable_by_agent/4` reads it. No row is promoted before
  this release, so every existing row starts false.
  """
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :open_channel, :boolean, null: false, default: false
    end
  end
end
