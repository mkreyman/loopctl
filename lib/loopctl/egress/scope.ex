defmodule Loopctl.Egress.Scope do
  @moduledoc """
  The `(tenant_id, project_id)` pair an outbound provider call is made on behalf
  of (US-41.4, AC-41.4.2).

  `project_id` is nullable BY DESIGN: `articles.project_id` is nullable
  (tenant-wide articles) and memories have no project association at all. A
  project-less scope inherits the TENANT marking.

  ENDPOINT RESOLUTION IS TENANT-SCOPED ONLY — there is no project-level endpoint
  override anywhere in loopctl, so `project_id` narrows only the MARKING, never
  the endpoint. Consequence, stated rather than hidden: a `local_only` project
  inside a tenant whose endpoints are vendor defaults is `egress_blocked`, and
  the documented remediation is to configure a satisfying endpoint AT TENANT
  level (role `:user`) or to clear the project marking.
  """

  @enforce_keys [:tenant_id]
  defstruct [:tenant_id, :project_id]

  @type t :: %__MODULE__{tenant_id: Ecto.UUID.t(), project_id: Ecto.UUID.t() | nil}

  @doc "Builds a scope for a tenant, optionally narrowed to a project."
  @spec new(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: t()
  def new(tenant_id, project_id \\ nil) when is_binary(tenant_id) do
    %__MODULE__{tenant_id: tenant_id, project_id: project_id}
  end

  @doc """
  Stable string key for the scope, used as the pin-cache key component and the
  `scope_key` on aggregated blocked-decision rows.

  NOTE the cache key is `(tenant_id, scope, host)` — never host alone — because
  locality depends on the TENANT's declared list; a host-keyed cache would let
  tenant A's declaration make a host read as local for tenant B (AC-41.4.12).
  """
  @spec key(t()) :: String.t()
  def key(%__MODULE__{tenant_id: tenant_id, project_id: nil}), do: "tenant:#{tenant_id}"

  def key(%__MODULE__{tenant_id: tenant_id, project_id: project_id}),
    do: "tenant:#{tenant_id}/project:#{project_id}"
end
