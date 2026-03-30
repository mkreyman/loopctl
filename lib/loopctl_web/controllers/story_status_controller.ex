defmodule LoopctlWeb.StoryStatusController do
  @moduledoc """
  Controller for agent status transitions on stories.

  Implements the agent side of the two-tier trust model:
  - POST /stories/:id/contract -- acknowledge ACs (pending -> contracted)
  - POST /stories/:id/claim -- claim story (contracted -> assigned)
  - POST /stories/:id/start -- begin work (assigned -> implementing)
  - POST /stories/:id/request-review -- signal implementation ready for review
  - POST /stories/:id/report -- report done (implementing -> reported_done)
    (chain-of-custody: caller must be a DIFFERENT agent from the implementer)
  - POST /stories/:id/unclaim -- release story (any -> pending)
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Progress
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole,
       [exact_role: [:agent, :orchestrator]] when action in [:contract]

  plug LoopctlWeb.Plugs.RequireRole,
       [exact_role: [:agent, :orchestrator]] when action in [:report]

  plug LoopctlWeb.Plugs.RequireRole,
       [exact_role: :agent] when action in [:claim, :start, :request_review, :unclaim]

  tags(["Progress"])

  operation(:contract,
    summary: "Contract story",
    description:
      "Agent acknowledges the story's acceptance criteria. " <>
        "Transitions pending -> contracted.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    request_body: {"Contract params", "application/json", Schemas.ContractRequest},
    responses: %{
      200 => {"Story contracted", "application/json", Schemas.StoryStatusResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 => {"Invalid transition", "application/json", Schemas.ErrorResponse},
      422 => {"Mismatch", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:claim,
    summary: "Claim story",
    description: "Agent claims a contracted story. Uses pessimistic locking.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    responses: %{
      200 => {"Story claimed", "application/json", Schemas.StoryStatusResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 =>
        {"Invalid transition or dependencies not met", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:start,
    summary: "Start story",
    description: "Agent starts work on an assigned story.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    responses: %{
      200 => {"Story started", "application/json", Schemas.StoryStatusResponse},
      403 => {"Not assigned agent", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 => {"Invalid transition", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:request_review,
    summary: "Request review",
    description:
      "Assigned agent signals that implementation is complete and ready for review. " <>
        "Does NOT change status. Fires a story.review_requested webhook event.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    responses: %{
      200 => {"Review requested", "application/json", Schemas.StoryStatusResponse},
      403 => {"Not assigned agent", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 => {"Story not in implementing status", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:report,
    summary: "Report story done",
    description:
      "A DIFFERENT agent (reviewer) reports story as done. " <>
        "The implementing agent cannot call this (chain-of-custody). " <>
        "Optionally includes an artifact report.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    request_body:
      {"Report params (optional artifact)", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           artifact: %OpenApiSpex.Schema{
             type: :object,
             properties: %{
               artifact_type: %OpenApiSpex.Schema{type: :string},
               path: %OpenApiSpex.Schema{type: :string},
               exists: %OpenApiSpex.Schema{type: :boolean},
               details: %OpenApiSpex.Schema{type: :object, additionalProperties: true}
             }
           }
         }
       }},
    responses: %{
      200 => {"Story reported done", "application/json", Schemas.StoryStatusResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 =>
        {"Invalid transition or self-report blocked", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:unclaim,
    summary: "Unclaim story",
    description: "Agent releases a story back to pending.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    responses: %{
      200 => {"Story unclaimed", "application/json", Schemas.StoryStatusResponse},
      403 => {"Not assigned agent", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 => {"Invalid transition", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc """
  POST /api/v1/stories/:id/contract

  Agent acknowledges the story's acceptance criteria.
  Request body must include story_title and ac_count matching the actual story.
  """
  def contract(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    skip_check = api_key.role in [:orchestrator, :admin]

    opts =
      AuditContext.from_conn(conn)
      |> Keyword.merge(agent_id: api_key.agent_id)
      |> Keyword.put(:skip_contract_check, skip_check)

    case Progress.contract_story(tenant_id, story_id, params, opts) do
      {:ok, story} ->
        json(conn, %{story: story})

      {:error, :title_mismatch} ->
        {:error, :unprocessable_entity, "story_title does not match"}

      {:error, {:contract_mismatch, _ctx} = err} ->
        {:error, err}

      {:error, {:invalid_transition, _ctx} = err} ->
        {:error, err}

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
    opts = Keyword.merge(AuditContext.from_conn(conn), agent_id: api_key.agent_id)

    case Progress.claim_story(tenant_id, story_id, opts) do
      {:ok, story} ->
        json(conn, %{story: story})

      {:error, :must_contract_first} ->
        {:error, :must_contract_first}

      {:error, {:invalid_transition, _ctx} = err} ->
        {:error, err}

      {:error, :invalid_transition} ->
        {:error, :conflict}

      {:error, :dependencies_not_met} ->
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
    opts = Keyword.merge(AuditContext.from_conn(conn), agent_id: api_key.agent_id)

    case Progress.start_story(tenant_id, story_id, opts) do
      {:ok, story} ->
        json(conn, %{story: story})

      {:error, :not_assigned_agent} ->
        {:error, :forbidden}

      {:error, :must_contract_first} ->
        {:error, :must_contract_first}

      {:error, :must_claim_first} ->
        {:error, :must_claim_first}

      {:error, {:invalid_transition, _ctx} = err} ->
        {:error, err}

      {:error, :invalid_transition} ->
        {:error, :conflict}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  POST /api/v1/stories/:id/request-review

  Assigned agent signals that implementation is complete and ready for review.
  Fires a story.review_requested webhook event without changing status.
  """
  def request_review(conn, %{"id" => story_id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    opts = Keyword.merge(AuditContext.from_conn(conn), agent_id: api_key.agent_id)

    case Progress.request_review(tenant_id, story_id, opts) do
      {:ok, story} ->
        json(conn, %{story: story})

      {:error, :not_assigned_agent} ->
        {:error, :forbidden}

      {:error, {:invalid_transition, _ctx} = err} ->
        {:error, err}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  POST /api/v1/stories/:id/report

  A DIFFERENT agent (reviewer) confirms that the implementation is done.
  Chain-of-custody: the implementing agent cannot report their own work.
  Optionally includes an artifact report.
  """
  def report(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    opts = Keyword.merge(AuditContext.from_conn(conn), agent_id: api_key.agent_id)
    artifact_params = extract_artifact_params(params)

    case Progress.report_story(tenant_id, story_id, opts, artifact_params) do
      {:ok, story} ->
        json(conn, %{story: story})

      {:error, :self_report_blocked} ->
        {:error, :self_report_blocked}

      {:error, {:invalid_transition, _ctx} = err} ->
        {:error, err}

      {:error, :invalid_transition} ->
        {:error, :conflict}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  POST /api/v1/stories/:id/unclaim

  Agent releases a story back to pending.
  """
  def unclaim(conn, %{"id" => story_id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    opts = Keyword.merge(AuditContext.from_conn(conn), agent_id: api_key.agent_id)

    case Progress.unclaim_story(tenant_id, story_id, opts) do
      {:ok, story} ->
        json(conn, %{story: story})

      {:error, :not_assigned_agent} ->
        {:error, :forbidden}

      {:error, :not_assigned_to_you} ->
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
