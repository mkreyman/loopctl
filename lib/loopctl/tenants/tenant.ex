defmodule Loopctl.Tenants.Tenant do
  @moduledoc """
  Schema for the `tenants` table — the root organizational unit.

  Tenants are NOT tenant-scoped (they have no `tenant_id` column).
  All downstream entities belong to a tenant via `tenant_id` foreign keys.

  ## Fields

  - `name` — display name
  - `slug` — URL-safe unique identifier (lowercase alphanumeric + hyphens)
  - `email` — contact email for the tenant
  - `settings` — jsonb map for tenant-level configuration
  - `status` — `:active`, `:suspended`, or `:deactivated`
  - `default_story_budget_millicents` — nullable tenant-wide default budget for stories
  """

  use Loopctl.Schema, tenant_scoped: false

  @type t :: %__MODULE__{}

  @statuses [:active, :suspended, :deactivated]
  @slug_format ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/
  @email_format ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/
  @min_retention_days 30

  schema "tenants" do
    field :name, :string
    field :slug, :string
    field :email, :string
    field :settings, :map, default: %{}
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :default_story_budget_millicents, :integer
    # AC-21.14.1: NULL means unlimited (no archival)
    field :token_data_retention_days, :integer

    timestamps()
  end

  @doc """
  Changeset for creating a new tenant.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(tenant \\ %__MODULE__{}, attrs) do
    tenant
    |> cast(attrs, [:name, :slug, :email, :settings])
    |> validate_required([:name, :slug, :email])
    |> validate_slug()
    |> validate_email()
    |> validate_settings()
    |> unique_constraint(:slug)
  end

  @doc """
  Changeset for updating an existing tenant.

  Accepts `token_data_retention_days` (integer >= 30, or nil to disable).
  """
  @spec update_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def update_changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [
      :name,
      :slug,
      :email,
      :settings,
      :default_story_budget_millicents,
      :token_data_retention_days
    ])
    |> validate_slug()
    |> validate_email()
    |> validate_settings()
    |> validate_number(:default_story_budget_millicents, greater_than: 0)
    |> validate_retention_days()
    |> unique_constraint(:slug)
  end

  @doc """
  Changeset for status transitions (suspend, activate, deactivate).
  """
  @spec status_changeset(%__MODULE__{}, atom()) :: Ecto.Changeset.t()
  def status_changeset(tenant, status) when status in @statuses do
    change(tenant, status: status)
  end

  defp validate_slug(changeset) do
    changeset
    |> validate_format(:slug, @slug_format,
      message:
        "must be lowercase alphanumeric with hyphens, starting and ending with alphanumeric"
    )
    |> validate_length(:slug, min: 2, max: 63)
  end

  defp validate_email(changeset) do
    validate_format(changeset, :email, @email_format, message: "must be a valid email address")
  end

  defp validate_settings(changeset) do
    validate_change(changeset, :settings, fn :settings, value ->
      if is_map(value) and not is_struct(value) do
        []
      else
        [settings: "must be a map"]
      end
    end)
  end

  # AC-21.14.6: Minimum 30 days. nil disables retention.
  defp validate_retention_days(changeset) do
    validate_change(changeset, :token_data_retention_days, fn :token_data_retention_days, value ->
      cond do
        is_nil(value) ->
          []

        not is_integer(value) ->
          [token_data_retention_days: "must be an integer"]

        value < @min_retention_days ->
          [
            token_data_retention_days: "must be at least #{@min_retention_days} days"
          ]

        true ->
          []
      end
    end)
  end
end
