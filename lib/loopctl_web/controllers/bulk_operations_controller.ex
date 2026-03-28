defmodule LoopctlWeb.BulkOperationsController do
  @moduledoc """
  Controller for bulk story operations.

  - `POST /api/v1/stories/bulk/claim` -- agent claims multiple stories
  - `POST /api/v1/stories/bulk/verify` -- orchestrator verifies multiple stories
  - `POST /api/v1/stories/bulk/reject` -- orchestrator rejects multiple stories

  All endpoints use partial-success semantics and return per-story results.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.BulkOperations
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [exact_role: :agent] when action in [:claim]
  plug LoopctlWeb.Plugs.RequireRole, [exact_role: :orchestrator] when action in [:verify, :reject]

  tags(["Progress"])

  operation(:claim,
    summary: "Bulk claim stories",
    description: "Agent claims multiple pending stories. Partial-success semantics.",
    request_body: {"Claim params", "application/json", Schemas.BulkClaimRequest},
    responses: %{
      200 => {"Results", "application/json", Schemas.BulkResultResponse},
      422 => {"Invalid input", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:verify,
    summary: "Bulk verify stories",
    description: "Orchestrator verifies multiple reported_done stories.",
    request_body: {"Verify params", "application/json", Schemas.BulkVerifyRequest},
    responses: %{
      200 => {"Results", "application/json", Schemas.BulkResultResponse},
      422 => {"Invalid input", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:reject,
    summary: "Bulk reject stories",
    description: "Orchestrator rejects multiple stories with reasons.",
    request_body: {"Reject params", "application/json", Schemas.BulkRejectRequest},
    responses: %{
      200 => {"Results", "application/json", Schemas.BulkResultResponse},
      422 => {"Invalid input", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc """
  POST /api/v1/stories/bulk/claim

  Agent claims multiple pending stories.
  """
  def claim(conn, %{"story_ids" => story_ids}) when is_list(story_ids) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    agent_id = api_key.agent_id
    audit_opts = AuditContext.from_conn(conn)

    case BulkOperations.bulk_claim(tenant_id, story_ids, agent_id, audit_opts) do
      {:ok, results} ->
        respond_with_results(conn, results)

      {:error, :empty_batch} ->
        {:error, :unprocessable_entity, "story_ids must not be empty"}

      {:error, :batch_too_large} ->
        {:error, :unprocessable_entity, "Maximum batch size is 50 stories"}
    end
  end

  def claim(_conn, _params) do
    {:error, :unprocessable_entity, "story_ids is required and must be an array"}
  end

  @doc """
  POST /api/v1/stories/bulk/verify

  Orchestrator verifies multiple reported_done stories.
  """
  def verify(conn, %{"stories" => stories}) when is_list(stories) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    orchestrator_agent_id = api_key.agent_id
    audit_opts = AuditContext.from_conn(conn)

    case BulkOperations.bulk_verify(tenant_id, stories, orchestrator_agent_id, audit_opts) do
      {:ok, results} ->
        respond_with_results(conn, results)

      {:error, :empty_batch} ->
        {:error, :unprocessable_entity, "stories must not be empty"}

      {:error, :batch_too_large} ->
        {:error, :unprocessable_entity, "Maximum batch size is 50 stories"}
    end
  end

  def verify(_conn, _params) do
    {:error, :unprocessable_entity, "stories is required and must be an array"}
  end

  @doc """
  POST /api/v1/stories/bulk/reject

  Orchestrator rejects multiple stories with reasons.
  """
  def reject(conn, %{"stories" => stories}) when is_list(stories) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    orchestrator_agent_id = api_key.agent_id
    audit_opts = AuditContext.from_conn(conn)

    case BulkOperations.bulk_reject(tenant_id, stories, orchestrator_agent_id, audit_opts) do
      {:ok, results} ->
        respond_with_results(conn, results)

      {:error, :empty_batch} ->
        {:error, :unprocessable_entity, "stories must not be empty"}

      {:error, :batch_too_large} ->
        {:error, :unprocessable_entity, "Maximum batch size is 50 stories"}
    end
  end

  def reject(_conn, _params) do
    {:error, :unprocessable_entity, "stories is required and must be an array"}
  end

  # --- Private helpers ---

  defp respond_with_results(conn, results) do
    has_success = Enum.any?(results, &(&1.status == "success"))
    has_error = Enum.any?(results, &(&1.status == "error"))

    # Clean results for JSON serialization (remove Story structs)
    clean_results =
      Enum.map(results, fn result ->
        result
        |> Map.delete(:story)
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
      end)

    cond do
      has_success ->
        json(conn, %{results: clean_results})

      has_error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{results: clean_results})

      true ->
        json(conn, %{results: clean_results})
    end
  end
end
