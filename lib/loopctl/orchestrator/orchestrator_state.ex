defmodule Loopctl.Orchestrator.OrchestratorState do
  @moduledoc """
  Schema for the `orchestrator_states` table.

  Represents a named state checkpoint for an AI orchestrator session.
  Each state is scoped by `(tenant_id, project_id, state_key)` and uses
  an integer `version` field for optimistic locking.

  ## Fields

  - `state_key` -- namespaced key (e.g., "main", "backup", "experiment-1")
  - `state_data` -- arbitrary JSONB map of orchestrator state
  - `version` -- integer version for optimistic locking, increments on each save
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :project_id,
             :state_key,
             :state_data,
             :version,
             :inserted_at,
             :updated_at
           ]}

  schema "orchestrator_states" do
    tenant_field()
    belongs_to :project, Loopctl.Projects.Project, type: :binary_id
    field :state_key, :string
    field :state_data, :map, default: %{}
    field :version, :integer, default: 1

    timestamps()
  end

  @doc """
  Changeset for creating a new orchestrator state record.

  The `tenant_id` and `project_id` are set programmatically, not via cast.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(state \\ %__MODULE__{}, attrs) do
    state
    |> cast(attrs, [:state_key, :state_data])
    |> validate_required([:state_key, :state_data])
    |> validate_length(:state_key, min: 1, max: 255)
    |> validate_state_data()
    |> put_change(:version, 1)
    |> unique_constraint([:tenant_id, :project_id, :state_key],
      message: "state already exists for this project and key"
    )
  end

  @doc """
  Changeset for updating an existing orchestrator state record.

  Increments the version and replaces state_data.
  """
  @spec update_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def update_changeset(state, attrs) do
    state
    |> cast(attrs, [:state_data])
    |> validate_required([:state_data])
    |> validate_state_data()
  end

  defp validate_state_data(changeset) do
    validate_change(changeset, :state_data, fn :state_data, value ->
      if is_map(value) and not is_struct(value) do
        []
      else
        [state_data: "must be a JSON object"]
      end
    end)
  end
end
