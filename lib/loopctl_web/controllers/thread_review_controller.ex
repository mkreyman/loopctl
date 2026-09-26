defmodule LoopctlWeb.ThreadReviewController do
  @moduledoc """
  Review on a story's change thread (US-45.3, Epic 45 PRD §6). A thin HTTP shell over
  `Loopctl.Threads.Reviews`, where the authority, the rounds and the ceiling live.

  - `place` is `role: :orchestrator`: it mints the reviewer's dispatch, as
    `POST /api/v1/dispatches` does, and returns its key once.
  - `finding` and `verdict` are `exact_role: :agent`, and the context accepts them only on the
    key a placed review dispatch minted. Every other key is refused `review_dispatch_required`,
    never `self_review_blocked`, which feeds the L6 custody halt.
  - `fix` is `exact_role: :agent`, as a checkpoint is: only the claiming agent's key.
  - The writes are behind `RequireHumanAnchor`, mounted before the role gates, as on
    `LoopctlWeb.ThreadController`. The review read is open to every role, as the thread is.
  """

  use LoopctlWeb, :controller

  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Threads.Entry
  alias Loopctl.Threads.Reviews
  alias LoopctlWeb.ClaimEpochParam
  alias OpenApiSpex.Schema
  alias Plug.Conn.Status

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:place, :finding, :verdict, :fix]
  plug LoopctlWeb.Plugs.RequireRole, [role: :orchestrator] when action in [:place]

  plug LoopctlWeb.Plugs.RequireRole,
       [exact_role: :agent] when action in [:finding, :verdict, :fix]

  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:show]

  @max_body_bytes Entry.max_body_bytes()
  @max_location_bytes Reviews.max_location_bytes()
  @severities Enum.map(Entry.severities(), &to_string/1)
  @uuid %Schema{type: :string, format: :uuid}

  @body %Schema{
    type: :string,
    minLength: 1,
    maxLength: @max_body_bytes,
    description:
      "Bounded in BYTES (#{@max_body_bytes}), so multi-byte text reaches the limit before " <>
        "maxLength's character count does. Refused when it carries a credential. UNTRUSTED."
  }

  @busy {"`busy`: a lock the write needed was held past the wait bound, or the connection " <>
           "was lost. Resend: a write that did commit is answered from its row",
         "application/json", Schemas.ErrorResponse}

  @judgement_responses %{
    200 => {"Already recorded", "application/json", %Schema{type: :object}},
    201 => {"Recorded", "application/json", %Schema{type: :object}},
    403 =>
      {"Not an agent key, the tenant is not human-anchored, or `review_dispatch_required` " <>
         "(the key was not minted by a review dispatch of this story)", "application/json",
       Schemas.ErrorResponse},
    404 => {"Not found", "application/json", Schemas.ErrorResponse},
    409 =>
      {"`review_closed` (this review recorded its verdict), `review_round_superseded` " <>
         "(another review completed this round), `reviewer_not_separate`, or " <>
         "`idempotency_key_reused`", "application/json", Schemas.ErrorResponse},
    422 =>
      {"`invalid_severity`, `invalid_location`, `introduced_by_not_allowed`, " <>
         "`introduced_by_required`, `introduced_by_invalid`, an invalid field, or " <>
         "`secret_blocked`", "application/json", Schemas.ErrorResponse},
    503 => @busy
  }

  tags(["Threads"])

  operation(:place,
    summary: "Place a review of a story's thread",
    description:
      "Mints the reviewer's dispatch as a SIBLING of the implementer's dispatch (the same " <>
        "parent), records it for the next review round, and returns its API key ONCE. " <>
        "Findings and verdicts are accepted only on that key. The round is the number of " <>
        "completed rounds plus one: round 2 is always placeable after round 1, round 3 only " <>
        "when a round-2 finding's `introduced_by` names a checkpoint a round-1 fix is " <>
        "carried by, and round #{Reviews.max_rounds() + 1} never.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    request_body:
      {"Review placement", "application/json",
       %Schema{
         type: :object,
         required: [:agent_id],
         properties: %{
           agent_id: %Schema{
             type: :string,
             format: :uuid,
             description:
               "The agent the review acts as: not the story's claimant, and not a principal " <>
                 "that recorded a checkpoint of this thread"
           },
           checkpoint_id: %Schema{
             type: :string,
             format: :uuid,
             description: "The checkpoint to review; the thread's latest when absent"
           },
           expires_in_seconds: %Schema{
             type: :integer,
             minimum: 1,
             description: "The review key's lifetime; capped at four hours"
           }
         }
       }},
    responses: %{
      201 => {"Placed. `raw_key` is shown once", "application/json", %Schema{type: :object}},
      403 =>
        {"Not an orchestrator key, the tenant is not human-anchored, " <>
           "`review_placer_on_implementer_chain` (the caller is the implementer or its " <>
           "descendant), `parent_outside_caller_lineage`, or `root_dispatch_forbidden`",
         "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 =>
        {"`implementer_dispatch_required` (no dispatch made the claim), `reviewer_not_separate` " <>
           "(the agent is the claimant or recorded a checkpoint), `no_checkpoint`, " <>
           "`review_ceiling_reached`, or `review_parent_inactive` (the implementer's parent " <>
           "dispatch is revoked or expired)", "application/json", Schemas.ErrorResponse},
      422 =>
        {"`invalid_agent_id`, `invalid_checkpoint_id`, `invalid_expires_in_seconds`, " <>
           "`unknown_agent` or `unknown_checkpoint`", "application/json", Schemas.ErrorResponse},
      503 =>
        {"`tenant_halted`: the tenant's custody is halted", "application/json",
         Schemas.ErrorResponse}
    }
  )

  operation(:show,
    summary: "Read a review's payload",
    description:
      "What the review dispatch reads: the story, the checkpoint diff reference (the " <>
        "thread branch, the checkpoint's commit and its parent checkpoint's commit), the " <>
        "thread's latest page of entries, every fix with the findings it answers, and the " <>
        "rounds. Every entry `body` is UNTRUSTED.",
    parameters: [
      id: [in: :path, type: :string, description: "Story UUID"],
      review_id: [in: :path, type: :string, description: "Review UUID"]
    ],
    responses: %{
      200 => {"The payload", "application/json", %Schema{type: :object}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:finding,
    summary: "Record a finding from a review dispatch",
    description:
      "Accepted only on the key a placed review dispatch of this story minted, and bound to " <>
        "that review and the checkpoint it reads. `introduced_by` is refused in round 1 and " <>
        "required after it: a checkpoint id of this story at or before the reviewed " <>
        "checkpoint, or `none`; it is stored canonicalised. IDEMPOTENT on `idempotency_key` " <>
        "for the same write.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    request_body:
      {"Finding", "application/json",
       %Schema{
         type: :object,
         required: [:idempotency_key, :body, :severity],
         properties: %{
           idempotency_key: %Schema{type: :string, minLength: 1, maxLength: 255},
           body: %{@body | description: "The failure scenario. " <> @body.description},
           severity: %Schema{type: :string, enum: @severities},
           location: %Schema{
             type: :string,
             maxLength: @max_location_bytes,
             description: "`file:line`, bounded in BYTES (#{@max_location_bytes})"
           },
           introduced_by: %Schema{type: :string, description: "A checkpoint id, or `none`"}
         }
       }},
    responses: @judgement_responses
  )

  operation(:verdict,
    summary: "Record a review dispatch's verdict",
    description:
      "The ONE entry that completes the review's round. Accepted only on the review " <>
        "dispatch's key, once, and only while the round before it is the last completed one. " <>
        "When the round reaches the ceiling with a critical, high or medium finding in it, " <>
        "the verdict also records a `review_ceiling` escalation and the story's delivery " <>
        "stage is escalated.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    request_body:
      {"Verdict", "application/json",
       %Schema{
         type: :object,
         required: [:idempotency_key, :body],
         properties: %{
           idempotency_key: %Schema{type: :string, minLength: 1, maxLength: 255},
           body: @body
         }
       }},
    responses: @judgement_responses
  )

  operation(:fix,
    summary: "Record a fix on a story's thread",
    description:
      "The story's CLAIMING agent names the findings a checkpoint answers. Refused unless the " <>
        "key's agent is the claimant, `claim_epoch` is current and the lease is live; the " <>
        "checkpoint must be one this claim recorded, after every checkpoint its findings " <>
        "were found in; each finding must belong to a completed review round of this story.",
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
           body: %{@body | description: "The fix's reasoning. " <> @body.description}
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
      503 => @busy
    }
  )

  @doc "POST /api/v1/stories/:id/thread/reviews"
  def place(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key

    with {:ok, story_id} <- story_uuid(story_id),
         {:ok, %{review: review, raw_key: raw_key}} <-
           Reviews.place(api_key.tenant_id, story_id, api_key,
             agent_id: params["agent_id"],
             checkpoint_id: params["checkpoint_id"],
             expires_in_seconds: params["expires_in_seconds"]
           ) do
      conn
      |> put_status(:created)
      |> json(%{review: render_review(review), raw_key: raw_key})
    else
      other -> refusal(conn, other)
    end
  end

  @doc "GET /api/v1/stories/:id/thread/reviews/:review_id"
  def show(conn, %{"id" => story_id, "review_id" => review_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with {:ok, story_id} <- story_uuid(story_id),
         {:ok, review_id} <- story_uuid(review_id),
         {:ok, payload} <- Reviews.payload(tenant_id, story_id, review_id) do
      json(conn, render_payload(payload))
    end
  end

  @doc "POST /api/v1/stories/:id/thread/findings"
  def finding(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key
    attrs = Map.take(params, ~w(idempotency_key body severity location introduced_by))

    with {:ok, story_id} <- story_uuid(story_id),
         {:ok, entry, status} <-
           Reviews.record_finding(api_key.tenant_id, story_id, api_key, attrs) do
      conn |> put_status(created_or_ok(status)) |> json(%{entry: render_entry(entry)})
    else
      other -> refusal(conn, other)
    end
  end

  @doc "POST /api/v1/stories/:id/thread/verdicts"
  def verdict(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key
    attrs = Map.take(params, ~w(idempotency_key body))

    with {:ok, story_id} <- story_uuid(story_id),
         {:ok, %{entry: entry, escalation: escalation}, status} <-
           Reviews.record_verdict(api_key.tenant_id, story_id, api_key, attrs) do
      conn
      |> put_status(created_or_ok(status))
      |> json(%{entry: render_entry(entry), escalation: escalation && render_entry(escalation)})
    else
      other -> refusal(conn, other)
    end
  end

  @doc "POST /api/v1/stories/:id/thread/fixes"
  def fix(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key

    with {:ok, story_id} <- story_uuid(story_id),
         {:ok, epoch} <- claim_epoch(params),
         attrs =
           params
           |> Map.take(~w(checkpoint_id finding_ids idempotency_key body))
           |> Map.put("claim_epoch", epoch),
         {:ok, entry, status} <- Reviews.record_fix(api_key.tenant_id, story_id, api_key, attrs) do
      conn |> put_status(created_or_ok(status)) |> json(%{entry: render_entry(entry)})
    else
      other -> refusal(conn, other)
    end
  end

  # The review path's own refusal codes. Everything else is the fallback's to render.
  defp refusal(conn, {:error, {status, code, message}})
       when status in [:forbidden, :conflict, :unprocessable_entity, :service_unavailable] do
    conn
    |> put_status(status)
    |> json(%{error: %{status: Status.code(status), code: code, message: message}})
  end

  # A halted or un-anchored tenant is refused by `Reviews.place/4` itself, as by
  # `Loopctl.Delivery.Placement`, with the codes `CheckCustodyHalt` and `RequireHumanAnchor`
  # answer on their own routes.
  defp refusal(conn, {:error, :tenant_halted}),
    do: refusal(conn, {:error, {:service_unavailable, "tenant_halted", "custody is halted"}})

  defp refusal(conn, {:error, :custody_tier_required}),
    do:
      refusal(
        conn,
        {:error, {:forbidden, "custody_tier_required", "the tenant is not human-anchored"}}
      )

  defp refusal(_conn, other), do: other

  defp story_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp claim_epoch(params) do
    case ClaimEpochParam.fetch(params) do
      {:ok, epoch} -> {:ok, epoch}
      _ -> {:error, :bad_request, "claim_epoch must be a non-negative integer"}
    end
  end

  defp created_or_ok(:created), do: :created
  defp created_or_ok(:existing), do: :ok

  defp render_review(review) do
    %{
      id: review.id,
      story_id: review.story_id,
      dispatch_id: review.dispatch_id,
      agent_id: review.agent_id,
      checkpoint_id: review.checkpoint_id,
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
      entries: Enum.map(payload.entries, &render_entry/1),
      entries_truncated: payload.entries_truncated,
      fixes:
        Enum.map(payload.fixes, fn %{fix: fix, findings: findings} ->
          %{fix: render_entry(fix), findings: Enum.map(findings, &render_entry/1)}
        end),
      rounds: payload.rounds
    }
  end

  defp render_entry(entry) do
    %{
      id: entry.id,
      seq: entry.seq,
      kind: entry.kind,
      author_principal: entry.author_principal,
      dispatch_id: entry.dispatch_id,
      idempotency_key: entry.idempotency_key,
      body: entry.body,
      body_untrusted: true,
      checkpoint_id: entry.checkpoint_id,
      review_id: entry.review_id,
      severity: entry.severity,
      location: entry.location,
      location_untrusted: true,
      introduced_by: entry.introduced_by,
      finding_ids: entry.finding_ids,
      inserted_at: entry.inserted_at
    }
  end
end
