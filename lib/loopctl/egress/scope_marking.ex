defmodule Loopctl.Egress.ScopeMarking do
  @moduledoc """
  A `local_only` marking on a scope — the tenant (`project_id == nil`) or one of
  its projects (US-41.4, AC-41.4.1 / AC-41.4.2).

  Default is OFF everywhere: absence of a row means "not marked". The EFFECTIVE
  marking for a call is the MOST RESTRICTIVE of the tenant and project rows
  (`project OR tenant`) — a project can never relax a tenant marking, and any row
  or operation with no project (articles with a nil `project_id`, memories)
  inherits the TENANT marking. Resolution lives in `Loopctl.Egress`.

  `tenant_id` is set programmatically and never appears in `cast/3`.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "egress_scope_markings" do
    tenant_field()
    belongs_to :project, Loopctl.Projects.Project, type: :binary_id

    field :local_only, :boolean, default: false
    field :enabled_by_actor_type, :string
    field :enabled_by_actor_id, Ecto.UUID
    field :enabled_at, :utc_datetime_usec
    field :acknowledged_blocked_endpoints, {:array, :string}, default: []

    timestamps()
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(marking, attrs) do
    marking
    |> cast(attrs, [
      :project_id,
      :local_only,
      :enabled_by_actor_type,
      :enabled_by_actor_id,
      :enabled_at,
      :acknowledged_blocked_endpoints
    ])
    |> validate_required([:local_only])
    |> foreign_key_constraint(:project_id)
    |> unique_constraint(:tenant_id, name: :egress_scope_markings_tenant_scope_idx)
    |> unique_constraint(:project_id, name: :egress_scope_markings_project_scope_idx)
  end
end
