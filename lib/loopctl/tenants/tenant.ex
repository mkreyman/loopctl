defmodule Loopctl.Tenants.Tenant do
  @moduledoc """
  Minimal tenant schema placeholder.

  The full Tenant schema with validations and context functions
  will be implemented in Epic 2 (Tenant Management). This module
  exists so that `belongs_to :tenant, Loopctl.Tenants.Tenant`
  compiles in the base schema macro.
  """

  use Loopctl.Schema, tenant_scoped: false

  schema "tenants" do
    field :name, :string
    field :slug, :string
    field :status, :string, default: "active"

    timestamps()
  end
end
