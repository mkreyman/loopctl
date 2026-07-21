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

  # Roles that may be minted through the public HTTP API-key create path.
  # `:superadmin` is deliberately excluded: superadmin keys can only be
  # provisioned out-of-band via the privileged `create_changeset/2` path
  # (bootstrap/fixtures/dispatch). See #462 — defense-in-depth so a future
  # internal caller that reaches the HTTP path can't mint a superadmin key.
  @http_roles [:user, :orchestrator, :agent]

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
    field :sth_bootstrap_consumed_at, :utc_datetime_usec

    timestamps()
  end

  @doc """
  Changeset for creating a new API key (privileged / full-role path).

  Accepts the FULL role set including `:superadmin`. This is the bootstrap /
  fixture / dispatch provisioning path — the only path that may mint a
  superadmin key. HTTP callers must use `http_create_changeset/2` instead,
  which structurally excludes `:superadmin` (#462).

  The `key_hash` and `key_prefix` are set programmatically, not via cast.
  The `tenant_id` is also set programmatically.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(api_key \\ %__MODULE__{}, attrs) do
    base_create_changeset(api_key, attrs, @roles)
  end

  @doc """
  Changeset for creating a new API key via the public HTTP API path.

  Identical to `create_changeset/2` except the allowed roles are restricted
  to `#{inspect(@http_roles)}` — `:superadmin` is structurally rejected with a
  clear error (#462).

  This is a defense-in-depth backstop for DIRECT context callers that reach the
  HTTP path with a raw `:superadmin` role. Note that the
  `LoopctlWeb.ApiKeyController` create path does NOT exercise this specific
  rejection: it returns 403 for `role: "superadmin"` first, and even if that
  guard were bypassed its `safe_to_role/1` maps `"superadmin"` to `nil`, so the
  changeset would fail via `validate_required` ("can't be blank") rather than
  this role-inclusion message. The superadmin-specific message therefore only
  fires for a caller passing the `:superadmin` atom directly to this changeset.
  """
  @spec http_create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def http_create_changeset(api_key \\ %__MODULE__{}, attrs) do
    base_create_changeset(api_key, attrs, @http_roles,
      role_message: "superadmin keys cannot be created via the API"
    )
  end

  defp base_create_changeset(api_key, attrs, allowed_roles, opts \\ []) do
    inclusion_opts =
      case Keyword.get(opts, :role_message) do
        nil -> []
        message -> [message: message]
      end

    api_key
    |> cast(attrs, [:name, :role, :expires_at, :agent_id])
    |> validate_required([:name, :role])
    |> validate_inclusion(:role, allowed_roles, inclusion_opts)
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
  Changeset for setting expires_at (used during key rotation).
  """
  @spec expire_changeset(%__MODULE__{}, DateTime.t()) :: Ecto.Changeset.t()
  def expire_changeset(api_key, expires_at) do
    change(api_key, expires_at: expires_at)
  end

  # NOTE: the one-time STH bootstrap grace (custody-03) is consumed via an
  # atomic conditional `UPDATE ... WHERE sth_bootstrap_consumed_at IS NULL`
  # in `LoopctlWeb.Plugs.ValidateWitnessHeader` — NOT via a changeset — so the
  # NULL guard is evaluated by Postgres and two concurrent first-requests
  # cannot both win. See that plug for the single-winner logic.

  @doc """
  Returns the list of valid roles.
  """
  @spec roles() :: [atom()]
  def roles, do: @roles

  @doc """
  Returns the list of roles that may be created via the public HTTP API path
  (the full role set minus `:superadmin`). See `http_create_changeset/2`.
  """
  @spec http_roles() :: [atom()]
  def http_roles, do: @http_roles

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
