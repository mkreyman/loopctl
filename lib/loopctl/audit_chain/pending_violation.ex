defmodule Loopctl.AuditChain.PendingViolation do
  @moduledoc """
  Schema for the `audit_pending_violations` table.

  Records pre-existing data violations that need operator triage before
  the Chain of Custody v2 constraints can be enforced.
  """

  use Loopctl.Schema, tenant_scoped: false

  @type t :: %__MODULE__{}

  @violation_types ~w(
    cross_role_binding
    nil_agent_non_user_key
    orphaned_agent_ref
    nil_reviewer
    missing_chain_hash
    unreviewed_reported_done
  )

  @statuses ~w(pending resolved ignored)

  schema "audit_pending_violations" do
    field :tenant_id, Ecto.UUID
    field :violation_type, :string
    field :entity_type, :string
    field :entity_id, Ecto.UUID
    field :discovered_at, :utc_datetime_usec
    field :detail, :map, default: %{}
    field :status, :string, default: "pending"
    field :resolved_at, :utc_datetime_usec
    field :resolved_by_api_key_id, Ecto.UUID
    field :resolution_note, :string

    timestamps()
  end

  @doc false
  def changeset(violation \\ %__MODULE__{}, attrs) do
    violation
    |> cast(attrs, [
      :violation_type,
      :entity_type,
      :entity_id,
      :detail,
      :status,
      :resolved_at,
      :resolved_by_api_key_id,
      :resolution_note
    ])
    |> validate_required([:violation_type, :entity_type])
    |> validate_inclusion(:violation_type, @violation_types)
    |> validate_inclusion(:status, @statuses)
  end

  def violation_types, do: @violation_types
end
