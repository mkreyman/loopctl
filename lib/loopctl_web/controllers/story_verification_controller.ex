defmodule LoopctlWeb.StoryVerificationController do
  @moduledoc """
  Controller for orchestrator verification operations on stories.

  Implements the orchestrator side of the two-tier trust model:
  - POST /stories/:id/verify -- verify a reported_done story
  - POST /stories/:id/reject -- reject a story with reason
  - GET /stories/:id/verifications -- list verification history

  All mutation endpoints require exact_role: :orchestrator.

  TODO: Superadmin access via impersonation with X-Effective-Role header (US-11.2)
  """

  use LoopctlWeb, :controller

  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Stories

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole,
       [exact_role: :orchestrator] when action in [:verify, :reject, :force_unclaim]

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :agent] when action in [:index]

  @doc """
  POST /api/v1/stories/:id/verify

  Orchestrator verifies a story. Creates a verification_result with result=pass.
  """
  def verify(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    case Progress.verify_story(tenant_id, story_id, params,
           orchestrator_agent_id: api_key.agent_id,
           actor_id: api_key.id,
           actor_label: "orchestrator:#{api_key.name}"
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
  POST /api/v1/stories/:id/reject

  Orchestrator rejects a story. Requires a non-empty reason.
  Creates a verification_result with result=fail.
  """
  def reject(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    case Progress.reject_story(tenant_id, story_id, params,
           orchestrator_agent_id: api_key.agent_id,
           actor_id: api_key.id,
           actor_label: "orchestrator:#{api_key.name}"
         ) do
      {:ok, story} ->
        json(conn, %{story: story})

      {:error, :reason_required} ->
        {:error, :unprocessable_entity, "reason is required and cannot be blank"}

      {:error, :invalid_transition} ->
        {:error, :conflict}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  GET /api/v1/stories/:id/verifications

  Lists verification results for a story.
  """
  def index(conn, %{"story_id" => story_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with {:ok, _story} <- Stories.get_story(tenant_id, story_id),
         {:ok, results} <- Progress.list_verifications(tenant_id, story_id) do
      json(conn, %{data: results})
    end
  end

  @doc """
  POST /api/v1/stories/:id/force-unclaim

  Orchestrator force-unclaims a story, resetting it to pending.
  Idempotent on already-pending stories. Does NOT reset verified_status.
  """
  def force_unclaim(conn, %{"id" => story_id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    case Progress.force_unclaim_story(tenant_id, story_id,
           orchestrator_agent_id: api_key.agent_id,
           actor_id: api_key.id,
           actor_label: "orchestrator:#{api_key.name}"
         ) do
      {:ok, story} ->
        json(conn, %{story: story})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end
end
