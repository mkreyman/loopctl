defmodule Loopctl.Auth.ApiKey do
  @moduledoc """
  Schema for the `api_keys` table.

  API keys are the sole authentication mechanism for loopctl. Raw keys
  are never stored -- only their SHA-256 hash. The `key_prefix` (first 8
  characters) allows identification without exposing the full key.

  ## Roles

  - `:superadmin` -- app-wide, tenant_id is NULL
  - `:user` -- tenant-scoped, full tenant management
  - `:orchestrator` -- tenant-scoped, verification writes
  - `:agent` -- tenant-scoped, agent status writes
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @roles [:superadmin, :user, :orchestrator, :agent]

  schema "api_keys" do
    tenant_field()
    field :name, :string
    field :key_hash, :string
    field :key_prefix, :string
    field :role, Ecto.Enum, values: @roles
    field :agent_id, :binary_id
    field :last_used_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    timestamps()
  end

  @doc """
  Changeset for creating a new API key.

  The `key_hash` and `key_prefix` are set programmatically, not via cast.
  The `tenant_id` is also set programmatically.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(api_key \\ %__MODULE__{}, attrs) do
    api_key
    |> cast(attrs, [:name, :role, :expires_at, :agent_id])
    |> validate_required([:name, :role])
    |> validate_inclusion(:role, @roles)
    |> validate_tenant_for_role()
    |> unique_constraint([:tenant_id, :agent_id],
      name: :api_keys_one_role_per_agent_idx,
      message: "agent already has an active key with this role"
    )
  end

  @doc """
  Changeset for revoking an API key (sets revoked_at).
  """
  @spec revoke_changeset(%__MODULE__{}) :: Ecto.Changeset.t()
  def revoke_changeset(api_key) do
    change(api_key, revoked_at: DateTime.utc_now())
  end

  @doc """
  Changeset for updating last_used_at timestamp.
  """
  @spec touch_changeset(%__MODULE__{}) :: Ecto.Changeset.t()
  def touch_changeset(api_key) do
    change(api_key, last_used_at: DateTime.utc_now())
  end

  @doc """
  Changeset for setting expires_at (used during key rotation).
  """
  @spec expire_changeset(%__MODULE__{}, DateTime.t()) :: Ecto.Changeset.t()
  def expire_changeset(api_key, expires_at) do
    change(api_key, expires_at: expires_at)
  end

  @doc """
  Returns the list of valid roles.
  """
  @spec roles() :: [atom()]
  def roles, do: @roles

  defp validate_tenant_for_role(changeset) do
    validate_change(changeset, :role, fn :role, role ->
      tenant_id = get_field(changeset, :tenant_id)

      cond do
        role == :superadmin and not is_nil(tenant_id) ->
          [role: "superadmin keys must not have a tenant_id"]

        role != :superadmin and is_nil(tenant_id) ->
          [tenant_id: "is required for non-superadmin keys"]

        true ->
          []
      end
    end)
  end
end
