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

  # Names loopctl gives its OWN per-tenant agents (US-48.11's `system:escalation-digest`, which
  # coordination posts are attributed to). Written only by server code that bypasses these
  # changesets; refused here so no key can register or rename an agent into the namespace and
  # so own the identity a system post is attributed to.
  @reserved_name_prefix "system:"

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
    |> validate_unreserved_name()
    |> validate_metadata()
    |> put_change(:last_seen_at, DateTime.utc_now())
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
    |> validate_unreserved_name()
    |> validate_metadata()
    |> unique_constraint([:tenant_id, :name],
      message: "has already been taken for this tenant"
    )
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

  @doc """
  The agent-name prefix reserved for loopctl's own system agents. `register_changeset/2` and
  `update_changeset/2` refuse a name that starts with it.
  """
  @spec reserved_name_prefix() :: String.t()
  def reserved_name_prefix, do: @reserved_name_prefix

  defp validate_unreserved_name(changeset) do
    validate_change(changeset, :name, fn :name, name ->
      if is_binary(name) and String.starts_with?(String.downcase(name), @reserved_name_prefix),
        do: [name: "must not start with #{inspect(@reserved_name_prefix)}, which is reserved"],
        else: []
    end)
  end

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
