defmodule Loopctl.WebAuthn.EnrollmentChallenge do
  @moduledoc """
  Schema for the `webauthn_enrollment_challenges` table (US-26.7.2).

  Mirrors `Loopctl.WebAuthn.ReauthChallenge`'s persistence SHAPE exactly (a
  persisted, single-use, TTL-bound challenge handle: mint, hand the `id` to
  the client, refuse if missing/expired/used, atomically stamp `used_at`)
  but is a SEPARATE table and schema. `Reauth.issue_challenge/2` requires
  >=1 enrolled authenticator (it embeds `allow_credentials`), which makes it
  unusable for a tenant's FIRST enrollment (zero authenticators). This table
  stores plain REGISTRATION challenges (`Wax.new_registration_challenge`),
  not authentication/reauth challenges, so it carries no
  `allow_credentials` semantics at all.

  ## Tenant isolation (NOT via RLS here)

  Every query runs on `Loopctl.AdminRepo` (BYPASSRLS), so the table's RLS
  policy is never evaluated on this path. Isolation rests solely on the
  explicit `tenant_id` predicates in `Loopctl.WebAuthn.Enrollment`.

  ## Fields

  - `id`         -- binary UUID primary key; the opaque challenge handle
  - `tenant_id`  -- FK to tenants (set programmatically, never cast)
  - `purpose`    -- ceremony label, always `"enroll_authenticator"` today
  - `challenge`  -- Erlang-term-binary encoded adapter registration challenge
  - `expires_at` -- TTL boundary; a challenge past this is refused
  - `used_at`    -- single-use stamp; non-nil ⇒ already consumed, refused
  - `inserted_at`-- creation timestamp (no `updated_at`)
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "webauthn_enrollment_challenges" do
    tenant_field()

    field :purpose, :string
    field :challenge, :binary
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end

  @cast_fields [:purpose, :challenge, :expires_at]

  @doc """
  Changeset for minting a new enrollment registration challenge.

  `tenant_id` is set programmatically and must not appear in attrs.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(challenge \\ %__MODULE__{}, attrs) do
    challenge
    |> cast(attrs, @cast_fields)
    |> validate_required([:purpose, :challenge, :expires_at])
  end
end
