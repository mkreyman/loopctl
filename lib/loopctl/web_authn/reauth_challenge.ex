defmodule Loopctl.WebAuthn.ReauthChallenge do
  @moduledoc """
  Schema for the `webauthn_reauth_challenges` table (crypto-01,
  GHSA-c3cw-5f7p-g76r).

  A reauth challenge is the server-minted, single-use, TTL-bounded handle
  that makes WebAuthn reauthentication (currently audit-key rotation)
  challenge-bound. The challenge-issuance step generates an authentication
  challenge via the configured `Loopctl.WebAuthn.Behaviour` adapter,
  serializes it into `challenge`, and returns the row `id` to the client.
  The assertion step loads the row by `(id AND tenant_id AND purpose)`,
  refuses it if missing/expired/used, atomically stamps `used_at`
  (single-use), and verifies the client's assertion against the STORED
  challenge — never a freshly generated one.

  ## Tenant isolation (NOT via RLS here)

  Every query runs on `Loopctl.AdminRepo` (BYPASSRLS), so the table's RLS
  policy is never evaluated on this path. Isolation rests solely on the
  explicit `tenant_id` predicates in `Loopctl.WebAuthn.Reauth`.

  ## Fields

  - `id`         -- binary UUID primary key; the opaque challenge handle
  - `tenant_id`  -- FK to tenants (set programmatically, never cast)
  - `purpose`    -- ceremony label, e.g. `"rotate_audit_key"`
  - `challenge`  -- Erlang-term-binary encoded adapter challenge
  - `expires_at` -- TTL boundary; a challenge past this is refused
  - `used_at`    -- single-use stamp; non-nil ⇒ already consumed, refused
  - `inserted_at`-- creation timestamp (no `updated_at`)
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "webauthn_reauth_challenges" do
    tenant_field()

    field :purpose, :string
    field :challenge, :binary
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end

  @cast_fields [:purpose, :challenge, :expires_at]

  @doc """
  Changeset for minting a new reauth challenge.

  `tenant_id` is set programmatically and must not appear in attrs.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(challenge \\ %__MODULE__{}, attrs) do
    challenge
    |> cast(attrs, @cast_fields)
    |> validate_required([:purpose, :challenge, :expires_at])
  end
end
