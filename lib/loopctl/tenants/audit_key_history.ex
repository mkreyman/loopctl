defmodule Loopctl.Tenants.AuditKeyHistory do
  @moduledoc """
  Tracks historical audit signing public keys for a tenant.

  When a tenant rotates their audit key, the old public key is stored
  here so that historical STHs and capability tokens signed under the
  old key remain verifiable.
  """

  use Loopctl.Schema

  schema "tenant_audit_key_history" do
    field :tenant_id, Ecto.UUID
    field :public_key, :binary
    field :rotated_in, :utc_datetime_usec
    field :rotated_out, :utc_datetime_usec
    field :rotation_signature, :binary

    timestamps()
  end

  @doc false
  def changeset(entry \\ %__MODULE__{}, attrs) do
    entry
    |> cast(attrs, [:public_key, :rotated_in, :rotated_out, :rotation_signature])
    |> validate_required([:public_key, :rotated_in])
  end
end
