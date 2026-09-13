defmodule LoopctlWeb.StoryEscalationController do
  @moduledoc """
  `POST /api/v1/stories/:id/escalate` — the claiming agent asks for a human (issue #803,
  design §8).

  The reasoning for the gate, the fence and the idempotence is in
  `Loopctl.Delivery.Escalations`, which this controller is a thin HTTP shell over. Two things
  belong here rather than there:

  - `exact_role: :agent`, the same gate `claim`/`start`/`unclaim` carry. NEVER `role:` — with
    the hierarchy applied, an orchestrator or a `:user` key could raise an escalation, and
    the human key that RESOLVES one (`:human_resolution`) would then be able to manufacture
    the escalation it resolves. `exact_role` is what keeps those two principals apart.
  - `RequireHumanAnchor`, because a story is work-breakdown data and the whole surface is
    behind it.
  """

  use LoopctlWeb, :controller

  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Delivery.Escalations
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Dispatches

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [exact_role: :agent] when action in [:escalate]
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:escalate]

  # Counted in CODEPOINTS the way Postgres counts it (see `codepoints/1`), and read from
  # `Loopctl.Delivery.StageMachine`, the ONE place the bound is declared (#824 round 2).
  @max_reason_length StageMachine.max_reason_length()

  tags(["Progress"])

  operation(:escalate,
    summary: "Escalate a story to a human",
    description:
      "The story's CLAIMING agent parks the story at the `escalated` delivery stage and " <>
        "stops. This is the affordance an unattended session has instead of a question: a " <>
        "headless run has no AskUserQuestion at all, and nothing fires when the model " <>
        "wanted to ask, so the session must be able to DO something. Only a human " <>
        "principal moves the story off `escalated` afterwards — a role of at least `user` " <>
        "on a key no dispatch minted — so a session cannot escalate and then resolve its " <>
        "own escalation.\n\n" <>
        "Requires the `claim_epoch` the claim returned, and refuses a caller that is not " <>
        "the story's assigned agent. IDEMPOTENT: repeating the call on a story already " <>
        "escalated under the SAME epoch returns the same stage row, writes no second audit " <>
        "chain entry and counts no second attempt.\n\n" <>
        "`reason` is recorded verbatim and is UNTRUSTED session-authored text: it is " <>
        "capped at #{@max_reason_length} codepoints, never executed, and fenced as " <>
        "untrusted data wherever it reaches a prompt. `payload` is an optional structured " <>
        "map recorded on the stage event only — it never lands on the story or on the " <>
        "audit chain — and is capped at 8000 bytes encoded.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    request_body:
      {"Escalation params", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:claim_epoch, :reason],
         properties: %{
           claim_epoch: %OpenApiSpex.Schema{
             type: :integer,
             minimum: 0,
             description:
               "The `claim_epoch` the story's claim returned. Not the current epoch means " <>
                 "the claim has ended: 409 `stale_claim_epoch`."
           },
           reason: %OpenApiSpex.Schema{
             type: :string,
             minLength: 1,
             maxLength: @max_reason_length,
             description:
               "Why a human is needed, in the session's own words. Recorded verbatim, " <>
                 "capped at #{@max_reason_length} CODEPOINTS (what Postgres counts, not " <>
                 "graphemes — an emoji family is one grapheme and several codepoints), " <>
                 "never executed. Over the bound is a 400."
           },
           payload: %OpenApiSpex.Schema{
             type: :object,
             additionalProperties: true,
             description:
               "Optional structured detail recorded on the story's stage event. At most " <>
                 "8000 bytes once encoded, and no NUL in any key or value."
           }
         }
       }},
    responses: %{
      200 =>
        {"The story's stage row, at `escalated`", "application/json", Schemas.StoryStageResponse},
      400 =>
        {"claim_epoch or reason missing or malformed", "application/json", Schemas.ErrorResponse},
      403 =>
        {"Not an agent key, or the tenant is not human-anchored", "application/json",
         Schemas.ErrorResponse},
      404 =>
        {"No such story, or it has no delivery stage row", "application/json",
         Schemas.ErrorResponse},
      409 =>
        {"stale_claim_epoch, not_claimant, or stale_stage", "application/json",
         Schemas.ErrorResponse},
      422 => {"The reason or payload was refused", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      500 =>
        {"The transition's audit-chain entry did not land, so nothing was written",
         "application/json", Schemas.ErrorResponse},
      503 =>
        {"A lock the write needed was not free; nothing was written", "application/json",
         Schemas.ErrorResponse}
    }
  )

  @doc "POST /api/v1/stories/:id/escalate"
  def escalate(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    with {:ok, epoch} <- claim_epoch(params),
         {:ok, reason} <- reason(params),
         {:ok, payload} <- payload(params),
         {:ok, row} <-
           Escalations.escalate(tenant_id, story_id,
             claim_epoch: epoch,
             agent_id: api_key.agent_id,
             reason: reason,
             payload: payload,
             actor_label: actor_label(api_key),
             # SERVER-resolved from the authenticating key, never taken from the body: a
             # self-attested lineage would let a caller write a custody chain entry naming a
             # dispatch it does not hold. Entering `escalated` is a chained transition, so
             # `Stages.advance/4` refuses an ABSENT lineage outright.
             actor_lineage: Dispatches.lineage_for_api_key(tenant_id, api_key.id)
           ) do
      json(conn, %{stage: render_stage(row)})
    end
  end

  defp claim_epoch(params) do
    case Map.get(params, "claim_epoch") do
      epoch when is_integer(epoch) and epoch >= 0 -> {:ok, epoch}
      _ -> {:error, :bad_request, "claim_epoch must be a non-negative integer"}
    end
  end

  # Checked here as well as in `Stages`, and deliberately: a missing reason is the caller's
  # mistake and deserves a 400 naming the field, while `Stages`' `:reason_required` is the
  # enforcement that also binds the channel path.
  defp reason(params) do
    case Map.get(params, "reason") do
      reason when is_binary(reason) ->
        if String.trim(reason) == "" or codepoints(reason) > @max_reason_length,
          do: {:error, :bad_request, reason_message()},
          else: {:ok, reason}

      _ ->
        {:error, :bad_request, reason_message()}
    end
  end

  # CODEPOINTS, which is what Postgres `char_length` counts and what the
  # `story_stages_text_bounds` CHECK bounds. `String.length/1` counts GRAPHEMES, and an emoji
  # family or a combining mark is one grapheme and several characters to Postgres — so
  # counting graphemes here let a reason past this 400 that `Loopctl.Delivery.Stages` then
  # refused as `:invalid_reason`, which had no fallback clause and answered 500.
  defp codepoints(value), do: value |> String.to_charlist() |> length()

  defp reason_message,
    do: "reason must be a non-empty string of at most #{@max_reason_length} codepoints"

  defp payload(params) do
    case Map.get(params, "payload") do
      nil -> {:ok, nil}
      payload when is_map(payload) -> {:ok, payload}
      _ -> {:error, :bad_request, "payload must be an object"}
    end
  end

  defp actor_label(%{agent_id: nil, id: key_id}), do: "api_key:" <> key_id
  defp actor_label(%{agent_id: agent_id}), do: "agent:" <> agent_id

  # The stage row as the API renders it. `escalation_reason` is the RAW text: this is a JSON
  # body for an operator or a dashboard, not a prompt, and fencing it here would hide what
  # the session actually wrote. The flag beside it is what a client acts on — a caller that
  # puts the reason in front of a model renders it through
  # `Loopctl.Delivery.Stages.escalation_block/1` first. It is a constant because the property
  # is one of the FIELD, not of any particular value: every reason is session-authored.
  defp render_stage(row) do
    %{
      story_id: row.story_id,
      stage: row.stage,
      claim_epoch: row.claim_epoch,
      lock_version: row.lock_version,
      attempts: row.attempts,
      escalation_reason: row.escalation_reason,
      escalation_reason_untrusted: true
    }
  end
end
