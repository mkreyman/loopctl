defmodule LoopctlWeb.ApiKeyController do
  @moduledoc """
  Controller for API key management: create, list, revoke, rotate.

  All endpoints require `user` role and are scoped to the current tenant.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Auth
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Tenants

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :user

  # LINEAGE CEILING, minting half. `create` and `rotate` are the two actions that hand
  # back a raw key, and a plain API key belongs to no dispatch lineage — which is
  # exactly the shape DispatchController admits as "may start a new root". Without this
  # a dispatch-minted `:user` key stepped outside its own subtree in one hop by minting
  # (or rotating itself) a plain key. See the plug's moduledoc for why the credential is
  # refused rather than made to inherit the minter's lineage.
  plug LoopctlWeb.Plugs.RequireUnlineagedCaller when action in [:create, :rotate]

  tags(["Auth"])

  operation(:create,
    summary: "Create API key",
    description:
      "Creates a new API key. Returns the raw key once. Requires user role. A caller " <>
        "whose own key was minted by a dispatch (and therefore carries a lineage) is " <>
        "refused with 403 `api_key_mint_forbidden`: a long-lived API key belongs to no " <>
        "lineage, so minting one would place the caller outside its own dispatch subtree. " <>
        "Mint a dispatch beneath your own instead (POST /api/v1/dispatches).",
    request_body: {"API key params", "application/json", Schemas.ApiKeyCreateRequest},
    responses: %{
      201 => {"API key created", "application/json", Schemas.ApiKeyResponse},
      403 =>
        {"Forbidden — superadmin role requested, or the caller carries a dispatch lineage " <>
           "(`api_key_mint_forbidden`)", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:index,
    summary: "List API keys",
    description: "Lists all API keys for the current tenant. Never exposes raw key or hash.",
    parameters: [
      include_revoked: [in: :query, type: :boolean, description: "Include revoked keys"]
    ],
    responses: %{
      200 =>
        {"API key list", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             api_keys: %OpenApiSpex.Schema{type: :array, items: Schemas.ApiKeyResponse}
           }
         }},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:delete,
    summary: "Revoke API key",
    description: "Revokes an API key (sets revoked_at). Requires user role.",
    parameters: [id: [in: :path, type: :string, description: "API key UUID"]],
    responses: %{
      200 => {"API key revoked", "application/json", Schemas.ApiKeyResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:rotate,
    summary: "Rotate API key",
    description:
      "Creates a new key with the same name/role and sets a grace period on the old key. " <>
        "Like `create`, this mints a raw key that belongs to no dispatch lineage, so a " <>
        "caller whose own key carries a lineage is refused with 403 " <>
        "`api_key_mint_forbidden`.",
    parameters: [
      id: [in: :path, type: :string, description: "API key UUID to rotate"]
    ],
    request_body:
      {"Rotation params", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           grace_period_hours: %OpenApiSpex.Schema{
             type: :integer,
             description: "Grace period in hours (default: 24)"
           }
         }
       }},
    responses: %{
      201 =>
        {"Rotated key", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      403 =>
        {"Forbidden — the caller carries a dispatch lineage (`api_key_mint_forbidden`)",
         "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 => {"Cannot rotate", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc """
  POST /api/v1/api_keys

  Creates a new API key. Returns the raw key once.
  """
  def create(conn, params) do
    tenant = conn.assigns.current_tenant

    with :ok <- validate_not_superadmin(params["role"]),
         :ok <- validate_key_limit(tenant),
         {:ok, {raw_key, api_key}} <- do_create_key(tenant, params) do
      conn
      |> put_status(:created)
      |> json(%{api_key: creation_json(raw_key, api_key)})
    end
  end

  @doc """
  GET /api/v1/api_keys

  Lists all API keys for the current tenant. Never exposes raw key or hash.
  """
  def index(conn, params) do
    tenant = conn.assigns.current_tenant
    include_revoked = params["include_revoked"] == "true"

    {:ok, keys} = Auth.list_api_keys(tenant.id, include_revoked: include_revoked)

    json(conn, %{api_keys: Enum.map(keys, &list_json/1)})
  end

  @doc """
  DELETE /api/v1/api_keys/:id

  Revokes an API key (sets revoked_at, does not delete the record).
  """
  def delete(conn, %{"id" => key_id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, api_key} <- Auth.get_api_key(tenant.id, key_id),
         {:ok, revoked} <- Auth.revoke_api_key(api_key) do
      json(conn, %{api_key: revoke_json(revoked)})
    end
  end

  @doc """
  POST /api/v1/api_keys/:id/rotate

  Creates a new key with the same name/role and sets a grace period on the old key.
  """
  def rotate(conn, %{"id" => key_id} = params) do
    tenant = conn.assigns.current_tenant
    grace_hours = parse_grace_period(params["grace_period_hours"])

    with {:ok, old_key} <- Auth.get_api_key(tenant.id, key_id),
         :ok <- validate_not_revoked(old_key),
         {:ok, {raw_key, new_key, updated_old}} <- do_rotate_key(tenant, old_key, grace_hours) do
      conn
      |> put_status(:created)
      |> json(%{
        new_key: creation_json(raw_key, new_key),
        old_key_expires_at: updated_old.expires_at
      })
    end
  end

  # --- Private helpers ---

  defp validate_not_superadmin("superadmin"), do: {:error, :forbidden}
  defp validate_not_superadmin(_role), do: :ok

  defp validate_key_limit(tenant) do
    max_keys = Tenants.get_tenant_settings(tenant, "max_api_keys", 100)
    current_count = Auth.count_api_keys(tenant.id)

    if current_count >= max_keys do
      {:error, :unprocessable_entity, "API key limit reached (max: #{max_keys})"}
    else
      :ok
    end
  end

  defp validate_not_revoked(%{revoked_at: nil}), do: :ok

  defp validate_not_revoked(_key),
    do: {:error, :unprocessable_entity, "Cannot rotate a revoked key"}

  defp do_create_key(tenant, params) do
    attrs = %{
      tenant_id: tenant.id,
      name: params["name"],
      role: safe_to_role(params["role"]),
      expires_at: parse_datetime(params["expires_at"]),
      agent_id: params["agent_id"]
    }

    # Structural backstop (#462). On THIS controller path superadmin is blocked
    # twice before the changeset's role-inclusion gate ever sees it: first
    # `validate_not_superadmin/1` returns 403 for role "superadmin", then
    # `safe_to_role/1` above maps "superadmin" (and any unknown string) to nil.
    # So `role` is already nil here — if the 403 guard were bypassed the :http
    # changeset would reject via `validate_required` ("can't be blank"), NOT via
    # its "superadmin keys cannot be created via the API" message. The @http_roles
    # superadmin exclusion is the backstop for DIRECT context callers that pass a
    # raw `:superadmin` atom (bypassing `safe_to_role/1`); we still route through
    # the HTTP-scoped changeset here so the context layer refuses a superadmin key
    # on every path regardless of how `role` was derived.
    Auth.generate_api_key(attrs, changeset: :http)
  end

  defp do_rotate_key(tenant, old_key, grace_hours) do
    new_attrs = %{
      tenant_id: tenant.id,
      name: old_key.name,
      role: old_key.role,
      agent_id: old_key.agent_id
    }

    result =
      Loopctl.AdminRepo.transaction(fn ->
        expires_at = DateTime.add(DateTime.utc_now(), grace_hours * 3600, :second)

        with {:ok, {raw_key, new_key}} <- Auth.generate_api_key(new_attrs),
             {:ok, updated_old} <- Auth.expire_api_key(old_key, expires_at) do
          {raw_key, new_key, updated_old}
        else
          {:error, reason} -> Loopctl.AdminRepo.rollback(reason)
        end
      end)

    # SECURITY (US-33.3): `generate_api_key`/`expire_api_key` bust the cache
    # in-band, but here that runs INSIDE the transaction (pre-commit). A
    # concurrent `verify_api_key/1` of the OLD key can, on a separate pooled
    # connection under READ COMMITTED, still read the not-yet-committed active old
    # row and repopulate the cache stamped with the pre-commit generation — which
    # would then authenticate the just-rotated-out key until the TTL (acute when
    # grace <= 0 expires it immediately). Re-invalidate BOTH key_hashes AFTER the
    # transaction commits so any such stale repopulation is rejected on the very
    # next request (mirrors the post-commit invalidation in `Dispatches.revoke/2`).
    case result do
      {:ok, {_raw, new_key, updated_old}} ->
        Auth.invalidate_key_cache_by_ids([new_key.id, updated_old.id])
        result

      _ ->
        result
    end
  end

  defp creation_json(raw_key, api_key) do
    %{
      id: api_key.id,
      raw_key: raw_key,
      key_prefix: api_key.key_prefix,
      role: api_key.role,
      name: api_key.name,
      expires_at: api_key.expires_at,
      inserted_at: api_key.inserted_at
    }
  end

  defp list_json(key) do
    %{
      id: key.id,
      name: key.name,
      key_prefix: key.key_prefix,
      role: key.role,
      last_used_at: key.last_used_at,
      expires_at: key.expires_at,
      revoked_at: key.revoked_at,
      inserted_at: key.inserted_at
    }
  end

  defp revoke_json(key) do
    %{
      id: key.id,
      name: key.name,
      key_prefix: key.key_prefix,
      role: key.role,
      revoked_at: key.revoked_at
    }
  end

  # Coerce the client-supplied role string to a known HTTP-creatable role atom,
  # or nil for anything else. The allowlist is derived from `ApiKey.http_roles/0`
  # (the single source of truth: full role set minus :superadmin) by matching on
  # the atom's string form — we NEVER `String.to_atom/1` untrusted input. Unknown
  # strings and non-string JSON values (numbers, booleans, arrays) both map to
  # nil, so they fail cleanly via `validate_required` (422 "can't be blank")
  # rather than raising a FunctionClauseError -> 500.
  defp safe_to_role(role) when is_binary(role) do
    Enum.find(ApiKey.http_roles(), fn allowed -> Atom.to_string(allowed) == role end)
  end

  defp safe_to_role(_role), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(datetime_str) when is_binary(datetime_str) do
    case DateTime.from_iso8601(datetime_str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  @max_grace_period_hours 168

  defp parse_grace_period(nil), do: 24

  defp parse_grace_period(hours) when is_integer(hours),
    do: min(hours, @max_grace_period_hours)

  defp parse_grace_period(hours) when is_binary(hours) do
    case Integer.parse(hours) do
      {n, _} -> min(n, @max_grace_period_hours)
      :error -> 24
    end
  end

  defp parse_grace_period(hours) when is_float(hours),
    do: min(round(hours), @max_grace_period_hours)
end
