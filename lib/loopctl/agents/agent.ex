defmodule Loopctl.Agents.Agent do
  @moduledoc """
  Schema for the `agents` table.

  Agents are AI coding agents that register with a tenant to perform
  work (implement stories, run orchestration, etc.). Each agent has a
  type (orchestrator or implementer) and a status lifecycle.

  ## Fields

  - `name` -- unique identifier within a tenant ("worker-1", "orchestrator-main")
  - `agent_type` -- `:orchestrator` or `:implementer`
  - `status` -- `:active`, `:idle`, or `:deactivated`
  - `last_seen_at` -- updated on every authenticated API call
  - `metadata` -- JSONB map for agent capabilities and configuration
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @agent_types [:orchestrator, :implementer]
  @statuses [:active, :idle, :deactivated]

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :name,
             :agent_type,
             :status,
             :last_seen_at,
             :metadata,
             :inserted_at,
             :updated_at
           ]}

  schema "agents" do
    tenant_field()
    field :name, :string
    field :agent_type, Ecto.Enum, values: @agent_types
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :last_seen_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc """
  Changeset for registering a new agent.

  The `tenant_id` is set programmatically, not via cast.
  """
  @spec register_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def register_changeset(agent \\ %__MODULE__{}, attrs) do
    agent
    |> cast(attrs, [:name, :agent_type, :metadata])
    |> validate_required([:name, :agent_type])
    |> validate_inclusion(:agent_type, @agent_types)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_metadata()
    |> unique_constraint([:tenant_id, :name],
      message: "has already been taken for this tenant"
    )
  end

  @doc """
  Changeset for updating an existing agent.
  """
  @spec update_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def update_changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name, :status, :metadata])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_metadata()
    |> unique_constraint([:tenant_id, :name],
      message: "has already been taken for this tenant"
    )
  end

  @doc """
  Changeset for updating last_seen_at timestamp.
  """
  @spec touch_changeset(%__MODULE__{}, DateTime.t()) :: Ecto.Changeset.t()
  def touch_changeset(agent, now) do
    change(agent, last_seen_at: now)
  end

  @doc """
  Returns the list of valid agent types.
  """
  @spec agent_types() :: [atom()]
  def agent_types, do: @agent_types

  @doc """
  Returns the list of valid statuses.
  """
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  defp validate_metadata(changeset) do
    validate_change(changeset, :metadata, fn :metadata, value ->
      if is_map(value) and not is_struct(value) do
        []
      else
        [metadata: "must be a map"]
      end
    end)
  end
end
