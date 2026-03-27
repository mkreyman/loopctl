defmodule LoopctlWeb.StoryVerificationController do
  @moduledoc """
  Controller for orchestrator verification operations on stories.

  Implements the orchestrator side of the two-tier trust model:
  - POST /stories/:id/verify -- verify a reported_done story
  - POST /stories/:id/reject -- reject a story with reason
  - GET /stories/:id/verifications -- list verification history

  All mutation endpoints require exact_role: :orchestrator.
  """

  use LoopctlWeb, :controller

  alias Loopctl.Artifacts
  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Stories
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole,
       [exact_role: :orchestrator] when action in [:verify, :reject, :force_unclaim]

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :orchestrator] when action in [:index]

  @doc """
  POST /api/v1/stories/:id/verify

  Orchestrator verifies a story. Creates a verification_result with result=pass.
  """
  def verify(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    opts = Keyword.merge(AuditContext.from_conn(conn), orchestrator_agent_id: api_key.agent_id)

    case Progress.verify_story(tenant_id, story_id, params, opts) do
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
    opts = Keyword.merge(AuditContext.from_conn(conn), orchestrator_agent_id: api_key.agent_id)

    case Progress.reject_story(tenant_id, story_id, params, opts) do
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
  GET /api/v1/stories/:story_id/verifications

  Lists verification results for a story with pagination.
  """
  def index(conn, %{"story_id" => story_id} = params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with {:ok, _story} <- Stories.get_story(tenant_id, story_id) do
      opts =
        []
        |> maybe_add_opt(:page, parse_int(params["page"]))
        |> maybe_add_opt(:page_size, parse_int(params["page_size"]))

      {:ok, result} = Artifacts.list_verifications(tenant_id, story_id, opts)

      json(conn, %{
        data: result.data,
        meta: %{
          page: result.page,
          page_size: result.page_size,
          total_count: result.total,
          total_pages: ceil_div(result.total, result.page_size)
        }
      })
    end
  end

  # --- Private helpers ---

  defp parse_int(nil), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp ceil_div(numerator, denominator), do: ceil(numerator / denominator)

  @doc """
  POST /api/v1/stories/:id/force-unclaim

  Orchestrator force-unclaims a story, resetting it to pending.
  Idempotent on already-pending stories. Does NOT reset verified_status.
  """
  def force_unclaim(conn, %{"id" => story_id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    opts = Keyword.merge(AuditContext.from_conn(conn), orchestrator_agent_id: api_key.agent_id)

    case Progress.force_unclaim_story(tenant_id, story_id, opts) do
      {:ok, story} ->
        json(conn, %{story: story})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end
end
