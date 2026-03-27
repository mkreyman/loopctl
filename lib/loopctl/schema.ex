defmodule Loopctl.Schema do
  @moduledoc """
  Base schema macro for all loopctl Ecto schemas.

  Provides consistent configuration across all schemas:
  - Binary UUID primary keys (`{:id, :binary_id, autogenerate: true}`)
  - Binary UUID foreign key type
  - Microsecond-precision UTC timestamps
  - Optional tenant scoping via `tenant_field/0` macro
  - Optional soft delete via `deleted_at` field

  ## Usage

  ### Standard tenant-scoped schema

      defmodule Loopctl.Projects.Project do
        use Loopctl.Schema

        schema "projects" do
          tenant_field()
          field :name, :string
          timestamps()
        end
      end

  ### Schema with soft delete

      defmodule Loopctl.Agents.Agent do
        use Loopctl.Schema, soft_delete: true

        schema "agents" do
          tenant_field()
          field :name, :string
          field :deleted_at, :utc_datetime_usec
          timestamps()
        end
      end

  ### Non-tenant-scoped schema (e.g., the tenants table itself)

      defmodule Loopctl.Tenants.Tenant do
        use Loopctl.Schema, tenant_scoped: false

        schema "tenants" do
          field :name, :string
          timestamps()
        end
      end

  ## Options

  - `:tenant_scoped` — when `false`, the `tenant_field/0` macro is still
    available but is not required. Defaults to `true`.
  - `:soft_delete` — when `true`, provides access to `soft_delete_changeset/1`
    and `not_deleted/1` helpers. The `deleted_at` field must still be declared
    in the schema block. Defaults to `false`.
  """

  import Ecto.Query, only: [where: 3]

  @doc """
  Creates a changeset that marks a record as soft-deleted by setting
  `deleted_at` to the current UTC time with microsecond precision.
  """
  @spec soft_delete_changeset(Ecto.Schema.t()) :: Ecto.Changeset.t()
  def soft_delete_changeset(struct) do
    Ecto.Changeset.change(struct, deleted_at: DateTime.utc_now())
  end

  @doc """
  Filters a query to exclude soft-deleted records (where `deleted_at` is not nil).

  ## Example

      Project
      |> Loopctl.Schema.not_deleted()
      |> Repo.all()
  """
  @spec not_deleted(Ecto.Queryable.t()) :: Ecto.Query.t()
  def not_deleted(queryable) do
    where(queryable, [r], is_nil(r.deleted_at))
  end

  defmacro __using__(opts) do
    opts = Keyword.merge([tenant_scoped: true, soft_delete: false], opts)
    _tenant_scoped = Keyword.fetch!(opts, :tenant_scoped)
    soft_delete = Keyword.fetch!(opts, :soft_delete)

    quote do
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime_usec]

      if unquote(soft_delete) do
        @loopctl_soft_delete true
        @before_compile Loopctl.Schema
      end

      import Loopctl.Schema, only: [tenant_field: 0]
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    if Module.get_attribute(env.module, :loopctl_soft_delete) do
      fields = Module.get_attribute(env.module, :ecto_fields, [])
      field_names = Enum.map(fields, &elem(&1, 0))

      unless :deleted_at in field_names do
        IO.warn(
          "#{inspect(env.module)} uses `use Loopctl.Schema, soft_delete: true` " <>
            "but does not define a `deleted_at` field. " <>
            "Add `field :deleted_at, :utc_datetime_usec` to the schema block.",
          Macro.Env.stacktrace(env)
        )
      end
    end
  end

  @doc """
  Adds a `tenant_id` field as a `belongs_to` association to `Loopctl.Tenants.Tenant`.

  Must be called inside a `schema` block:

      schema "my_table" do
        tenant_field()
        field :name, :string
        timestamps()
      end

  The tenant_id is set programmatically and must never appear in `cast/3`.
  """
  defmacro tenant_field do
    quote do
      belongs_to :tenant, Loopctl.Tenants.Tenant, type: :binary_id
    end
  end
end
