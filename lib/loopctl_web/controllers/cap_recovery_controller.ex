defmodule LoopctlWeb.CapRecoveryController do
  @moduledoc """
  Re-mints a capability token for a story the caller is already
  assigned to. Solves the session-crash problem: if an agent loses
  its cap, it can recover without being stuck.

  ## Security (custody-04)

  This is an auth boundary, not a feature endpoint. The caller supplies
  ONLY the story id (from the URL). Every cryptographic claim is derived
  server-side:

  - `cap_type` is HARDCODED to `start_cap`. Recovery can only ever
    re-issue the token that gates `start_story`. A client-supplied
    `cap_type` (e.g. `verify_cap`) is rejected and logged — otherwise an
    agent could have the server sign a `verify_cap` and self-certify its
    own work, collapsing chain-of-custody.
  - `lineage` is RE-DERIVED from the story's `implementer_dispatch_id`
    (the dispatch recorded at claim time). A client-supplied `lineage`
    is rejected and logged — otherwise an agent could mint a validly
    signed cap bound to an arbitrary lineage.

  The caller must own the story (`assigned_agent_id == caller`) or the
  request is a 404. Nothing the client sends is ever passed to
  `Capabilities.mint/4`.
  """

  use LoopctlWeb, :controller

  require Logger

  import Ecto.Query

  alias Loopctl.Capabilities
  alias Loopctl.Dispatches

  # The only cap type this endpoint may ever mint. Recovery re-issues the
  # token that gates `start_story` — never a report/verify/review cap.
  @recovery_cap_type "start_cap"

  plug LoopctlWeb.Plugs.RequireRole, role: :agent

  @doc "POST /api/v1/stories/:id/recover-cap"
  def recover(conn, %{"id" => story_id} = params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    agent_id = conn.assigns.current_api_key.agent_id

    reject_client_claims(params, tenant_id, agent_id, story_id)

    # Verify the caller owns this story. Uses AdminRepo (BYPASSRLS) but is
    # explicitly tenant- and agent-scoped so it cannot leak across tenants.
    story =
      from(s in Loopctl.WorkBreakdown.Story,
        where:
          s.id == ^story_id and s.tenant_id == ^tenant_id and
            s.assigned_agent_id == ^agent_id
      )
      |> Loopctl.AdminRepo.one()

    if story do
      recover_for_story(conn, tenant_id, story)
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: %{message: "Story not found or not assigned to you", status: 404}})
    end
  end

  # --- Private ---

  defp recover_for_story(conn, tenant_id, story) do
    # Re-derive the authoritative lineage server-side. This is the SAME
    # source used when the start_cap was originally minted at claim time
    # (progress.ex): the lineage_path of the story's implementer dispatch.
    lineage = server_derived_lineage(tenant_id, story)

    case Capabilities.mint(tenant_id, @recovery_cap_type, story.id, lineage) do
      {:ok, cap} ->
        conn
        |> put_status(:created)
        |> json(%{data: Capabilities.serialize(cap)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{message: "Cannot mint cap: #{inspect(reason)}", status: 422}})
    end
  end

  # Lineage is NEVER taken from the request. It is the lineage_path of the
  # dispatch recorded on the story at claim time. Legacy stories claimed
  # without a dispatch have no implementer_dispatch_id → empty lineage,
  # which matches how their start_cap was originally minted.
  defp server_derived_lineage(_tenant_id, %{implementer_dispatch_id: nil}), do: []

  defp server_derived_lineage(tenant_id, %{implementer_dispatch_id: dispatch_id}) do
    case Dispatches.get_dispatch(tenant_id, dispatch_id) do
      {:ok, dispatch} -> dispatch.lineage_path
      {:error, _} -> []
    end
  end

  # Any cryptographic claim the client tried to smuggle in is ignored and
  # logged as a warning — these are the exact inputs custody-04 exploited.
  defp reject_client_claims(params, tenant_id, agent_id, story_id) do
    if Map.has_key?(params, "cap_type") do
      Logger.warning(
        "cap_recovery: rejecting client-supplied cap_type=#{inspect(params["cap_type"])}; " <>
          "forcing #{@recovery_cap_type} (tenant=#{tenant_id} agent=#{agent_id} story=#{story_id})"
      )
    end

    if Map.has_key?(params, "lineage") do
      Logger.warning(
        "cap_recovery: rejecting client-supplied lineage=#{inspect(params["lineage"])}; " <>
          "re-deriving from story implementer dispatch (tenant=#{tenant_id} agent=#{agent_id} story=#{story_id})"
      )
    end

    :ok
  end
end
