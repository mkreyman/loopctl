defmodule LoopctlWeb.StoryStageReportController do
  @moduledoc """
  US-45.9: the CLAIMANT of an interactive thread claim reports its own story's stage
  transitions, as a runner reports a placed claim's over its socket.

  It is given a runner's vocabulary minus the merge and nothing more. The body is cast by the
  runner channel's own validator (`Loopctl.ApiSpec.RunnerContract.cast_stage/1`), then
  narrowed to `StageMachine.claimant_reportable?/3`: never into `merged` and never
  `merge_refused`, which loopctl records itself in thread mode; after the merge, `deployed`
  and an escalation, which nothing else would write for a claim with no runner. The transition is written by the one writer
  (`Loopctl.Delivery.Stages.advance/4`) under the claim's epoch. Before that the caller must be
  the story's claimant under the epoch it names (`Loopctl.Delivery.Claimant.check/3`), on a
  live claim (`Claimant.live?/2`), whose recorded route (`Loopctl.Delivery.ClaimRoute`) is an
  interactive THREAD route. A placed claim has a runner to report for it and is refused, so
  there is never a second reporter for one claim.

  A RESEND of a report that already landed (its response was lost) answers the row with
  `replayed: true` when the row is at the report's destination under its epoch with the
  effects it carried; a report that disagrees with what is recorded names the recorded
  effects, so the caller can tell "already applied" from "someone else moved it".

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
  alias Loopctl.Delivery.RunnerStages
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
        "as a runner reports a placed claim's, minus the merge: never into `merged` and never " <>
        "`merge_refused` (`StageMachine.claimant_reportable?/3`: loopctl records the merge " <>
        "itself), but `merged -> deployed` (with `release_id`) after it; the same reportable " <>
        "effects (a checkpoint's `head_sha` entering `ci`), the same " <>
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
         {:ok, route} <- interactive_thread_route(tenant_id, story),
         {:ok, stage} <- cast(params, route),
         :ok <- Claimant.check(story, api_key.agent_id, stage.claim_epoch),
         :ok <- claimant_reportable(stage),
         :ok <- live_claim(story),
         {:ok, row, replayed?} <- report(tenant_id, story, stage, api_key, conn) do
      json(conn, %{stage: StoryEscalationController.render_stage(row), replayed: replayed?})
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
          "the claimant of a thread never reports the merge: loopctl records it itself"}}
  end

  # The one definition of a live claim the thread's own writes use (a checkpoint, a fix), so
  # the two paths never disagree about the same claim.
  defp live_claim(story) do
    if Claimant.live?(story, DateTime.utc_now()), do: :ok, else: {:error, :claim_not_live}
  end

  defp report(tenant_id, story, stage, api_key, conn) do
    identity = identity(api_key, conn)

    # A chained transition (the claim's own `queued -> claimed`, an escalation) whose chain
    # append the tenant's audit chain refuses as a hash violation answers the permanent
    # `audit_chain_append_failed`, as the runner's path does, instead of escaping as an
    # unclassified database error (`RunnerStages.answering_broken_chain/3`, the one copy of
    # that policy).
    RunnerStages.answering_broken_chain(tenant_id, fn -> "story_id=#{story.id}" end, fn ->
      with :ok <- ensure_claimed(tenant_id, story, stage, identity) do
        tenant_id
        |> Stages.advance(story.id, {stage.from, stage.to, stage.edge},
          claim_epoch: stage.claim_epoch,
          effects: Map.to_list(Map.get(stage, :effects, %{})),
          reason: Map.get(stage, :reason),
          actor_label: identity[:actor_label],
          actor_role: :agent,
          actor_lineage: identity[:actor_lineage]
        )
        |> answer(tenant_id, story, stage)
      end
    end)
  end

  defp answer({:ok, row}, _tenant_id, _story, _stage), do: {:ok, row, false}

  defp answer({:error, :stale_stage}, tenant_id, story, stage),
    do: resolve_replay(tenant_id, story, stage)

  defp answer({:error, :effect_conflict}, tenant_id, story, _stage),
    do: effect_conflict(Stages.get(tenant_id, story.id))

  defp answer(other, _tenant_id, _story, _stage), do: other

  # The runner's replay rule (`RunnerStages`' `resolve_replay/3` and
  # `replayed_effects_agree/4`), answered over HTTP. A compare-and-set that matched nothing is
  # a RESEND of a report that already landed when the row is at its destination under its
  # epoch with the effects it carried; at the destination with OTHER effects it is an
  # `effect_conflict`; anywhere else the caller's picture is stale, and the refusal carries the
  # row so it need not read again. Reaching here proves the caller's epoch is the story's:
  # `Stages.advance/4` refuses `:stale_claim_epoch` before its compare-and-set.
  defp resolve_replay(tenant_id, story, %{to: to, claim_epoch: epoch} = stage) do
    case Stages.get(tenant_id, story.id) do
      nil ->
        {:error, :not_found}

      %StoryStage{stage: ^to, claim_epoch: ^epoch} = row ->
        replayed_effects_agree(row, stage)

      %StoryStage{} = row ->
        {:error,
         {:conflict, "stale_stage",
          %{
            message: "the story is not at this report's from stage",
            stage: Atom.to_string(row.stage),
            recorded_effects: RunnerStages.recorded_effects(row)
          }}}
    end
  end

  defp replayed_effects_agree(row, stage) do
    supplied = Map.get(stage, :effects, %{})

    if Enum.all?(supplied, fn {effect, value} -> Map.get(row, effect) == value end),
      do: {:ok, row, true},
      else: effect_conflict(row)
  end

  # An `effect_conflict` carries the identities the row holds, so a caller whose earlier
  # report recorded one (a `head_sha` at `implementing`, say) can see what it is reconciling
  # against rather than resend the same refused value.
  defp effect_conflict(nil), do: {:error, :not_found}

  defp effect_conflict(%StoryStage{} = row) do
    {:error,
     {:conflict, "effect_conflict",
      %{
        message: "a different value is already recorded for that effect",
        stage: Atom.to_string(row.stage),
        recorded_effects: RunnerStages.recorded_effects(row)
      }}}
  end

  # The claim's own `queued -> claimed`, made at the claimant's first report (`InteractiveClaims`).
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

  defp refusal(conn, status, code, %{message: message} = detail) do
    conn
    |> put_status(status)
    |> json(%{
      error:
        Map.merge(
          %{status: Status.code(status), code: code, message: message},
          Map.delete(detail, :message)
        )
    })
  end

  defp refusal(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{status: Status.code(status), code: code, message: message}})
  end
end
