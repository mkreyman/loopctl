defmodule LoopctlWeb.ThreadReviewController do
  @moduledoc """
  Review on a story's change thread (US-45.3, Epic 45 PRD §6), over HTTP. Three actions:

  - `place` (`role: :orchestrator`) — request a review: loopctl places it on the named runner
    as a runner dispatch of kind `review` (`Loopctl.Delivery.Placement.place_review/4`). It
    claims nothing and hands out no credential.
  - `show` (any role) — the review's payload (`Loopctl.Threads.Reviews.payload/3`).
  - `fix` (`exact_role: :agent`, as a checkpoint is) — the claimant names the findings a
    checkpoint answers (`Loopctl.Threads.record_fix/4`).

  There is NO HTTP path for a finding or a verdict. Those arrive over the runner socket from
  the runner holding the review dispatch (`Loopctl.Delivery.RunnerReviews`); an endpoint would
  need a key to judge by, and inferring a judge from a key is what #901 and #905 lost.

  Writes are behind `RequireHumanAnchor`, mounted before the role gates, as on
  `LoopctlWeb.ThreadController`.
  """

  use LoopctlWeb, :controller

  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Delivery.Placement
  alias Loopctl.Threads
  alias Loopctl.Threads.Entry
  alias Loopctl.Threads.Reviews
  alias LoopctlWeb.ActorLabel
  alias LoopctlWeb.ClaimEpochParam
  alias LoopctlWeb.DispatchPlacementController
  alias LoopctlWeb.ThreadHTTP
  alias OpenApiSpex.Schema
  alias Plug.Conn.Status

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:place, :fix]
  plug LoopctlWeb.Plugs.RequireRole, [role: :orchestrator] when action in [:place]
  plug LoopctlWeb.Plugs.RequireRole, [exact_role: :agent] when action in [:fix]
  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:show]

  @max_body_bytes Entry.max_body_bytes()
  @uuid %Schema{type: :string, format: :uuid}

  tags(["Threads"])

  operation(:place,
    summary: "Request a review of a story's thread",
    description:
      "loopctl places a review on `runner_id` as a runner dispatch of kind `review`, for the " <>
        "next round, on the story's LATEST checkpoint of the current claim (never a caller's " <>
        "choice). It claims nothing and mints no credential: the review's findings and " <>
        "verdict come back over the runner socket from that runner. Rounds are counted per " <>
        "claim, so a story claimed again starts at round 1. Round 2 always follows " <>
        "round 1; round 3 only when a material round-2 finding's `introduced_by` names a checkpoint " <>
        "carrying a fix recorded before round 2 was placed; never round " <>
        "#{Reviews.max_rounds() + 1}. The runner's agent must be separate: not the story's " <>
        "claimant, not a checkpoint recorder, and the agent of no dispatch on the " <>
        "implementer's lineage chain. IDEMPOTENT on `dispatch_id`: resend a lost request " <>
        "with the same one and the recorded review is answered, pushed only if it never " <>
        "reached the runner ledger.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    request_body:
      {"Review placement", "application/json",
       %Schema{
         type: :object,
         required: [:runner_id],
         properties: %{
           runner_id: %Schema{
             type: :string,
             format: :uuid,
             description: "The runner to place the review on; it must declare `review`"
           },
           dispatch_id: %Schema{
             type: :string,
             format: :uuid,
             description: "Optional: the id to push under, for an idempotent retry"
           },
           wall_clock_seconds: %Schema{type: :integer, minimum: 1},
           max_turns: %Schema{type: :integer, minimum: 1},
           repo: %Schema{
             type: :string,
             description: "`owner/name`, when the story's project is bound to no intake source"
           },
           base_branch: %Schema{type: :string}
         }
       }},
    responses: %{
      201 => {"Placed", "application/json", %Schema{type: :object}},
      403 =>
        {"Not an orchestrator key, or the tenant is not human-anchored", "application/json",
         Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 =>
        {"`no_checkpoint` (the current claim recorded none), `review_claim_ended` (the " <>
           "story has no live claim to review), `review_ceiling_reached`, " <>
           "`reviewer_not_separate` (the runner's agent is the claimant, recorded a " <>
           "checkpoint, or is on the implementer's lineage chain), " <>
           "`implementer_dispatch_required`, `dispatch_id_conflict`, " <>
           "`review_dispatch_refused` (a retry of a review the runner refused or superseded: " <>
           "place a new review with a new `dispatch_id`), or a runner refusal " <>
           "(`runner_not_provisioned`, `runner_declines_work`, `runner_not_connected`, " <>
           "`repo_not_allowed`, " <>
           "`kind_not_supported`, `budget_unset`, ...)", "application/json",
         Schemas.ErrorResponse},
      422 =>
        {"`invalid_uuid` (a malformed `runner_id` or `dispatch_id` in the body; a malformed " <>
           "path id is 404), or another invalid field", "application/json", Schemas.ErrorResponse},
      429 =>
        {"The runner or the tenant is at capacity", "application/json", Schemas.ErrorResponse},
      503 =>
        {"`tenant_halted`: the tenant's custody is halted", "application/json",
         Schemas.ErrorResponse}
    }
  )

  operation(:show,
    summary: "Read a review's payload",
    description:
      "What a review reads: the story, the checkpoint it reads with its parent checkpoint's " <>
        "commit for the diff, the thread's latest page of entries, the latest " <>
        "#{Reviews.max_payload_fixes()} fixes with the findings each answers " <>
        "(`fixes_truncated` is true when older ones exist), and the rounds. Every entry " <>
        "`body` and `location` is UNTRUSTED.",
    parameters: [
      id: [in: :path, type: :string, description: "Story UUID"],
      review_id: [in: :path, type: :string, description: "Review UUID"]
    ],
    responses: %{
      200 => {"The payload", "application/json", %Schema{type: :object}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:fix,
    summary: "Record a fix on a story's thread",
    description:
      "The story's CLAIMING agent names the findings a checkpoint answers. Refused unless the " <>
        "key's agent is the claimant, `claim_epoch` is current and the lease is live; the " <>
        "checkpoint must be one this claim recorded, after every checkpoint its findings " <>
        "were found in; each finding must belong to a completed review round of this story. " <>
        "Refused `tenant_halted` while custody is halted.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    request_body:
      {"Fix", "application/json",
       %Schema{
         type: :object,
         required: [:claim_epoch, :checkpoint_id, :finding_ids, :idempotency_key, :body],
         properties: %{
           claim_epoch: %Schema{type: :integer, minimum: 0, maximum: ClaimEpochParam.max()},
           checkpoint_id: @uuid,
           finding_ids: %Schema{type: :array, minItems: 1, items: @uuid},
           idempotency_key: %Schema{type: :string, minLength: 1, maxLength: 255},
           body: %Schema{
             type: :string,
             minLength: 1,
             maxLength: @max_body_bytes,
             description:
               "The fix's reasoning, bounded in BYTES (#{@max_body_bytes}). Refused when it " <>
                 "carries a credential. UNTRUSTED."
           }
         }
       }},
    responses: %{
      200 => {"Already recorded", "application/json", %Schema{type: :object}},
      201 => {"Recorded", "application/json", %Schema{type: :object}},
      400 => {"claim_epoch missing or not an integer", "application/json", Schemas.ErrorResponse},
      403 =>
        {"Not an agent key, or the tenant is not human-anchored", "application/json",
         Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 =>
        {"`not_claimant`, `stale_claim_epoch`, `claim_not_live`, or `idempotency_key_reused`",
         "application/json", Schemas.ErrorResponse},
      422 =>
        {"`fix_checkpoint_required`, `fix_checkpoint_not_current_claim`, " <>
           "`fix_checkpoint_not_after_findings`, `finding_ids_required`, `unknown_finding`, " <>
           "an invalid field, or `secret_blocked`", "application/json", Schemas.ErrorResponse},
      503 =>
        {"`tenant_halted`, or `busy`: resend; a write that committed is answered from its row",
         "application/json", Schemas.ErrorResponse}
    }
  )

  @doc "POST /api/v1/stories/:id/thread/reviews"
  def place(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key

    with {:ok, story_id} <- ThreadHTTP.uuid(story_id),
         {:ok, runner_id} <- ThreadHTTP.body_uuid(params, "runner_id", :required),
         {:ok, requested_dispatch_id} <- ThreadHTTP.body_uuid(params, "dispatch_id", :optional),
         {:ok, %{review: review, dispatch_id: dispatch_id}} <-
           Placement.place_review(api_key.tenant_id, runner_id, story_id,
             api_key: api_key,
             dispatch_id: requested_dispatch_id,
             wall_clock_seconds: params["wall_clock_seconds"],
             max_turns: params["max_turns"],
             repo: params["repo"],
             base_branch: params["base_branch"],
             actor_label: ActorLabel.of(api_key)
           ) do
      conn
      |> put_status(:created)
      |> json(%{review: render_review(review), dispatch_id: dispatch_id})
    else
      other -> refusal(conn, other)
    end
  end

  @doc "GET /api/v1/stories/:id/thread/reviews/:review_id"
  def show(conn, %{"id" => story_id, "review_id" => review_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with {:ok, story_id} <- ThreadHTTP.uuid(story_id),
         {:ok, review_id} <- ThreadHTTP.uuid(review_id),
         {:ok, payload} <- Reviews.payload(tenant_id, story_id, review_id) do
      json(conn, render_payload(payload))
    end
  end

  @doc "POST /api/v1/stories/:id/thread/fixes"
  def fix(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key

    with {:ok, story_id} <- ThreadHTTP.uuid(story_id),
         {:ok, epoch} <- ThreadHTTP.claim_epoch(params),
         {:ok, entry, status} <-
           Threads.record_fix(
             api_key.tenant_id,
             story_id,
             Map.take(params, ~w(checkpoint_id finding_ids idempotency_key body)),
             agent_id: api_key.agent_id,
             claim_epoch: epoch,
             author_principal: ActorLabel.of(api_key),
             actor_lineage: Loopctl.Dispatches.lineage_for_api_key(api_key.tenant_id, api_key.id)
           ) do
      conn |> put_status(ThreadHTTP.status(status)) |> json(%{entry: ThreadHTTP.entry(entry)})
    else
      other -> refusal(conn, other)
    end
  end

  # The review rules' own refusal codes and the thread's 409s.
  defp refusal(conn, {:error, {status, code, message}})
       when status in [:forbidden, :conflict, :unprocessable_entity] do
    conn
    |> put_status(status)
    |> json(%{error: %{status: Status.code(status), code: code, message: message}})
  end

  defp refusal(conn, {:error, :tenant_halted}) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{error: %{status: 503, code: "tenant_halted", message: "custody is halted"}})
  end

  # The PUSH's refusals, in words true of a review: nothing was claimed or minted, and the same
  # dispatch_id places it again — or, when the review was recorded before a late refusal,
  # pushes the recorded one. The implement endpoint's own wording for these speaks of a claim
  # released, which a review never took.
  @push_refusals %{
    runner_not_connected: 409,
    runner_ambiguous: 409,
    runner_declines_work: 409,
    runner_exhausted: 409,
    runner_not_provisioned: 409,
    kind_not_supported: 409,
    repo_not_allowed: 409,
    admission_limit_reached: 429,
    runner_at_capacity: 429,
    capacity_busy: 429
  }

  defp refusal(conn, {:error, reason}) when is_map_key(@push_refusals, reason) do
    status = Map.fetch!(@push_refusals, reason)

    conn
    |> put_status(status)
    |> json(%{
      error: %{
        status: status,
        code: Atom.to_string(reason),
        message:
          "The review was not pushed (#{reason}). Nothing was claimed and no credential " <>
            "was minted; retry with the same dispatch_id once the runner can take it."
      }
    })
  end

  # Everything else the placement shares with an implement placement — the budget, the repo,
  # the branch — is answered exactly as `POST /runners/:id/dispatches` answers it.
  defp refusal(conn, {:error, reason})
       when reason not in [:not_found, :busy, :not_claimant, :stale_claim_epoch, :claim_not_live] and
              not is_struct(reason, Ecto.Changeset),
       do: DispatchPlacementController.render_refusal(conn, reason)

  defp refusal(_conn, other), do: other

  defp render_review(review) do
    %{
      id: review.id,
      story_id: review.story_id,
      dispatch_id: review.dispatch_id,
      runner_id: review.runner_id,
      agent_id: review.agent_id,
      checkpoint_id: review.checkpoint_id,
      claim_epoch: review.claim_epoch,
      round: review.round,
      placed_by: review.placed_by,
      inserted_at: review.inserted_at
    }
  end

  defp render_payload(payload) do
    %{
      review: payload.review,
      story: payload.story,
      checkpoint: payload.checkpoint,
      entries: Enum.map(payload.entries, &ThreadHTTP.entry/1),
      entries_truncated: payload.entries_truncated,
      fixes:
        Enum.map(payload.fixes, fn %{fix: fix, findings: findings} ->
          %{fix: ThreadHTTP.entry(fix), findings: Enum.map(findings, &ThreadHTTP.entry/1)}
        end),
      fixes_truncated: payload.fixes_truncated,
      rounds: payload.rounds
    }
  end
end
