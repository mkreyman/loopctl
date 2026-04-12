defmodule Loopctl.Dispatches.Dispatch do
  @moduledoc """
  Schema for the `dispatches` table.

  Each dispatch represents a scoped task assignment: an orchestrator
  or operator dispatching a sub-agent to work in a specific role,
  optionally on a specific story, with an ephemeral API key.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @roles [:agent, :orchestrator, :user]

  schema "dispatches" do
    field :tenant_id, Ecto.UUID
    field :parent_dispatch_id, Ecto.UUID
    field :api_key_id, Ecto.UUID
    field :agent_id, Ecto.UUID
    field :story_id, Ecto.UUID
    field :role, Ecto.Enum, values: @roles
    field :lineage_path, {:array, Ecto.UUID}, default: []
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
  end

  @doc false
  def changeset(dispatch \\ %__MODULE__{}, attrs) do
    dispatch
    |> cast(attrs, [
      :parent_dispatch_id,
      :api_key_id,
      :agent_id,
      :story_id,
      :role,
      :lineage_path,
      :expires_at,
      :revoked_at,
      :created_at
    ])
    |> validate_required([:role, :lineage_path, :expires_at])
    |> validate_inclusion(:role, @roles)
    |> foreign_key_constraint(:parent_dispatch_id)
    |> foreign_key_constraint(:api_key_id)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:story_id)
  end
end
