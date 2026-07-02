defmodule Loopctl.Repo.Migrations.CreateWebauthnReauthChallenges do
  @moduledoc """
  crypto-01 (GHSA-c3cw-5f7p-g76r) — creates `webauthn_reauth_challenges`.

  Backs the two-step, challenge-bound WebAuthn reauthentication ceremony
  that gates chain-of-custody-critical operations (currently audit-key
  rotation). The rotate endpoint's challenge-issuance step mints a row
  here whose server-generated `id` IS the opaque handle returned to the
  client; the client echoes it on the assertion step, and the assertion
  is verified against the STORED challenge (never a self-generated one).

  Single-use (`used_at`) and TTL-bounded (`expires_at`), mirroring the
  `knowledge_bulk_delete_tokens` frozen-token pattern.

  ## Tenant isolation (NOT via RLS here)

  Every query against this table runs on `Loopctl.AdminRepo` (BYPASSRLS),
  so the RLS policy enabled below is NEVER evaluated on the live path and
  is not an active backstop — tenant isolation rests solely on the
  explicit `tenant_id` predicates in `Loopctl.WebAuthn.Reauth`. The policy
  is kept for defense-in-depth / future RLS-repo use.
  """

  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:webauthn_reauth_challenges, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id,
          references(:tenants, type: :binary_id, on_delete: :delete_all),
          null: false

      # Ceremony this challenge authorizes, e.g. "rotate_audit_key".
      add :purpose, :string, null: false

      # Opaque, adapter-produced authentication challenge, stored as
      # Erlang-term-binary so it round-trips back to the WebAuthn adapter
      # for verification (bytes + rp_id + origin + timeout).
      add :challenge, :bytea, null: false

      add :expires_at, :utc_datetime_usec, null: false
      add :used_at, :utc_datetime_usec

      # Only `inserted_at` — challenges are immutable except for the
      # single-use `used_at` stamp, so no `updated_at`.
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:webauthn_reauth_challenges, [:tenant_id])
    create index(:webauthn_reauth_challenges, [:expires_at])

    enable_rls(:webauthn_reauth_challenges)
  end
end
