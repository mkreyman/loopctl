defmodule Loopctl.Repo.Migrations.CreateTenantRootAuthenticators do
  @moduledoc """
  US-26.0.1 — creates the `tenant_root_authenticators` table.

  Stores the FIDO2 credential records minted during the signup ceremony.
  Each row is a human-touched authenticator that anchors the tenant's
  chain of custody (per `docs/chain-of-custody-v2.md` section 9).

  RLS: tenant-scoped isolation policy via the shared RLS helper.
  """

  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:tenant_root_authenticators, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id,
          references(:tenants, type: :binary_id, on_delete: :delete_all),
          null: false

      # FIDO2 credential ID — raw bytes as returned by the browser.
      add :credential_id, :bytea, null: false

      # COSE-encoded public key — stored as Erlang-term-binary for
      # round-trip verification by the WebAuthn adapter.
      add :public_key, :bytea, null: false

      # Attestation format: "packed", "fido-u2f", "none", "apple", "tpm", ...
      add :attestation_format, :string, null: false

      # Signature counter for clone detection on subsequent assertions.
      add :sign_count, :integer, null: false, default: 0

      # Human-readable label — defaults to something like "Primary YubiKey".
      add :friendly_name, :string, null: false

      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tenant_root_authenticators, [:tenant_id, :credential_id])
    create index(:tenant_root_authenticators, [:tenant_id])

    enable_rls(:tenant_root_authenticators)
  end
end
