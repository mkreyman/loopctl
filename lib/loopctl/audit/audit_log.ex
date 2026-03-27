defmodule Loopctl.Audit.AuditLog do
  @moduledoc """
  Schema for the `audit_log` table.

  The audit log is an append-only, immutable record of every mutation
  in the system. Only `create_changeset/1` is provided — no update
  or delete operations are supported.

  ## Fields

  - `entity_type` — the type of entity (e.g., "project", "story", "epic")
  - `entity_id` — the UUID of the affected entity
  - `action` — the action performed (e.g., "created", "updated", "deleted")
  - `actor_type` — who performed the action ("api_key", "system", "superadmin")
  - `actor_id` — the UUID of the actor (API key ID)
  - `actor_label` — human-readable label ("agent:worker-1", "user:admin")
  - `old_state` — JSONB diff of changed fields before mutation (nil for creates)
  - `new_state` — JSONB diff of changed fields after mutation (nil for deletes)
  - `project_id` — optional FK for project-scoped entities
  - `metadata` — additional context as JSONB
  - `inserted_at` — timestamp, no updated_at (immutable)
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :project_id,
             :entity_type,
             :entity_id,
             :action,
             :actor_type,
             :actor_id,
             :actor_label,
             :old_state,
             :new_state,
             :metadata,
             :inserted_at
           ]}

  schema "audit_log" do
    tenant_field()
    field :project_id, :binary_id
    field :entity_type, :string
    field :entity_id, :binary_id
    field :action, :string
    field :actor_type, :string
    field :actor_id, :binary_id
    field :actor_label, :string
    field :old_state, :map
    field :new_state, :map
    field :metadata, :map, default: %{}

    # Immutable — no updated_at
    timestamps(updated_at: false)
  end

  @cast_fields [
    :entity_type,
    :entity_id,
    :action,
    :actor_type,
    :actor_id,
    :actor_label,
    :old_state,
    :new_state,
    :project_id,
    :metadata
  ]

  @required_fields [:entity_type, :entity_id, :action, :actor_type]

  @doc """
  Changeset for creating a new audit log entry.

  This is the only changeset — no update changeset exists.
  The `tenant_id` is set programmatically, not via cast.
  """
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
  end
end
