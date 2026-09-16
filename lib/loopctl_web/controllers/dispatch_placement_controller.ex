defmodule LoopctlWeb.DispatchPlacementController do
  @moduledoc """
  Place a queued story on a runner — the control-side dispatch trigger (issue #803).

  `Loopctl.Delivery.Placement.place/4` shipped with #833 and had NO CALLER. The mechanism
  was built, tested and documented; nothing could reach it. The delivery loop's first
  end-to-end run on 2026-09-14 therefore went out BY PRODUCTION RPC, and the KB finding
  written from that run names this as blocker #1: "There is no API or MCP path;
  `Runners.dispatch/3` is an Elixir function."

  This is that path.

  ## It is a TRIGGER, not a scheduler

  The caller names the story and the runner. Nothing here selects work, ranks it, or runs on
  a cadence — an operator or an orchestrator decides what to place and when, exactly as they
  decide what to claim. That boundary is deliberate: an unattended driver that picks stories
  by a policy nobody stated is the part of this loop that changes what runs on someone's
  machines, and it is a decision to be made rather than a default to be inferred. Making the
  trigger reachable does not make it automatic.

  ## Every gate is `place/4`'s own

  This controller resolves the tenant and the authenticating key and calls the context, which
  applies the L6 halt, the human anchor, the lineage ceiling and the role floor —
  `:orchestrator` for a lineaged caller, `:user` for an unlineaged one. Those live in
  `place/4` because it is reachable without a `conn`, and a caller from a worker or an MCP
  tool has to meet the same gates.

  TWO of them are ALSO plugs here, and that is not an oversight. `place/4` validates the
  dispatch object before it checks the tier, so without a plug an agent-rooted tenant got
  `422 invalid_payload` for a malformed id and `403` only once the id parsed — an endpoint it
  may not use at all still answering questions about its input. The plug answers before a
  body is read. `RequireHumanAnchorDefaultDenyTest` enforces that across every mutating
  route.

  ## Repeating a placement

  Safe under the SAME claim: a repeat with the same `dispatch_id` resumes from the ledger and
  re-pushes. Once that claim ends — the lease expires, an operator force-unclaims, a refused
  push releases it — the recorded epoch is stale for ever and re-placing needs a NEW
  `dispatch_id`. That is the fence working rather than a fault, and the refusal says so.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Delivery.Placement
  alias OpenApiSpex.Schema

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :orchestrator

  # THE TIER GATE IS A PLUG AS WELL AS A CONTEXT CHECK, and the duplication is deliberate
  # even though the moduledoc argues against duplicating gates elsewhere.
  #
  # `place/4` validates the dispatch object BEFORE it checks the tier — `fetch_uuid` first,
  # `require_human_anchor` third. Without this plug an agent-rooted tenant therefore got 422
  # `invalid_payload` for a malformed id and 403 only once the id parsed, which makes the
  # endpoint a probe: a caller that may not use it at all could still learn whether a value
  # is a valid UUID. `RequireHumanAnchorDefaultDenyTest` enforces the invariant across every
  # mutating route and is what caught it.
  #
  # The context keeps its own check, for callers with no `conn` — that is the half the
  # moduledoc is about. This one answers before a body is ever read.
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:create]

  tags(["Runners"])

  operation(:create,
    summary: "Place a queued story on a runner",
    description:
      "The control-side dispatch trigger. Claims the story under a freshly minted session " <>
        "dispatch, advances its delivery stage `queued -> claimed` with that lineage, and " <>
        "pushes the dispatch to the runner — the three steps `Loopctl.Delivery.Placement` " <>
        "performs as one. A TRIGGER and not a scheduler: the caller names the story and the " <>
        "runner, and nothing here selects work or runs on a cadence.\n\n" <>
        "The story must be `contracted` and its stage row at `queued`; both are checked " <>
        "BEFORE anything is minted, so a not-ready story costs no dispatch row, no ephemeral " <>
        "key and no audit-chain entry.\n\n" <>
        "REPEATING is safe under the same claim — a repeat with the same `dispatch_id` " <>
        "resumes and re-pushes. Once that claim has ended the recorded epoch is stale for " <>
        "ever and re-placing the story needs a NEW `dispatch_id`.",
    parameters: [
      runner_id: [in: :path, type: :string, description: "The runner to place the story on"]
    ],
    request_body:
      {"Dispatch", "application/json",
       %Schema{
         type: :object,
         # EVERY FIELD `RunnerDispatch` REQUIRES except `claim_epoch`, which `place/4` injects
         # from the claim it just took. Under-declaring these is not a documentation nicety:
         # `cast_dispatch/1` applies NO defaults, so a caller following a shorter list gets
         # through the readiness check, has a session dispatch and an ephemeral key minted,
         # has `dispatch_created` and `story_stage_claimed` appended to an IMMUTABLE chain and
         # the story claimed — and only then is refused. That is exactly the cost the pre-mint
         # readiness check exists to avoid, reintroduced by a wrong schema.
         required: [
           :dispatch_id,
           :story_id,
           :kind,
           :repo,
           :base_branch,
           :branch,
           :wall_clock_seconds,
           :max_turns
         ],
         description:
           "The dispatch object, as `RunnerDispatch` declares it, minus `claim_epoch` (which " <>
             "loopctl injects from the claim) and minus `story` (which is REFUSED and built " <>
             "server-side from loopctl's own rows — see " <>
             "`story_not_accepted` below). Nothing is defaulted: `kind` must be sent and " <>
             "must be one of `x-connection.dispatchable_kinds`.",
         properties: %{
           dispatch_id: %Schema{
             type: :string,
             format: :uuid,
             description:
               "Caller-minted. Spent by the claim it is placed under: re-placing after that " <>
                 "claim ends needs a new one."
           },
           story_id: %Schema{type: :string, format: :uuid},
           kind: %Schema{
             type: :string,
             description: "Only the kinds in `x-connection.dispatchable_kinds` are accepted."
           },
           repo: %Schema{type: :string},
           branch: %Schema{type: :string},
           base_branch: %Schema{type: :string},
           wall_clock_seconds: %Schema{type: :integer, minimum: 1},
           max_turns: %Schema{type: :integer, minimum: 1}
         }
       }},
    responses: %{
      201 =>
        {"Placed", "application/json",
         %Schema{
           type: :object,
           required: [:dispatch_id, :claim_epoch],
           properties: %{
             dispatch_id: %Schema{type: :string, format: :uuid},
             claim_epoch: %Schema{
               type: :integer,
               description:
                 "The epoch the claim produced. Every runner-to-control message about this " <>
                   "dispatch echoes it, and a resurrected session's writes are refused on it."
             },
             implementer_dispatch_id: %Schema{
               type: :string,
               format: :uuid,
               nullable: true,
               description:
                 "The session dispatch this placement minted, or the one the ORIGINAL " <>
                   "placement minted when this call resumed from the ledger."
             }
           }
         }},
      403 => {"Forbidden", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 => {"Not placeable", "application/json", Schemas.ErrorResponse},
      422 =>
        {"Validation error; `story_not_accepted` — the story object is built by loopctl from " <>
           "its own records and may not be supplied by a caller; or " <>
           "`story_not_dispatchable` — the story exceeds a cap the runner contract declares " <>
           "and HAS BEEN ESCALATED to a human, with the claim released and nothing " <>
           "dispatched; or `story_no_longer_dispatchable` — the same cap on a RE-SEND of a " <>
           "recorded dispatch_id, where nothing is written and the claim stands",
         "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      500 =>
        {"`story_escalation_failed` — the story is neither dispatchable nor parked, so " <>
           "nothing is on a runner and no human has it either", "application/json",
         Schemas.ErrorResponse}
    }
  )

  @doc "POST /api/v1/runners/:runner_id/dispatches"
  def create(conn, %{"runner_id" => runner_id} = params) do
    # FROM THE KEY, not from `conn.assigns.current_tenant`. A superadmin key with no
    # impersonation header passes `RequireRole` by hierarchy and `RequireHumanAnchor`'s
    # leading `current_tenant: nil` clause unconditionally — so reading the assign
    # dereferenced nil and answered 500 on a valid credential, in a controller whose whole
    # thesis is that ordinary conditions must not. `DispatchController.create/2` reads the key
    # for the same reason; this at least reaches `place/4`'s `is_binary` guard.
    tenant_id = conn.assigns.current_api_key.tenant_id

    # The dispatch object is passed THROUGH, not reassembled: `place/4` hands it to
    # `Runners.dispatch/3`, which casts it against `RunnerDispatch` and refuses anything the
    # contract does not declare. Picking fields out here would be a second, quieter schema
    # that drifts from the published one.
    #
    # EXCEPT `story`, which is REFUSED — see `caller_supplied_story?/1`.
    dispatch = Map.drop(params, ["runner_id"])

    if caller_supplied_story?(dispatch),
      do: refuse_story(conn),
      else: do_place(conn, tenant_id, runner_id, dispatch)
  end

  # THE STORY OBJECT MAY NOT COME FROM THE WIRE, and this endpoint is what would have let it.
  #
  # `RunnerDispatch` carries the story as TYPED FIELDS — title, description, acceptance
  # criteria — and the runner composes its prompt from them. The contract's own reason for
  # that shape is security: "loopctl never sends a prompt ... because a dispatch runs as the
  # machine's user and a control plane able to hand a runner prose to execute is able to run
  # anything on it." A caller-supplied `story` IS prose handed to a runner, one level along.
  #
  # `Loopctl.Delivery.StoryPayload.build/3` is the server-side builder — "built from
  # Postgres" — and `place/4` NOW CALLS IT (`attach_story/6`), after the claim, which is the
  # only point where an undispatchable story can be escalated rather than truncated. So an
  # implement dispatch placed here carries a story object loopctl built from its own rows, and
  # the runner receives work rather than a story_id with nothing attached.
  #
  # This guard stays, and it is no longer the only one: `place/4` refuses a caller-supplied
  # `story` itself, so a worker, an MCP tool or the unattended driver is bound by the same
  # rule without passing through this endpoint. What this one adds is the message — a caller
  # is told to send `story_id` alone rather than getting a bare reason code.
  #
  # Refused rather than silently dropped: a caller that sent a story and got a dispatch
  # carrying a different one would have no way to tell.
  defp caller_supplied_story?(dispatch), do: Map.has_key?(dispatch, "story")

  defp refuse_story(conn) do
    error(conn, 422, "story_not_accepted", %{
      message:
        "The story object is built by loopctl from its own records and may not be supplied " <>
          "by a caller: a runner composes its prompt from those fields, so accepting them " <>
          "here would let a caller hand a runner prose to execute. Send `story_id` alone."
    })
  end

  defp do_place(conn, tenant_id, runner_id, dispatch) do
    case Placement.place(tenant_id, runner_id, dispatch,
           api_key: conn.assigns.current_api_key,
           actor_label: "api:dispatch_placement"
         ) do
      {:ok, placed} -> conn |> put_status(:created) |> json(placed)
      {:error, reason} -> refuse(conn, reason)
    end
  end

  @doc """
  The rendering of one refusal, public so every mapped code is testable.

  Staging a real push refusal needs a claimable story and a live socket, so the alternative
  was a test that asserted the mapping existed by inspecting the module — which is what the
  first version of this file did, and it could not fail. An unfalsifiable guard reads as
  coverage the file does not have.
  """
  @spec render_refusal(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def render_refusal(conn, reason), do: refuse(conn, reason)

  # MAPPED HERE, and this is not ceremony. `FallbackController`'s catch-all answers 500 for
  # an atom it has no clause for — deliberately, because an unmapped refusal is a gap and
  # rendering it as a client error would tell a caller its request was wrong when nobody
  # decided that. Its own comment says "Add a clause, or map it in the controller."
  #
  # Six of `place/4`'s documented refusals had no clause, and every one of them is an
  # ORDINARY answer on this endpoint: a halted tenant, an agent-rooted tenant, an unlineaged
  # caller, a caller below the role floor, a key from another tenant, a runner with no agent.
  # Unmapped, the commonest legitimate refusals of the loop's dispatch trigger would each
  # have answered 500 and logged an error about a gap that was really the endpoint working.
  #
  # The status and the code MATCH THE PLUGS that refuse the same conditions elsewhere —
  # `CheckCustodyHalt` answers 503 `tenant_halted`, `RequireHumanAnchor` 403
  # `custody_tier_required`, `RequireRole` 403 `insufficient_role` — because this path
  # applies those gates in the CONTEXT rather than in a pipeline, and a caller should not be
  # able to tell which mechanism refused it.
  defp refuse(conn, :tenant_halted) do
    error(conn, 503, "tenant_halted", %{
      message:
        "Custody operations are halted for this tenant and require a break-glass ceremony " <>
          "to clear. Reads and non-custody writes remain available.",
      scope: "custody_operations_only"
    })
  end

  defp refuse(conn, :custody_tier_required) do
    error(conn, 403, "custody_tier_required", %{
      message:
        "Placing a dispatch mints a custody dispatch and claims a story, which requires a " <>
          "human-anchored tenant (a WebAuthn signup ceremony)."
    })
  end

  defp refuse(conn, :root_dispatch_forbidden) do
    error(conn, 403, "root_dispatch_forbidden", %{
      message:
        "A dispatch may only be minted inside the caller's own lineage. An unlineaged " <>
          "caller below user role cannot place one."
    })
  end

  defp refuse(conn, :insufficient_role) do
    error(conn, 403, "insufficient_role", %{
      message: "Placing a dispatch requires orchestrator role."
    })
  end

  defp refuse(conn, :not_authorized) do
    error(conn, 403, "not_authorized", %{
      message: "No such runner in this tenant, or its row, key or tenant is no longer valid."
    })
  end

  defp refuse(conn, :runner_not_provisioned) do
    error(conn, 409, "runner_not_provisioned", %{
      message:
        "This runner has no agent identity, so a story claimed for it would be claimed for " <>
          "nobody. Re-enroll the runner."
    })
  end

  # A MALFORMED dispatch object. `place/4` answers `{:invalid, messages}` for an id that is
  # not a UUID, and `FallbackController`'s catch-all is deliberately ATOM-ONLY — so this
  # tuple matched no clause and RAISED a FunctionClauseError rather than rendering. Caught by
  # the default-deny guard, which drives every mutating route with an empty body: the very
  # first thing a caller gets wrong is the one shape that crashed.
  defp refuse(conn, {:invalid, messages}) when is_list(messages) do
    error(conn, 422, "invalid_payload", %{
      message: "The dispatch object is not valid.",
      details: messages
    })
  end

  # THE PUSH'S OWN REFUSALS, all eight of them, and none had a clause anywhere. `place/4`
  # ends in `Runners.dispatch/3`, whose spec returns these — and the most ordinary failure a
  # dispatch trigger has is the first one: a runner whose machine is asleep. The claim is
  # taken, the stage advances, the push is refused, `undo_claim/5` correctly releases and
  # revokes — and the caller got a 500 saying the server had a gap. Mapping `place/4`'s own
  # refusals and stopping there was the same defect one layer out.
  #
  # 409 for a state the caller can see and act on; 429 for BACKPRESSURE, which is a wait
  # rather than a fault and is the difference between "try another runner" and "try later".
  defp refuse(conn, :runner_not_connected) do
    error(conn, 409, "runner_not_connected", %{
      message:
        "The runner has no live connection. The claim was released and the session dispatch " <>
          "revoked, so re-placing needs a NEW dispatch_id once it reconnects."
    })
  end

  # The machine's own socket says it takes no work — `draining`, or a declared `max_sessions`
  # of `0`. 409 rather than 429: this is not backpressure that clears on its own, it is a
  # state the machine chose and leaves. NOTHING was claimed and nothing was minted, which is
  # the whole point of checking it before the claim — and it is why the gate is mounted on the
  # CLAIM path alone: a retry carrying a dispatch_id the ledger already holds never reaches
  # it, so this message's two claims are true wherever it is read.
  defp refuse(conn, :runner_declines_work) do
    error(conn, 409, "runner_declines_work", %{
      message:
        "This runner declares draining (or max_sessions 0), so it is taking no work. " <>
          "Nothing was claimed. Place on another runner, or reconnect this one without it."
    })
  end

  defp refuse(conn, :runner_ambiguous) do
    error(conn, 409, "runner_ambiguous", %{
      message: "More than one live connection for this runner; loopctl will not guess."
    })
  end

  defp refuse(conn, :kind_not_supported) do
    error(conn, 409, "kind_not_supported", %{
      message: "This runner does not run that kind. See x-connection.dispatchable_kinds."
    })
  end

  defp refuse(conn, :dispatch_id_conflict) do
    error(conn, 409, "dispatch_id_conflict", %{
      message:
        "This dispatch_id is already recorded against a different story or runner. A " <>
          "dispatch_id names one placement; use a new one."
    })
  end

  defp refuse(conn, :dispatch_already_replied) do
    error(conn, 409, "dispatch_already_replied", %{
      message: "The runner has already answered this dispatch."
    })
  end

  defp refuse(conn, reason) when reason in [:admission_limit_reached, :runner_at_capacity] do
    error(conn, 429, Atom.to_string(reason), %{
      message:
        "Backpressure, not a fault: the tenant or the runner is at its session limit. The " <>
          "claim was released. Retry when a slot frees."
    })
  end

  # THE STORY WAS TOO BIG FOR THE CONTRACT AND A HUMAN NOW HAS IT. An ordinary outcome of this
  # endpoint since `place/4` builds the story object: the story is escalated, the claim is
  # released, and nothing is on a runner. Rendered here because the shared fallback matches
  # `{:error, reason} when is_atom(reason)` and a TUPLE matched no clause at all — the same
  # FunctionClauseError this file already records for `{:invalid, messages}`, which would have
  # answered a 500 and a crash log to a caller whose story is sitting in front of a person.
  defp refuse(conn, {:story_not_dispatchable, violations}) do
    error(conn, 422, "story_not_dispatchable", %{
      message:
        "The story exceeds a cap the runner contract declares, so it was ESCALATED to a " <>
          "human rather than truncated — a dropped acceptance criterion is a story built to " <>
          "the wrong spec. The claim was released and nothing was dispatched. Shorten the " <>
          "story and it becomes dispatchable again.",
      violations: Enum.take(violations, 10)
    })
  end

  # NEITHER DISPATCHABLE NOR PARKED, which is the outcome nothing downstream picks up. 500 and
  # not 422: the story is undersized for nobody's fault, the escalation loopctl tried to write
  # failed, and the caller cannot fix either by changing the request.
  defp refuse(conn, {:escalation_failed, reason, violations}) do
    error(conn, 500, "story_escalation_failed", %{
      message:
        "The story is not dispatchable AND could not be escalated, so it is in neither " <>
          "place: nothing is on a runner and no human has been given it. This needs an " <>
          "operator.",
      escalation_error: inspect(reason),
      violations: Enum.take(violations, 10)
    })
  end

  # THE RESUME'S VERSION, and it says the opposite about the claim on purpose. A re-send does
  # not own the claim it would be parking — the story may be live under a session right now —
  # so this path writes NOTHING: no escalation, no release, no chain entry. Telling the
  # operator "the claim was released" here, as the message above does, would be a false
  # statement about system state that they would then act on.
  # THE STORY'S PROJECT IS BOUND TO NO REPOSITORY, or to two. Named rather than left to the
  # contract's `invalid_payload`, because the remedy is an operator's and has nothing to do
  # with the request: enrol an intake source for the project, or revoke the duplicate.
  defp refuse(conn, {:no_intake_source, project_id}) do
    error(conn, 409, "no_intake_source", %{
      message:
        "This story's project is bound to no repository, so a dispatch cannot name one. " <>
          "Enrol an intake source for the project, or pass `repo` and `base_branch` " <>
          "explicitly.",
      project_id: project_id
    })
  end

  defp refuse(conn, {:ambiguous_intake_source, project_id, count}) do
    error(conn, 409, "ambiguous_intake_source", %{
      message:
        "This story's project has #{count} active intake sources, so loopctl cannot choose " <>
          "the repository. Revoke the ones that no longer apply, or pass `repo` and " <>
          "`base_branch` explicitly.",
      project_id: project_id
    })
  end

  # A BUDGET THE OPERATOR HAS NOT SET. No default, deliberately — see the driver's moduledoc —
  # so this is configuration rather than a bad request, and the message names the key.
  defp refuse(conn, {:unset, key}) do
    error(conn, 409, "budget_unset", %{
      message:
        "#{key} is not configured and the request did not carry one. Set it, or pass " <>
          "`wall_clock_seconds` and `max_turns` on the request. There is deliberately no " <>
          "default: the budget is a cost decision and loopctl does not make it for you.",
      key: to_string(key)
    })
  end

  defp refuse(conn, {:over_contract_maximum, key}) do
    error(conn, 409, "budget_over_maximum", %{
      message: "#{key} is configured above the maximum the runner contract declares.",
      key: to_string(key)
    })
  end

  defp refuse(conn, :story_not_found) do
    error(conn, 404, "story_not_found", %{
      message: "No story with that id in this tenant."
    })
  end

  defp refuse(conn, {:story_no_longer_dispatchable, violations}) do
    error(conn, 422, "story_no_longer_dispatchable", %{
      message:
        "This dispatch_id is already recorded, and the story no longer fits a cap the runner " <>
          "contract declares — it must have been edited since it was placed. NOTHING was " <>
          "changed: the claim stands and any session under it is untouched. Shorten the " <>
          "story, or release the claim and place it again.",
      violations: Enum.take(violations, 10)
    })
  end

  defp refuse(conn, :story_not_accepted), do: refuse_story(conn)

  defp refuse(conn, :capacity_busy) do
    error(conn, 429, "capacity_busy", %{
      message: "The capacity reservation is contended. Retry."
    })
  end

  # Everything else — `:not_found`, `:wrong_stage`, `{:invalid_transition, _}`,
  # `:stale_claim_epoch`, every changeset and every fault `Dispatches`, `Stages` and
  # `Runners` already raise — keeps the shared rendering. Those ARE mapped, and duplicating
  # them here is how two renderings of one refusal drift apart.
  # FORWARDED, whatever the shape. The previous version guarded this `when is_atom(reason)`
  # and sent everything else to a local 500 — which threw away the two shapes the fallback
  # renders BEST, while the comment above claimed they kept the shared rendering:
  #
  #   * `{:invalid_transition, ctx}` — the race `place/4`'s own docs name, a story claimed by
  #     someone else between the readiness check and the lock. The fallback answers 409 WITH
  #     the story's current statuses; the guard made it a 500.
  #   * `%Ecto.Changeset{}` — `create_dispatch/3` surfaces its insert failure verbatim. The
  #     fallback answers 422 with the field errors; the guard made it a 500.
  #
  # The fallback's own atom-only catch-all still answers 500 for an atom nobody mapped, which
  # is the loudness that belongs there rather than here.
  defp refuse(conn, reason), do: LoopctlWeb.FallbackController.call(conn, {:error, reason})

  defp error(conn, status, code, extra) do
    conn
    |> put_status(status)
    |> json(%{error: Map.merge(extra, %{status: status, code: code})})
  end
end
