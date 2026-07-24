defmodule Loopctl.Tenants.CustodyOwnerKeyHistory do
  @moduledoc """
  LCP-1 §9.2 — historical (rotated-out) owner public keys for a tenant.

  When a tenant rotates its owner key, the retiring key is archived here with its
  `[rotated_in, rotated_out)` validity window so that ROOT dispatch attestations
  signed under the old key remain re-verifiable offline. The analogue of
  `Loopctl.Tenants.AuditKeyHistory`, but for the owner (root-of-trust) key whose
  private half is held by the OWNER, never the server.
  """

  use Loopctl.Schema

  schema "tenant_custody_owner_key_history" do
    field :tenant_id, Ecto.UUID
    field :public_key, :binary
    field :alg, :string
    field :rotated_in, :utc_datetime_usec
    field :rotated_out, :utc_datetime_usec

    timestamps()
  end

  @doc false
  def changeset(entry \\ %__MODULE__{}, attrs) do
    entry
    |> cast(attrs, [:public_key, :alg, :rotated_in, :rotated_out])
    |> validate_required([:public_key, :alg, :rotated_in, :rotated_out])
    |> validate_inclusion(:alg, ["ed25519"])
  end
end
