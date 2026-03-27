defmodule LoopctlWeb.StoryStatusController do
  @moduledoc """
  Controller for agent status transitions on stories.

  Implements the agent side of the two-tier trust model:
  - POST /stories/:id/contract -- acknowledge ACs (pending -> contracted)
  - POST /stories/:id/claim -- claim story (contracted -> assigned)
  - POST /stories/:id/start -- begin work (assigned -> implementing)
  - POST /stories/:id/report -- report done (implementing -> reported_done)
  - POST /stories/:id/unclaim -- release story (any -> pending)

  All endpoints require exact_role: :agent.

  TODO: Superadmin access via impersonation with X-Effective-Role header (US-11.2)
  """

  use LoopctlWeb, :controller

  alias Loopctl.Progress

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole,
       [exact_role: :agent] when action in [:contract, :claim, :start, :report, :unclaim]

  @doc """
  POST /api/v1/stories/:id/contract

  Agent acknowledges the story's acceptance criteria.
  Request body must include story_title and ac_count matching the actual story.
  """
  def contract(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    case Progress.contract_story(tenant_id, story_id, params,
           agent_id: api_key.agent_id,
           actor_id: api_key.id,
           actor_label: "agent:#{api_key.name}"
         ) do
      {:ok, story} ->
        json(conn, %{story: story})

      {:error, :title_mismatch} ->
        {:error, :unprocessable_entity, "story_title does not match"}

      {:error, :ac_count_mismatch} ->
        {:error, :unprocessable_entity, "ac_count does not match"}

      {:error, :invalid_transition} ->
        {:error, :conflict}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  POST /api/v1/stories/:id/claim

  Agent claims a contracted story. Uses pessimistic locking.
  """
  def claim(conn, %{"id" => story_id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    case Progress.claim_story(tenant_id, story_id,
           agent_id: api_key.agent_id,
           actor_id: api_key.id,
           actor_label: "agent:#{api_key.name}"
         ) do
      {:ok, story} ->
        json(conn, %{story: story})

      {:error, :invalid_transition} ->
        {:error, :conflict}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  POST /api/v1/stories/:id/start

  Agent starts work on an assigned story.
  """
  def start(conn, %{"id" => story_id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    case Progress.start_story(tenant_id, story_id,
           agent_id: api_key.agent_id,
           actor_id: api_key.id,
           actor_label: "agent:#{api_key.name}"
         ) do
      {:ok, story} ->
        json(conn, %{story: story})

      {:error, :not_assigned_agent} ->
        {:error, :forbidden}

      {:error, :invalid_transition} ->
        {:error, :conflict}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  POST /api/v1/stories/:id/report

  Agent reports story as done. Optionally includes an artifact report.
  """
  def report(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    artifact_params = extract_artifact_params(params)

    case Progress.report_story(
           tenant_id,
           story_id,
           [
             agent_id: api_key.agent_id,
             actor_id: api_key.id,
             actor_label: "agent:#{api_key.name}"
           ],
           artifact_params
         ) do
      {:ok, story} ->
        json(conn, %{story: story})

      {:error, :not_assigned_agent} ->
        {:error, :forbidden}

      {:error, :invalid_transition} ->
        {:error, :conflict}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  POST /api/v1/stories/:id/unclaim

  Agent releases a story back to pending.
  """
  def unclaim(conn, %{"id" => story_id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    case Progress.unclaim_story(tenant_id, story_id,
           agent_id: api_key.agent_id,
           actor_id: api_key.id,
           actor_label: "agent:#{api_key.name}"
         ) do
      {:ok, story} ->
        json(conn, %{story: story})

      {:error, :not_assigned_agent} ->
        {:error, :forbidden}

      {:error, :invalid_transition} ->
        {:error, :conflict}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # --- Private helpers ---

  defp extract_artifact_params(%{"artifact" => artifact}) when is_map(artifact) do
    %{
      "artifact_type" => artifact["artifact_type"],
      "path" => artifact["path"],
      "exists" => artifact["exists"],
      "details" => artifact["details"]
    }
  end

  defp extract_artifact_params(_), do: nil
end
