defmodule Loopctl.Repo.Migrations.AddStatusCheckConstraintsToStories do
  use Ecto.Migration

  def change do
    create constraint(:stories, :stories_agent_status_check,
             check:
               "agent_status IN ('pending', 'contracted', 'assigned', 'implementing', 'reported_done')"
           )

    create constraint(:stories, :stories_verified_status_check,
             check: "verified_status IN ('unverified', 'verified', 'rejected')"
           )
  end
end
