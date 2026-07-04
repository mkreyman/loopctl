defmodule LoopctlWeb.CapRecoveryController do
  @moduledoc """
  Re-mints a capability token for a story the caller is already
  assigned to. Solves the session-crash problem: if an agent loses
  its cap, it can recover without being stuck.

  Security (L1 capability layer, chain-of-custody v2):

    * Recovery re-mints ONLY a `start_cap`. A client that supplies any
      other `cap_type` (e.g. `verify_cap`, `report_cap`,
      `review_complete_cap`) is rejected with 422 — an agent must never
      be able to mint a capability to verify/report/review its own work.
      A forged-cap-type attempt is an L1 forgery attempt: it is logged
      (Logger.warning) and recorded in the story's audit history
      (`cap_recovery_forgery_attempt`) so operators and L5/L6 detection
      can see it.
    * The lineage the cap is bound to is DERIVED SERVER-SIDE from the
      story's recorded implementer dispatch (`implementer_dispatch_id` ->
      `Dispatch.lineage_path`). A client-supplied `lineage` param is
      ignored entirely — the cap is always scoped to the lineage that was
      actually dispatched to work the story.
    * The recorded dispatch must still be ACTIVE (not revoked, not
      expired). A revoked dispatch is an L6 custody-halt stop signal;
      recovery must not mint a fresh cap off a halted/expired lineage.
    * The caller must own the story (`assigned_agent_id`). The role gate
      is `exact_role: :agent` (no hierarchy) to match the sibling
      agent-exclusive custody endpoints (claim/start/request_review/
      unclaim) — an orchestrator identity linked to the same agent_id
      must not be able to walk this gate where it couldn't walk claim.
  """

  use LoopctlWeb, :controller

  require Logger

  import Ecto.Query

  alias Loopctl.Audit
  alias Loopctl.Capabilities
  alias Loopctl.Dispatches
  alias Loopctl.WorkBreakdown.Story

  plug LoopctlWeb.Plugs.RequireRole, exact_role: :agent

  # US-26.7.1 — work-breakdown surface requires a human-anchored tenant.
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:recover]

  @doc "POST /api/v1/stories/:id/recover-cap"
  def recover(conn, %{"id" => story_id} = params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    agent_id = conn.assigns.current_api_key.agent_id

    with :ok <- validate_start_cap(params),
         {:ok, story} <- fetch_owned_story(tenant_id, agent_id, story_id),
         {:ok, lineage} <- recorded_lineage(tenant_id, story),
         {:ok, cap} <- Capabilities.mint(tenant_id, "start_cap", story.id, lineage) do
      conn
      |> put_status(:created)
      |> json(%{data: Capabilities.serialize(cap)})
    else
      {:error, :invalid_cap_type} ->
        log_forgery_attempt(conn, tenant_id, agent_id, story_id, Map.get(params, "cap_type"))
        error(conn, 422, "cap recovery only re-mints start_cap")

      {:error, :not_found} ->
        error(conn, 404, "Story not found or not assigned to you")

      {:error, :no_dispatch_lineage} ->
        error(
          conn,
          422,
          "No recorded dispatch lineage for this story — cannot recover a cap " <>
            "for a story you weren't dispatched to"
        )

      {:error, :dispatch_inactive} ->
        error(
          conn,
          422,
          "The story's implementer dispatch has been revoked or has expired — " <>
            "cannot recover a cap off a halted lineage"
        )

      {:error, reason} ->
        error(conn, 422, "Cannot mint cap: #{inspect(reason)}")
    end
  end

  # --- Private ---

  # Recovery only ever re-mints a start_cap. An absent cap_type defaults
  # to start_cap; anything else is a client trying to forge a higher-trust
  # capability and is rejected.
  defp validate_start_cap(params) do
    case Map.get(params, "cap_type") do
      nil -> :ok
      "start_cap" -> :ok
      _other -> {:error, :invalid_cap_type}
    end
  end

  defp fetch_owned_story(tenant_id, agent_id, story_id) do
    story =
      from(s in Story,
        where:
          s.id == ^story_id and s.tenant_id == ^tenant_id and s.assigned_agent_id == ^agent_id
      )
      |> Loopctl.AdminRepo.one()

    if story, do: {:ok, story}, else: {:error, :not_found}
  end

  # The canonical lineage is the implementer dispatch's lineage_path,
  # recorded on the story at claim time. Never trust a client-supplied
  # lineage — resolve it from the dispatch record server-side, and only
  # if that dispatch is still active.
  defp recorded_lineage(_tenant_id, %Story{implementer_dispatch_id: nil}),
    do: {:error, :no_dispatch_lineage}

  defp recorded_lineage(tenant_id, %Story{implementer_dispatch_id: dispatch_id}) do
    case Dispatches.get_dispatch(tenant_id, dispatch_id) do
      {:ok, dispatch} -> active_lineage(dispatch)
      _ -> {:error, :no_dispatch_lineage}
    end
  end

  # Mirror DispatchController.validate_parent_and_create/4: a dispatch is
  # only usable if it is neither revoked nor expired. A revoked dispatch is
  # a custody-halt stop signal — recovery must not mint off it.
  defp active_lineage(dispatch) do
    now = DateTime.utc_now()

    cond do
      not is_nil(dispatch.revoked_at) -> {:error, :dispatch_inactive}
      DateTime.compare(dispatch.expires_at, now) != :gt -> {:error, :dispatch_inactive}
      dispatch.lineage_path == [] -> {:error, :no_dispatch_lineage}
      true -> {:ok, dispatch.lineage_path}
    end
  end

  # An agent asking recovery to mint it a verify_cap/report_cap/
  # review_complete_cap is forging the L1 capability layer. Surface it: a
  # Logger.warning (structured data in the message string, following
  # log_custody_orphaned) plus an audit entry so it appears in
  # GET /stories/:id/history and can feed anomaly detection. The audit
  # write is best-effort — it must never mask the 422.
  defp log_forgery_attempt(conn, tenant_id, agent_id, story_id, rejected_cap_type) do
    Logger.warning(
      "cap_recovery_forgery_attempt: agent attempted to mint a non-start_cap via cap " <>
        "recovery — rejected_cap_type=#{inspect(rejected_cap_type)} story_id=#{story_id} " <>
        "tenant_id=#{tenant_id} caller_agent_id=#{inspect(agent_id)}"
    )

    attrs =
      conn
      |> LoopctlWeb.AuditContext.from_conn()
      |> Map.new()
      |> Map.merge(%{
        entity_type: "story",
        entity_id: story_id,
        action: "cap_recovery_forgery_attempt",
        metadata: %{
          "rejected_cap_type" => to_string(rejected_cap_type),
          "caller_agent_id" => agent_id
        }
      })

    _ = Audit.create_log_entry(tenant_id, attrs)
    :ok
  end

  defp error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{message: message, status: status}})
  end
end
