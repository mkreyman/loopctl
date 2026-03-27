defmodule LoopctlWeb.ApiKeyController do
  @moduledoc """
  Controller for API key management: create, list, revoke, rotate.

  All endpoints require `user` role and are scoped to the current tenant.
  """

  use LoopctlWeb, :controller

  alias Loopctl.Auth
  alias Loopctl.Tenants

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :user

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

    Auth.generate_api_key(attrs)
  end

  defp do_rotate_key(tenant, old_key, grace_hours) do
    new_attrs = %{
      tenant_id: tenant.id,
      name: old_key.name,
      role: old_key.role,
      agent_id: old_key.agent_id
    }

    Loopctl.AdminRepo.transaction(fn ->
      expires_at = DateTime.add(DateTime.utc_now(), grace_hours * 3600, :second)

      with {:ok, {raw_key, new_key}} <- Auth.generate_api_key(new_attrs),
           {:ok, updated_old} <- Auth.expire_api_key(old_key, expires_at) do
        {raw_key, new_key, updated_old}
      else
        {:error, reason} -> Loopctl.AdminRepo.rollback(reason)
      end
    end)
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

  defp safe_to_role(nil), do: nil

  defp safe_to_role(role) when is_binary(role) do
    case role do
      "user" -> :user
      "orchestrator" -> :orchestrator
      "agent" -> :agent
      _ -> nil
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(datetime_str) when is_binary(datetime_str) do
    case DateTime.from_iso8601(datetime_str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_grace_period(nil), do: 24
  defp parse_grace_period(hours) when is_integer(hours), do: hours

  defp parse_grace_period(hours) when is_binary(hours) do
    case Integer.parse(hours) do
      {n, _} -> n
      :error -> 24
    end
  end

  defp parse_grace_period(hours) when is_float(hours), do: round(hours)
end
