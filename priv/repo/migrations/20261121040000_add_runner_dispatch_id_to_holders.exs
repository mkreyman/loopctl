defmodule Loopctl.Repo.Migrations.AddRunnerDispatchIdToHolders do
  @moduledoc """
  US-52.15: a runner session's holder records the WIRE dispatch id, the one the runner's
  accept and `session_ended` name, beside `dispatch_id` (the `dispatches` row minted for the
  session, which verify and revoke read). The two are different ids: the wire id is the
  placement's, and the row is minted for it.

  No backfill and no manual step: no runner-session holder exists before this release.
  """

  use Ecto.Migration

  def change do
    alter table(:holders) do
      add :runner_dispatch_id, :binary_id
    end

    create index(:holders, [:tenant_id, :runner_dispatch_id],
             where: "runner_dispatch_id IS NOT NULL"
           )
  end
end
