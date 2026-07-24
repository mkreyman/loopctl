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

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Dispatches
  alias Loopctl.Progress
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole,
       [exact_role: [:orchestrator, :user]] when action in [:create]

  # US-26.7.1 — work-breakdown surface requires a human-anchored tenant.
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:create]

  # LCP-1 §9.3: under the `signed` custody profile, an enrolled reviewer's claim
  # must carry a valid signature. No-op under the default `bearer` profile.
  plug LoopctlWeb.Plugs.RequireSignedClaim, [gate: "review_complete"] when action in [:create]

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
    reviewer_agent_id = api_key.agent_id
    reviewer_lineage = Dispatches.lineage_for_api_key(tenant_id, api_key.id)

    # Agent and orchestrator keys must have an agent_id set for chain-of-custody
    # enforcement. There is NO "human operator" sentinel: a user-role key with no
    # agent passes a literal nil, which Progress.validate_not_self_review/3
    # deliberately PERMITS (a human is structurally not the implementing agent).
    # This cond is the half that keeps agent/orchestrator keys from reaching that
    # permit — the exact_role plug above (which 403s agent keys outright) and the
    # Progress guard are the other two. All three must change together.
    cond do
      api_key.role in [:agent, :orchestrator] and is_nil(reviewer_agent_id) ->
        {:error, :unprocessable_entity, "Agent ID required for chain-of-custody"}

      api_key.role == :user and is_nil(reviewer_agent_id) ->
        # User-role keys represent human operators. nil reviewer_agent_id is
        # allowed because a human cannot be the same entity as the implementing
        # agent (validate_not_self_review accepts nil, gated by the controller).
        do_create_review(conn, tenant_id, nil, story_id, params, reviewer_lineage)

      true ->
        do_create_review(conn, tenant_id, reviewer_agent_id, story_id, params, reviewer_lineage)
    end
  end

  defp do_create_review(conn, tenant_id, reviewer_agent_id, story_id, params, reviewer_lineage) do
    opts =
      AuditContext.from_conn(conn)
      |> Keyword.put(:reviewer_agent_id, reviewer_agent_id)
      |> Keyword.put(:reviewer_lineage, reviewer_lineage)
      # LCP-1 §9.4: record the verified signed claim (nil under bearer) in the
      # hash-chained audit entry, atomically with the review record.
      |> Keyword.put(:custody_claim, conn.assigns[:custody_signed_claim])

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

      {:error, :unresolvable_dispatch_lineage} ->
        {:error, :unresolvable_dispatch_lineage}

      {:error, :missing_assigned_agent} ->
        {:error, :missing_assigned_agent}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end
end
