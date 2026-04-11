defmodule LoopctlWeb.ReviewRecordController do
  @moduledoc """
  Controller for recording that an independent review was completed for a story.

  The review pipeline calls POST /stories/:id/review-complete after running
  its review process. This creates a review_record that verify_story/4 then
  checks for before allowing verification to proceed.

  This separates the enforcement mechanism from the verify endpoint: the review
  record is structural proof that a review happened, not just a string claim.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.Agents
  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Progress
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole,
       [exact_role: [:orchestrator, :user]] when action in [:create]

  tags(["Progress"])

  operation(:create,
    summary: "Record review completion",
    description:
      "Records that the review pipeline completed for a story. " <>
        "Must be called AFTER the story is in reported_done status and BEFORE verify. " <>
        "Creates a review_record that verify uses as proof of independent review.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    request_body:
      {"Review completion params", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:review_type],
         properties: %{
           review_type: %OpenApiSpex.Schema{
             type: :string,
             description: "Type of review conducted",
             example: "enhanced"
           },
           findings_count: %OpenApiSpex.Schema{
             type: :integer,
             description: "Number of findings identified",
             example: 5
           },
           fixes_count: %OpenApiSpex.Schema{
             type: :integer,
             description: "Number of findings that were fixed",
             example: 5
           },
           disproved_count: %OpenApiSpex.Schema{
             type: :integer,
             description:
               "Number of findings disproved as false positives. fixes_count + disproved_count must equal findings_count.",
             example: 0
           },
           summary: %OpenApiSpex.Schema{
             type: :string,
             description: "Summary of review findings and outcome",
             example: "Enhanced review completed. 5 findings, all fixed."
           },
           completed_at: %OpenApiSpex.Schema{
             type: :string,
             format: :"date-time",
             description:
               "When the review completed (defaults to now). Must be after reported_done_at.",
             example: "2026-03-30T01:44:41Z"
           },
           reviewer_agent_id: %OpenApiSpex.Schema{
             type: :string,
             format: :uuid,
             description:
               "Optional explicit reviewer agent id. Required when the calling API key " <>
                 "does not have an agent_id set (e.g., user-role keys recording a manual " <>
                 "review on behalf of a human reviewer). Must belong to the caller's tenant " <>
                 "and must differ from the story's assigned implementer. When the caller's " <>
                 "API key already has an agent_id, this field defaults to that value and " <>
                 "must not be set to the same value explicitly.",
             example: "09429bc4-1234-5678-90ab-cdef12345678"
           }
         }
       }},
    responses: %{
      201 => {"Review recorded", "application/json", Schemas.ReviewRecordResponse},
      404 => {"Story not found", "application/json", Schemas.ErrorResponse},
      422 => {"Story not in reported_done status", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc """
  POST /api/v1/stories/:id/review-complete

  Records that the review pipeline completed for a story. The review_record
  created here is what verify_story/4 checks before allowing verification.
  """
  def create(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    # Determine the reviewer agent id:
    #   - Prefer the explicit body param if provided. This is the path for
    #     user-role keys that don't have an agent_id of their own (e.g.,
    #     a human admin recording a manual review by a specific agent).
    #   - Fall back to the caller's own agent_id.
    #   - Reject if neither is available — reviews must always be attributable.
    body_reviewer_id = params["reviewer_agent_id"]
    reviewer_agent_id = body_reviewer_id || api_key.agent_id

    with :ok <- validate_reviewer_identity_present(reviewer_agent_id),
         :ok <- validate_reviewer_tenant(tenant_id, reviewer_agent_id),
         :ok <- validate_reviewer_not_self_via_body(api_key, body_reviewer_id) do
      do_create_review(conn, tenant_id, reviewer_agent_id, story_id, params)
    end
  end

  # Every review_complete call must have an attributable reviewer agent id.
  # This eliminates the nil-bypass where a user-role key with no agent_id
  # could record a review without ever triggering the self-review check.
  defp validate_reviewer_identity_present(nil) do
    {:error, :unprocessable_entity,
     "reviewer_agent_id is required. Provide it in the request body or " <>
       "authenticate with a key that has an agent_id set."}
  end

  defp validate_reviewer_identity_present(_), do: :ok

  # The declared reviewer agent id must belong to the caller's tenant.
  # This prevents a caller from claiming a review by an agent from another
  # tenant (which would both 404 at read time AND pollute the review record).
  defp validate_reviewer_tenant(tenant_id, reviewer_agent_id) do
    case Agents.get_agent(tenant_id, reviewer_agent_id) do
      {:ok, _agent} ->
        :ok

      {:error, :not_found} ->
        {:error, :unprocessable_entity,
         "reviewer_agent_id not found in tenant. The declared reviewer must " <>
           "be an existing agent in the current tenant."}
    end
  end

  # When a caller passes reviewer_agent_id in the body AND has their own
  # agent_id on the key, the body value must not equal the caller's own
  # agent — that's bypass theater ("I'm reviewing this, but I'm also the
  # same agent that implemented it").
  defp validate_reviewer_not_self_via_body(%{agent_id: caller_agent_id}, body_reviewer_id)
       when not is_nil(caller_agent_id) and not is_nil(body_reviewer_id) and
              caller_agent_id == body_reviewer_id do
    {:error, :unprocessable_entity,
     "reviewer_agent_id in request body must not match the caller's own agent_id. " <>
       "Use a different agent or authenticate as that agent directly."}
  end

  defp validate_reviewer_not_self_via_body(_api_key, _body_reviewer_id), do: :ok

  defp do_create_review(conn, tenant_id, reviewer_agent_id, story_id, params) do
    opts =
      AuditContext.from_conn(conn)
      |> Keyword.put(:reviewer_agent_id, reviewer_agent_id)

    case Progress.record_review(tenant_id, story_id, params, opts) do
      {:ok, review_record} ->
        conn
        |> put_status(:created)
        |> json(%{review_record: review_record})

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :story_not_reported_done} ->
        {:error, :story_not_reported_done}

      {:error, :self_review_blocked} ->
        {:error, :self_review_blocked}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end
end
