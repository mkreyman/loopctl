defmodule Loopctl.Repo.Migrations.CreateRunners do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  # Issue #801: the machine registry behind the runner channel.
  #
  # A runner is a dev machine that connects OUTBOUND to loopctl over an authenticated
  # Phoenix Channel. Its credential is an ordinary `api_keys` row, so resolution,
  # the revocation cache and tenant suspension all go through `Auth.verify_api_key/1`
  # exactly as a REST request does. This table binds that key to ONE machine name:
  # a key that has no row here cannot open the runner socket, and a runner cannot join
  # under a machine name other than the one it was enrolled as.
  #
  # Liveness is NOT stored here. Presence carries it and dies with the socket, so
  # there is no `last_seen_at` column to go stale and nothing to sweep.
  #
  # The name is unique among ACTIVE runners only, so a revoked machine can be
  # re-enrolled under the same name with a fresh key.
  def change do
    create table(:runners, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :text, null: false
      add :revoked_at, :utc_datetime_usec, null: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:runners, [:api_key_id], name: :runners_api_key_uidx)

    create unique_index(:runners, [:tenant_id, :name],
             where: "revoked_at IS NULL",
             name: :runners_active_name_uidx
           )

    create constraint(:runners, :runners_name_shape,
             check: "name ~ '^[a-z0-9][a-z0-9._-]{0,62}$'"
           )

    enable_rls(:runners)
  end
end
