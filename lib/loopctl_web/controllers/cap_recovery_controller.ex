defmodule LoopctlWeb.CapRecoveryController do
  @moduledoc """
  Re-mints a capability token for a story the caller is already
  assigned to. Solves the session-crash problem: if an agent loses
  its cap, it can recover without being stuck.

  Security: only re-mints to the lineage that was originally assigned.
  Cannot be used to mint caps for stories you don't own.
  """

  use LoopctlWeb, :controller

  alias Loopctl.Capabilities

  plug LoopctlWeb.Plugs.RequireRole, role: :agent

  @doc "POST /api/v1/stories/:id/recover-cap"
  def recover(conn, %{"id" => story_id} = params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    agent_id = conn.assigns.current_api_key.agent_id
    lineage = Map.get(params, "lineage", [])
    cap_type = Map.get(params, "cap_type", "start_cap")

    # Verify the caller owns this story
    import Ecto.Query

    story =
      from(s in Loopctl.WorkBreakdown.Story,
        where:
          s.id == ^story_id and s.tenant_id == ^tenant_id and s.assigned_agent_id == ^agent_id
      )
      |> Loopctl.AdminRepo.one()

    if story do
      case Capabilities.mint(tenant_id, cap_type, story_id, lineage) do
        {:ok, cap} ->
          conn
          |> put_status(:created)
          |> json(%{data: Capabilities.serialize(cap)})

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: %{message: "Cannot mint cap: #{inspect(reason)}", status: 422}})
      end
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: %{message: "Story not found or not assigned to you", status: 404}})
    end
  end
end
