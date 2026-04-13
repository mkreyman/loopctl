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
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Artifacts
  alias Loopctl.Progress
  alias Loopctl.Verification
  alias Loopctl.WorkBreakdown.Stories
  alias Loopctl.Workers.VerificationRunnerWorker
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole,
       [exact_role: :orchestrator] when action in [:verify, :reject, :force_unclaim, :verify_all]

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :orchestrator] when action in [:index]

  tags(["Progress"])

  operation(:verify,
    summary: "Verify story",
    description:
      "Orchestrator verifies a reported_done story. Creates verification_result with result=pass. " <>
        "Requires a review_record to exist (call POST /stories/:id/review-complete first). " <>
        "The review_record must have been completed AFTER the story was reported done.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    request_body: {"Verification params", "application/json", Schemas.VerifyRequest},
    responses: %{
      200 => {"Story verified", "application/json", Schemas.StoryStatusResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 => {"Invalid transition", "application/json", Schemas.ErrorResponse},
      422 => {"No review record found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:reject,
    summary: "Reject story",
    description:
      "Orchestrator rejects a story with reason. Creates verification_result with result=fail.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    request_body: {"Rejection params", "application/json", Schemas.RejectRequest},
    responses: %{
      200 => {"Story rejected", "application/json", Schemas.StoryStatusResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 => {"Invalid transition", "application/json", Schemas.ErrorResponse},
      422 => {"Reason required", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:index,
    summary: "List verifications",
    description: "Lists verification results for a story with pagination.",
    parameters: [
      story_id: [in: :path, type: :string, description: "Story UUID"],
      page: [in: :query, type: :integer, description: "Page number"],
      page_size: [in: :query, type: :integer, description: "Items per page"]
    ],
    responses: %{
      200 =>
        {"Verification list", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array, items: Schemas.VerificationResultResponse},
             meta: Schemas.PaginationMeta
           }
         }},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:force_unclaim,
    summary: "Force unclaim story",
    description: "Orchestrator force-unclaims a story, resetting it to pending.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    responses: %{
      200 => {"Story unclaimed", "application/json", Schemas.StoryStatusResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:verify_all,
    summary: "Verify all reported-done stories in an epic",
    description:
      "Orchestrator convenience endpoint that verifies all stories in the epic " <>
        "that have agent_status=reported_done and verified_status=unverified. " <>
        "Requires review_type and summary in the body (same as single verify). " <>
        "Returns count of verified stories and any errors.",
    parameters: [id: [in: :path, type: :string, description: "Epic UUID"]],
    request_body: {"Verification params", "application/json", Schemas.VerifyRequest},
    responses: %{
      200 =>
        {"Verify-all result", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             verified_count: %OpenApiSpex.Schema{type: :integer, example: 5},
             skipped_count: %OpenApiSpex.Schema{type: :integer, example: 0},
             total_eligible: %OpenApiSpex.Schema{type: :integer, example: 5},
             errors: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}}
           }
         }},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc """
  POST /api/v1/stories/:id/verify

  Orchestrator verifies a story. Creates a verification_result with result=pass.
  """
  def verify(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key

    with :ok <- validate_orchestrator_agent_linked(api_key) do
      tenant_id = api_key.tenant_id
      opts = Keyword.merge(AuditContext.from_conn(conn), orchestrator_agent_id: api_key.agent_id)

      case Progress.verify_story(tenant_id, story_id, params, opts) do
        {:ok, story} ->
          run_id = enqueue_verification_run(tenant_id, story_id, params)

          conn
          |> put_status(:accepted)
          |> json(%{
            status: "verification_pending",
            run_id: run_id,
            story: story,
            next_action: %{
              description: "Poll GET /api/v1/stories/#{story_id}/verifications for results",
              learn_more: "https://loopctl.com/wiki/verification-runs"
            }
          })

        {:error, :self_verify_blocked} ->
          {:error, :self_verify_blocked}

        {:error, :review_not_conducted} ->
          {:error, :review_not_conducted}

        {:error, {:invalid_transition, _ctx} = err} ->
          {:error, err}

        {:error, :invalid_transition} ->
          {:error, :conflict}

        {:error, :not_found} ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  POST /api/v1/stories/:id/reject

  Orchestrator rejects a story. Requires a non-empty reason.
  Creates a verification_result with result=fail.
  """
  def reject(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key

    with :ok <- validate_orchestrator_agent_linked(api_key) do
      tenant_id = api_key.tenant_id
      opts = Keyword.merge(AuditContext.from_conn(conn), orchestrator_agent_id: api_key.agent_id)

      case Progress.reject_story(tenant_id, story_id, params, opts) do
        {:ok, story} ->
          json(conn, %{story: story})

        {:error, :self_verify_blocked} ->
          {:error, :self_verify_blocked}

        {:error, :reason_required} ->
          {:error, :unprocessable_entity, "reason is required and cannot be blank"}

        {:error, {:invalid_transition, _ctx} = err} ->
          {:error, err}

        {:error, :invalid_transition} ->
          {:error, :conflict}

        {:error, :not_found} ->
          {:error, :not_found}
      end
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

    with :ok <- validate_orchestrator_agent_linked(api_key) do
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

  @doc """
  POST /api/v1/epics/:id/verify-all

  Orchestrator bulk-verifies all reported_done, unverified stories in an epic.
  Requires review_type and summary in the body.
  """
  def verify_all(conn, %{"id" => epic_id} = params) do
    api_key = conn.assigns.current_api_key

    with :ok <- validate_orchestrator_agent_linked(api_key) do
      tenant_id = api_key.tenant_id
      opts = Keyword.merge(AuditContext.from_conn(conn), orchestrator_agent_id: api_key.agent_id)

      {:ok, result} = Progress.verify_all_in_epic(tenant_id, epic_id, params, opts)
      json(conn, result)
    end
  end

  defp validate_orchestrator_agent_linked(%{agent_id: nil}) do
    {:error, :bad_request,
     "Orchestrator API key must be linked to a registered agent. " <>
       "Create an agent with agent_type: orchestrator first, " <>
       "then create an API key with agent_id set."}
  end

  defp validate_orchestrator_agent_linked(_api_key), do: :ok

  # US-26.4.4.1: enqueue a verification_run and return the run_id
  defp enqueue_verification_run(tenant_id, story_id, params) do
    attrs = %{
      commit_sha: Map.get(params, "commit_sha"),
      runner_type: "ci_github"
    }

    case Verification.create_run(tenant_id, story_id, attrs) do
      {:ok, run} ->
        %{"run_id" => run.id, "tenant_id" => tenant_id}
        |> VerificationRunnerWorker.new()
        |> Oban.insert()

        run.id

      _ ->
        nil
    end
  end
end
