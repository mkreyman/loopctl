defmodule Loopctl.AuditChain.SignedTreeHead do
  @moduledoc """
  Schema for the `audit_signed_tree_heads` table.

  Each STH is a signed commitment of a tenant's audit chain state:
  the chain position, merkle root of all entry hashes, and an ed25519
  signature from the tenant's audit signing key.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "audit_signed_tree_heads" do
    field :tenant_id, Ecto.UUID
    field :chain_position, :integer
    field :merkle_root, :binary
    field :signed_at, :utc_datetime_usec
    field :signature, :binary
  end

  @doc false
  def changeset(sth \\ %__MODULE__{}, attrs) do
    sth
    |> cast(attrs, [:chain_position, :merkle_root, :signed_at, :signature])
    |> validate_required([:chain_position, :merkle_root, :signed_at, :signature])
  end
end
