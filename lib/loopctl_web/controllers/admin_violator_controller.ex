defmodule LoopctlWeb.AdminViolatorController do
  @moduledoc """
  US-26.1.4 — Admin API for pre-existing violation management.
  Requires superadmin role.
  """

  use LoopctlWeb, :controller

  alias Loopctl.AuditChain.Violations

  plug LoopctlWeb.Plugs.RequireRole, role: :superadmin

  @doc "GET /api/v1/admin/violators"
  def index(conn, params) do
    opts =
      []
      |> maybe_add(:tenant_id, params["tenant_id"])
      |> maybe_add(:violation_type, params["violation_type"])
      |> maybe_add(:status, params["status"])
      |> maybe_add(:limit, parse_int(params["limit"]))
      |> maybe_add(:offset, parse_int(params["offset"]))

    result = Violations.list_violations(opts)

    json(conn, %{
      data: Enum.map(result.data, &serialize/1),
      meta: result.meta,
      merge_ready: Violations.pending_count() == 0
    })
  end

  @doc "POST /api/v1/admin/violators/:id/resolve"
  def resolve(conn, %{"id" => id} = params) do
    note = Map.get(params, "note", "")
    key_id = conn.assigns.current_api_key.id

    case Violations.resolve(id, note, key_id) do
      {:ok, violation} ->
        json(conn, %{data: serialize(violation)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: %{message: "Not found", status: 404}})
    end
  end

  @doc "POST /api/v1/admin/violators/:id/ignore"
  def ignore(conn, %{"id" => id} = params) do
    note = Map.get(params, "note", "")

    case Violations.ignore(id, note) do
      {:ok, violation} ->
        json(conn, %{data: serialize(violation)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: %{message: "Not found", status: 404}})
    end
  end

  defp serialize(v) do
    %{
      id: v.id,
      tenant_id: v.tenant_id,
      violation_type: v.violation_type,
      entity_type: v.entity_type,
      entity_id: v.entity_id,
      discovered_at: v.discovered_at,
      detail: v.detail,
      status: v.status,
      resolved_at: v.resolved_at,
      resolution_note: v.resolution_note
    }
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_int(nil), do: nil

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
