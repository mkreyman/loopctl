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

  @statuses [:active, :suspended, :deactivated, :pending_enrollment]
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
    # US-26.0.2: ed25519 public key for signing audit chain entries
    field :audit_signing_public_key, :binary
    field :audit_key_rotated_at, :utc_datetime_usec

    has_many :root_authenticators, Loopctl.Tenants.RootAuthenticator, foreign_key: :tenant_id
    has_many :audit_key_history, Loopctl.Tenants.AuditKeyHistory, foreign_key: :tenant_id

    timestamps()
  end

  @doc """
  US-26.0.1 — changeset for the WebAuthn signup ceremony.

  The tenant is inserted with `status: :pending_enrollment` and flipped
  to `:active` only after the authenticator rows are written. The slug
  is normalized to lowercase kebab-case and validated against the
  canonical regex + length rules.
  """
  @spec signup_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def signup_changeset(tenant \\ %__MODULE__{}, attrs) do
    tenant
    |> cast(normalize_signup_attrs(attrs), [:name, :slug, :email])
    |> validate_required([:name, :slug, :email])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_slug(min: 2, max: 64)
    |> validate_email()
    |> put_change(:status, :pending_enrollment)
    |> put_change(:settings, %{})
    |> unique_constraint(:slug)
    |> unique_constraint(:email, name: :tenants_email_index)
  end

  @doc """
  Marks a tenant previously created via the signup ceremony as fully
  enrolled and ready for use.
  """
  @spec activate_after_enrollment_changeset(%__MODULE__{}) :: Ecto.Changeset.t()
  def activate_after_enrollment_changeset(tenant) do
    change(tenant, status: :active)
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

  defp validate_slug(changeset, opts \\ []) do
    min = Keyword.get(opts, :min, 2)
    max = Keyword.get(opts, :max, 63)

    changeset
    |> validate_format(:slug, @slug_format,
      message:
        "must be lowercase alphanumeric with hyphens, starting and ending with alphanumeric"
    )
    |> validate_length(:slug, min: min, max: max)
  end

  defp normalize_signup_attrs(attrs) when is_map(attrs) do
    attrs
    |> Map.new(fn
      {key, value} when key in [:slug, "slug"] and is_binary(value) ->
        {key, value |> String.trim() |> String.downcase()}

      {key, value} when key in [:email, "email"] and is_binary(value) ->
        {key, value |> String.trim() |> String.downcase()}

      {key, value} when key in [:name, "name"] and is_binary(value) ->
        {key, String.trim(value)}

      kv ->
        kv
    end)
  end

  defp normalize_signup_attrs(attrs), do: attrs

  defp validate_email(changeset) do
    validate_format(changeset, :email, @email_format, message: "must be a valid email address")
  end

  defp validate_settings(changeset) do
    validate_change(changeset, :settings, fn :settings, value ->
      cond do
        not is_map(value) or is_struct(value) ->
          [settings: "must be a map"]

        not valid_knowledge_auto_extract?(value) ->
          [settings: "knowledge_auto_extract must be a boolean"]

        true ->
          []
      end
    end)
  end

  defp valid_knowledge_auto_extract?(settings) do
    case Map.get(settings, "knowledge_auto_extract") do
      nil -> true
      val when is_boolean(val) -> true
      _ -> false
    end
  end

  # AC-21.14.6: Minimum 30 days. nil disables retention.
  # Note: validate_change/3 skips nil values (the callback is not invoked),
  # so passing nil correctly results in no validation errors.
  defp validate_retention_days(changeset) do
    validate_change(changeset, :token_data_retention_days, fn :token_data_retention_days, value ->
      cond do
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
