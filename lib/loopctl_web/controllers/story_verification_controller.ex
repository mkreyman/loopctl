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
       [role: :orchestrator] when action in [:index, :backfill]

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

  operation(:backfill,
    summary: "Backfill verified status",
    description:
      "Marks a story as verified for work completed outside loopctl (e.g. before onboarding). " <>
        "Only permitted for stories that never entered loopctl's dispatch lifecycle — " <>
        "stories with `assigned_agent_id` set, or already `:verified`/`:rejected`, are refused. " <>
        "Requires a non-empty `reason`; `evidence_url` and `pr_number` are optional but strongly recommended. " <>
        "Emits a `story.backfilled` webhook event on success.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    request_body:
      {"Backfill params", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:reason],
         properties: %{
           reason: %OpenApiSpex.Schema{type: :string},
           evidence_url: %OpenApiSpex.Schema{type: :string, nullable: true},
           pr_number: %OpenApiSpex.Schema{type: :integer, nullable: true}
         }
       }},
    responses: %{
      200 => {"Story backfilled", "application/json", Schemas.StoryStatusResponse},
      403 =>
        {"Insufficient role (orchestrator+ required)", "application/json", Schemas.ErrorResponse},
      404 => {"Story not found", "application/json", Schemas.ErrorResponse},
      422 =>
        {"Validation error: missing reason, already verified, already rejected, or has dispatch lineage",
         "application/json", Schemas.ErrorResponse},
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

        {:error, :missing_capability} ->
          {:error, :missing_capability}

        {:error, {:invalid_transition, _ctx} = err} ->
          {:error, err}

        {:error, :invalid_transition} ->
          {:error, :conflict}

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, other} ->
          {:error, other}
      end
    end
  end

  @doc """
  POST /api/v1/stories/:id/backfill

  Marks a story as verified for work completed outside loopctl. Bypasses the
  usual contract/claim/report/review/verify lifecycle because there is no
  agent dispatch to enforce chain-of-custody against. The provenance is
  recorded in `metadata.backfill` and in an audit event so the trust chain
  remains legible.

  Requires a non-empty `reason`. Evidence (`evidence_url`, `pr_number`) is
  optional but strongly recommended.
  """
  def backfill(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    opts = AuditContext.from_conn(conn)

    case Progress.backfill_story(tenant_id, story_id, params, opts) do
      {:ok, story} ->
        json(conn, %{story: story})

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}

      {:error, atom} when is_atom(atom) ->
        {:error, :unprocessable_entity, backfill_error_message(atom)}
    end
  end

  defp backfill_error_message(:reason_required) do
    "`reason` is required and cannot be blank. " <>
      "Describe why this story is being backfilled (e.g. 'completed before loopctl onboarding, see PR #232')."
  end

  defp backfill_error_message(:reason_too_long), do: "`reason` must be <= 2000 characters."

  defp backfill_error_message(:invalid_pr_number),
    do: "`pr_number` must be a positive integer or a numeric string."

  defp backfill_error_message(:invalid_evidence_url) do
    "`evidence_url` must be an http(s):// URL without credentials in the userinfo segment."
  end

  defp backfill_error_message(:evidence_url_too_long),
    do: "`evidence_url` must be <= 2000 characters."

  defp backfill_error_message(:already_verified) do
    "Story is already verified and the previous backfill metadata differs from this request. " <>
      "If this is a retry of a different backfill, nothing further is needed; otherwise " <>
      "investigate who verified the story and why."
  end

  defp backfill_error_message(:story_rejected) do
    "Story is in `verified_status=:rejected`. Backfill refuses to overwrite a rejection. " <>
      "Investigate the rejection reason in the audit trail, and if the rejection was wrong, " <>
      "create a new story to track the corrected work."
  end

  defp backfill_error_message(:story_has_dispatch_lineage) do
    "Story has loopctl dispatch lineage (non-pending agent_status, assigned_agent_id, " <>
      "implementer_dispatch_id, or verifier_dispatch_id is set). " <>
      "Backfill is only for work completed OUTSIDE the loopctl dispatch lifecycle. " <>
      "Use the normal report_story → review_complete → verify_story flow instead."
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
