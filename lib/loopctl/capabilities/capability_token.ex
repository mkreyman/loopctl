defmodule Loopctl.Capabilities.CapabilityToken do
  @moduledoc """
  Schema for the `capability_tokens` table.

  Signed, scoped, non-replayable tokens that gate custody-critical operations.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @types ~w(start_cap report_cap verify_cap review_complete_cap)

  schema "capability_tokens" do
    field :tenant_id, Ecto.UUID
    field :typ, :string
    field :story_id, Ecto.UUID
    field :issued_to_lineage, {:array, Ecto.UUID}, default: []
    field :issued_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :nonce, :binary
    field :signature, :binary
  end

  @doc false
  def changeset(token \\ %__MODULE__{}, attrs) do
    token
    |> cast(attrs, [
      :typ,
      :story_id,
      :issued_to_lineage,
      :issued_at,
      :expires_at,
      :consumed_at,
      :nonce,
      :signature
    ])
    |> validate_required([:typ, :issued_to_lineage, :issued_at, :expires_at, :nonce, :signature])
    |> validate_inclusion(:typ, @types)
    |> unique_constraint([:tenant_id, :nonce], name: :capability_tokens_tenant_id_nonce_index)
  end

  def types, do: @types
end
