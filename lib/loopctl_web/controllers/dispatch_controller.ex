defmodule LoopctlWeb.DispatchController do
  @moduledoc """
  US-26.2.1 — REST API for dispatch lineage management.
  """

  use LoopctlWeb, :controller

  alias Loopctl.Dispatches

  plug LoopctlWeb.Plugs.RequireRole, [role: :orchestrator] when action in [:create]
  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:show, :index]

  @doc "POST /api/v1/dispatches"
  def create(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    case Dispatches.create_dispatch(tenant_id, params) do
      {:ok, %{dispatch: dispatch, raw_key: raw_key}} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            dispatch: serialize(dispatch),
            api_key: %{
              raw_key: raw_key,
              role: dispatch.role,
              agent_id: dispatch.agent_id,
              expires_at: dispatch.expires_at
            },
            next_action: %{
              description:
                "Pass the raw_key to the sub-agent via launch arguments. Never store it.",
              learn_more: "https://loopctl.com/wiki/dispatch-lineage"
            }
          }
        })

      {:error, :parent_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Parent dispatch not found", status: 404}})

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{message: "Dispatch creation failed", status: 422}})
    end
  end

  @doc "GET /api/v1/dispatches/:id"
  def show(conn, %{"id" => id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    case Dispatches.get_dispatch(tenant_id, id) do
      {:ok, dispatch} ->
        json(conn, %{data: serialize(dispatch)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Not found", status: 404}})
    end
  end

  @doc "GET /api/v1/dispatches"
  def index(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      []
      |> maybe_add(:role, params["role"])
      |> maybe_add(:active_only, params["active_only"] == "true")
      |> maybe_add(:limit, parse_int(params["limit"]))
      |> maybe_add(:offset, parse_int(params["offset"]))

    result = Dispatches.list_dispatches(tenant_id, opts)

    json(conn, %{
      data: Enum.map(result.data, &serialize/1),
      meta: result.meta
    })
  end

  defp serialize(d) do
    %{
      id: d.id,
      tenant_id: d.tenant_id,
      parent_dispatch_id: d.parent_dispatch_id,
      agent_id: d.agent_id,
      story_id: d.story_id,
      role: d.role,
      lineage_path: d.lineage_path,
      expires_at: d.expires_at,
      revoked_at: d.revoked_at,
      created_at: d.created_at
    }
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, _key, false), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_int(nil), do: nil

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
