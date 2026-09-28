defmodule LoopctlWeb.StoryStageReportController do
  @moduledoc """
  US-45.9: the CLAIMANT of an interactive thread claim reports its own story's stage
  transitions, as a runner reports a placed claim's over its socket.

  It is given exactly a runner's vocabulary and nothing more. The body is cast by the runner
  channel's own validator (`Loopctl.ApiSpec.RunnerContract.cast_stage/1`), so only
  `StageMachine.runner_transitions/0` and the reportable effects pass, and the transition is
  written by the one writer (`Loopctl.Delivery.Stages.advance/4`) under the claim's epoch.
  Before any of that the caller must be the story's claimant, under the epoch it names, with a
  live lease, on a claim whose recorded route (`Loopctl.Delivery.ClaimRoute`) is an
  interactive THREAD route. A placed claim has a runner to report for it and is refused, so
  there is never a second reporter for one claim.

  When the claim's own `queued -> claimed` did not land (a bulk claim, or the claim's attempt
  failed), the first report from `claimed` makes it first
  (`Loopctl.Delivery.InteractiveClaims.enter_claimed/3`), as control and never as the
  claimant's assertion.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.AdminRepo
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Delivery.Claimant
  alias Loopctl.Delivery.ClaimRoute
  alias Loopctl.Delivery.InteractiveClaims
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Dispatches
  alias Loopctl.WorkBreakdown.Story
  alias LoopctlWeb.AuditContext
  alias LoopctlWeb.StoryEscalationController
  alias OpenApiSpex.Schema
  alias Plug.Conn.Status

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:create]
  plug LoopctlWeb.Plugs.RequireRole, [exact_role: :agent] when action in [:create]

  tags(["Stories"])

  operation(:create,
    summary: "Report a stage transition of your own interactive thread claim",
    description:
      "US-45.9. The claimant of an INTERACTIVE claim of a thread-mode story (claimed with " <>
        "`claim_story`, not placed on a runner) reports its story's stage transitions here, " <>
        "as a runner reports a placed claim's, up to `ci`: the runner's transitions short of " <>
        "the merge (`StageMachine.claimant_reportable?/3`: loopctl records `merged` itself), " <>
        "the same reportable effects (a checkpoint's `head_sha` entering `ci`), the same " <>
        "reason rules. The body is the runner `stage` message without `dispatch_id`. " <>
        "Refused 404 for a story not in your tenant, 409 `not_claimant` for any caller but " <>
        "the claimant, 409 `stale_claim_epoch` for another claim's epoch, 409 " <>
        "`claim_not_live` for a claim that is no longer live (its lease lapsed: renew it with " <>
        "`renew_story_claim`; or it requested review), 409 " <>
        "`not_interactive_thread_claim` for a placed claim or a `pr` route, 409 `stale_stage` " <>
        "when the row is not at `from`, 409 `effect_conflict`, 422 `invalid_payload` for a " <>
        "transition or effect the claimant may not report, 503 `busy` under lock contention " <>
        "(retry). Agent-role key only.",
    parameters: [
      id: [in: :path, type: :string, description: "Story UUID", required: true]
    ],
    request_body:
      {"The transition", "application/json",
       %Schema{
         type: :object,
         required: [:claim_epoch, :from, :to],
         properties: %{
           claim_epoch: %Schema{type: :integer, minimum: 0},
           from: %Schema{type: :string},
           to: %Schema{type: :string},
           edge: %Schema{type: :string, description: "Defaults to `forward`."},
           reason: %Schema{type: :string},
           effects: %Schema{type: :object}
         }
       }},
    responses: %{
      200 => {"The story's stage row", "application/json", %Schema{type: :object}},
      404 => {"No such story in your tenant", "application/json", %Schema{type: :object}},
      409 => {"Refused", "application/json", %Schema{type: :object}},
      422 => {"Invalid payload", "application/json", %Schema{type: :object}},
      503 => {"Busy: retry", "application/json", %Schema{type: :object}}
    }
  )

  # `Stages.advance/4`'s refusals that no fallback clause renders. Every other one it can give
  # (`:stale_claim_epoch`, `:stale_stage`, `:not_found`, `:busy`,
  # `:audit_chain_append_failed`) has its clause in `LoopctlWeb.FallbackController`.
  @advance_refusals %{
    effect_conflict:
      {:conflict, "effect_conflict", "a different value is already recorded for that effect"},
    wrong_stage:
      {:conflict, "stale_stage", "that effect cannot be recorded at the story's stage"},
    invalid_reason: {:unprocessable_entity, "invalid_payload", "the reason is not acceptable"},
    invalid_effect: {:unprocessable_entity, "invalid_payload", "an effect is not acceptable"},
    missing_required_effect:
      {:unprocessable_entity, "invalid_payload", "that transition requires an effect"},
    transition_only_effect:
      {:unprocessable_entity, "invalid_payload", "that effect is written only by a transition"},
    invalid_event_data: {:unprocessable_entity, "invalid_payload", "the event data is too large"}
  }

  def create(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    with {:ok, story} <- fetch_story(tenant_id, story_id),
         :ok <- claimant(story, api_key),
         {:ok, route} <- interactive_thread_route(tenant_id, story),
         {:ok, stage} <- cast(params, route),
         :ok <- claimant_reportable(stage),
         :ok <- live_claim(story),
         {:ok, row} <- report(tenant_id, story, stage, api_key, conn) do
      json(conn, %{stage: StoryEscalationController.render_stage(row)})
    else
      {:error, {status, code, message}} -> refusal(conn, status, code, message)
      {:error, reason} when is_map_key(@advance_refusals, reason) -> advance_refusal(conn, reason)
      other -> other
    end
  end

  defp advance_refusal(conn, reason) do
    {status, code, message} = Map.fetch!(@advance_refusals, reason)
    refusal(conn, status, code, message)
  end

  defp fetch_story(tenant_id, story_id) do
    case Ecto.UUID.cast(story_id) do
      {:ok, id} ->
        case AdminRepo.get_by(Story, id: id, tenant_id: tenant_id) do
          nil -> {:error, :not_found}
          story -> {:ok, story}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp claimant(%Story{assigned_agent_id: agent_id}, %{agent_id: agent_id})
       when is_binary(agent_id),
       do: :ok

  defp claimant(_story, _api_key), do: {:error, :not_claimant}

  defp interactive_thread_route(tenant_id, story) do
    case InteractiveClaims.current_route(tenant_id, story) do
      %ClaimRoute{mode: "thread"} = route ->
        {:ok, route}

      _placed_or_pr ->
        {:error,
         {:conflict, "not_interactive_thread_claim",
          "this claim is not an interactive thread claim: a placed claim's stages are its " <>
            "runner's to report, and a pr claim has none to report here"}}
    end
  end

  # The runner channel's own validator, given the route's id as the `dispatch_id` it requires:
  # a server-chosen UUID naming this claim, never a value from the request.
  defp cast(params, route) do
    payload =
      params
      |> Map.take(["claim_epoch", "from", "to", "edge", "reason", "effects"])
      |> Map.put("dispatch_id", route.id)

    case RunnerContract.cast_stage(payload) do
      {:ok, stage} ->
        {:ok, stage}

      {:error, {:invalid, errors}} ->
        {:error, {:unprocessable_entity, "invalid_payload", Enum.join(errors, "; ")}}
    end
  end

  # The epoch is not pre-checked here: `Stages.advance/4` reads the story's epoch under its own
  # lock and refuses another claim's `:stale_claim_epoch`, and that read is the fence.

  # A runner may also report the merge and what follows it; the implementing claimant may not
  # (`StageMachine.claimant_reportable?/3`).
  defp claimant_reportable(%{from: from, to: to, edge: edge}) do
    if StageMachine.claimant_reportable?(from, to, edge),
      do: :ok,
      else:
        {:error,
         {:unprocessable_entity, "invalid_payload",
          "the claimant of a thread reports up to ci: loopctl records the merge itself"}}
  end

  # The one definition of a live claim the thread's own writes use (a checkpoint, a fix), so
  # the two paths never disagree about the same claim.
  defp live_claim(story) do
    if Claimant.live?(story, DateTime.utc_now()), do: :ok, else: {:error, :claim_not_live}
  end

  defp report(tenant_id, story, stage, api_key, conn) do
    identity = identity(api_key, conn)

    with :ok <- ensure_claimed(tenant_id, story, stage, identity) do
      Stages.advance(tenant_id, story.id, {stage.from, stage.to, stage.edge},
        claim_epoch: stage.claim_epoch,
        effects: Map.to_list(Map.get(stage, :effects, %{})),
        reason: Map.get(stage, :reason),
        actor_label: identity[:actor_label],
        actor_role: :agent,
        actor_lineage: identity[:actor_lineage]
      )
    end
  end

  # The claim's own `queued -> claimed`, made here when it did not land at the claim.
  defp ensure_claimed(tenant_id, story, %{from: :claimed}, identity) do
    case Stages.get(tenant_id, story.id) do
      %StoryStage{stage: :queued} ->
        case InteractiveClaims.enter_claimed(tenant_id, story, identity) do
          {:ok, _row} -> :ok
          error -> error
        end

      _other ->
        :ok
    end
  end

  defp ensure_claimed(_tenant_id, _story, _stage, _identity), do: :ok

  defp identity(api_key, conn) do
    lineage = Dispatches.lineage_for_api_key(api_key.tenant_id, api_key.id)

    [
      actor_label: Keyword.get(AuditContext.from_conn(conn), :actor_label),
      actor_role: :agent,
      actor_lineage: lineage
    ]
  end

  defp refusal(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{status: Status.code(status), code: code, message: message}})
  end
end
