defmodule Loopctl.Repo.Migrations.CreateOperatorLogin do
  @moduledoc """
  US-50.5: the operator's browser login, restored from the Epic 45 thread-page login that
  `20261019120000_drop_change_thread_tables` dropped with its page.

  1. `browser_sessions`: the server side of a login (`Loopctl.WebAuthn.BrowserLogin`). The
     cookie carries only this row's id and tenant; the row says when the session ends and
     whether it was logged out. Deleting the asserting authenticator or the tenant deletes it.
  2. `webauthn_login_challenges`: the challenge a usernameless login is issued BEFORE anyone is
     identified, so it is bound to no tenant and has no RLS. Only `AdminRepo` touches it
     (`Loopctl.WebAuthn.Reauth`).

  `tenant_root_authenticators_credential_id_uidx`, which a usernameless login identifies its
  authenticator by, survived the drop and is not recreated. New tables only, so the release
  before this one keeps working during Fly's rolling deploy.
  """

  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def up do
    create table(:browser_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :authenticator_id,
          references(:tenant_root_authenticators, type: :binary_id, on_delete: :delete_all),
          null: false

      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec, null: true

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:browser_sessions, [:tenant_id, :expires_at])
    create index(:browser_sessions, [:authenticator_id])

    enable_rls(:browser_sessions)

    create table(:webauthn_login_challenges, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :challenge, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :used_at, :utc_datetime_usec, null: true

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:webauthn_login_challenges, [:expires_at])
  end

  def down do
    drop table(:webauthn_login_challenges)
    drop table(:browser_sessions)
  end
end
