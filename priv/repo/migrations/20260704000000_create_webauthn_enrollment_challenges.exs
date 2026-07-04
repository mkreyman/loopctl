defmodule Loopctl.Repo.Migrations.CreateWebauthnEnrollmentChallenges do
  @moduledoc """
  US-26.7.2 — creates `webauthn_enrollment_challenges`.

  Backs the persisted, single-use, TTL-bound WebAuthn REGISTRATION-challenge
  store for the opt-in trust-tier upgrade ceremony
  (`Loopctl.WebAuthn.Enrollment`). Mirrors the `webauthn_reauth_challenges`
  PERSISTENCE SHAPE (see `20260702120000_create_webauthn_reauth_challenges.exs`)
  exactly — same columns, same single-use/TTL semantics — but is a SEPARATE
  table: `Loopctl.WebAuthn.Reauth.issue_challenge/2` hard-requires an existing
  enrolled authenticator (it embeds `allow_credentials`), which would make a
  tenant's FIRST enrollment impossible. This table stores plain registration
  challenges with no such precondition.

  ## Tenant isolation (NOT via RLS here)

  Every query against this table runs on `Loopctl.AdminRepo` (BYPASSRLS), so
  the RLS policy enabled below is NEVER evaluated on the live path — tenant
  isolation rests solely on the explicit `tenant_id` predicates in
  `Loopctl.WebAuthn.Enrollment`. The policy is kept for defense-in-depth /
  future RLS-repo use, mirroring the reauth-challenges table.
  """

  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:webauthn_enrollment_challenges, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id,
          references(:tenants, type: :binary_id, on_delete: :delete_all),
          null: false

      # Ceremony this challenge authorizes — always "enroll_authenticator" today.
      add :purpose, :string, null: false

      # Opaque, adapter-produced REGISTRATION challenge, stored as
      # Erlang-term-binary so it round-trips back to the WebAuthn adapter
      # for verification (bytes + rp_id + origin + timeout).
      add :challenge, :bytea, null: false

      add :expires_at, :utc_datetime_usec, null: false
      add :used_at, :utc_datetime_usec

      # Only `inserted_at` — challenges are immutable except for the
      # single-use `used_at` stamp, so no `updated_at`.
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:webauthn_enrollment_challenges, [:tenant_id])
    create index(:webauthn_enrollment_challenges, [:expires_at])

    enable_rls(:webauthn_enrollment_challenges)
  end
end
