defmodule Loopctl.Tenants.RootAuthenticator do
  @moduledoc """
  Schema for the `tenant_root_authenticators` table.

  One row per FIDO2 credential enrolled during the tenant signup
  ceremony (US-26.0.1). See `docs/chain-of-custody-v2.md` section 9 for
  the human-touch root-of-trust model this anchors.

  ## Fields

  - `tenant_id` — owning tenant (programmatically set, never in cast)
  - `credential_id` — raw FIDO2 credential id (bytea)
  - `public_key` — Erlang-term-binary encoded COSE public key (bytea)
  - `attestation_format` — attestation format string from the attestation
    statement (`"packed"`, `"none"`, `"apple"`, etc.)
  - `sign_count` — monotonic signature counter for clone detection
  - `friendly_name` — operator-supplied display label
  - `last_used_at` — timestamp of the last successful assertion
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "tenant_root_authenticators" do
    tenant_field()

    field :credential_id, :binary
    field :public_key, :binary
    field :attestation_format, :string
    field :sign_count, :integer, default: 0
    field :friendly_name, :string
    field :last_used_at, :utc_datetime_usec

    timestamps()
  end

  @cast_fields [
    :credential_id,
    :public_key,
    :attestation_format,
    :sign_count,
    :friendly_name,
    :last_used_at
  ]

  @doc """
  Builds a create changeset. `tenant_id` must be set on the struct
  before calling — it is never cast from user input.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(auth \\ %__MODULE__{}, attrs) do
    auth
    |> cast(attrs, @cast_fields)
    |> validate_required([
      :credential_id,
      :public_key,
      :attestation_format,
      :friendly_name
    ])
    |> validate_length(:friendly_name, min: 1, max: 120)
    |> validate_length(:attestation_format, min: 1, max: 32)
    |> validate_number(:sign_count, greater_than_or_equal_to: 0)
    |> unique_constraint(:credential_id,
      name: :tenant_root_authenticators_tenant_id_credential_id_index
    )
  end

  @doc """
  Changeset for bumping the sign counter after a successful assertion.
  """
  @spec touch_changeset(t(), non_neg_integer()) :: Ecto.Changeset.t()
  def touch_changeset(authenticator, new_sign_count)
      when is_integer(new_sign_count) and new_sign_count >= 0 do
    change(authenticator, sign_count: new_sign_count, last_used_at: DateTime.utc_now())
  end
end
