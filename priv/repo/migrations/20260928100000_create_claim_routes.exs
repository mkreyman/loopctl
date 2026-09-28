defmodule Loopctl.Repo.Migrations.CreateClaimRoutes do
  @moduledoc """
  US-45.9: the ROUTE of an interactive claim.

  A runner placement records its route (mode, base branch, thread branch) on the accepted
  implement row of `runner_dispatches`, and every reader of a claim's route derives it from
  there (`Loopctl.Runners.DispatchLedger.route_rows_query/0`). A claim a session makes itself
  has no such row, so it gets one here, written when the claim is made and never changed: one
  row per claim epoch, which is what the readers key on, so a release needs no cleanup and an
  ended claim's route stays readable for its checkpoints' diffs.
  """

  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def up do
    create table(:claim_routes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false
      add :claim_epoch, :integer, null: false
      add :mode, :string, null: false
      add :base_branch, :string, null: false
      add :branch, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:claim_routes, [:tenant_id, :story_id, :claim_epoch])

    create constraint(:claim_routes, :claim_routes_mode, check: "mode IN ('pr', 'thread')")

    # A thread route names its branch; a pull-request route has none of its own.
    create constraint(:claim_routes, :claim_routes_thread_branch,
             check: "(mode = 'thread') = (branch IS NOT NULL)"
           )

    enable_rls(:claim_routes)
  end

  def down do
    drop table(:claim_routes)
  end
end
