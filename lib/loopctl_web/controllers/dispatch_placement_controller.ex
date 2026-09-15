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

  require Logger

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
         required: [:dispatch_id, :story_id],
         description:
           "The dispatch object, as `RunnerDispatch` declares it. `kind` defaults to " <>
             "`implement`; only the kinds in `x-connection.dispatchable_kinds` are accepted.",
         properties: %{
           dispatch_id: %Schema{
             type: :string,
             format: :uuid,
             description:
               "Caller-minted. Spent by the claim it is placed under: re-placing after that " <>
                 "claim ends needs a new one."
           },
           story_id: %Schema{type: :string, format: :uuid},
           kind: %Schema{type: :string},
           repo: %Schema{type: :string},
           branch: %Schema{type: :string},
           base_branch: %Schema{type: :string},
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
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "POST /api/v1/runners/:runner_id/dispatches"
  def create(conn, %{"runner_id" => runner_id} = params) do
    tenant = conn.assigns.current_tenant

    # The dispatch object is passed THROUGH, not reassembled: `place/4` hands it to
    # `Runners.dispatch/3`, which casts it against `RunnerDispatch` and refuses anything the
    # contract does not declare. Picking fields out here would be a second, quieter schema
    # that drifts from the published one.
    dispatch = Map.drop(params, ["runner_id"])

    case Placement.place(tenant.id, runner_id, dispatch,
           api_key: conn.assigns.current_api_key,
           actor_label: "api:dispatch_placement"
         ) do
      {:ok, placed} -> conn |> put_status(:created) |> json(placed)
      {:error, reason} -> refuse(conn, reason)
    end
  end

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

  # Everything else — `:not_found`, `:wrong_stage`, `{:invalid_transition, _}`,
  # `:stale_claim_epoch`, every changeset and every fault `Dispatches`, `Stages` and
  # `Runners` already raise — keeps the shared rendering. Those ARE mapped, and duplicating
  # them here is how two renderings of one refusal drift apart.
  defp refuse(conn, reason) when is_atom(reason),
    do: LoopctlWeb.FallbackController.call(conn, {:error, reason})

  # A NON-ATOM refusal the fallback cannot take. Its catch-all matches an atom only, on
  # purpose — "a new refusal shape still fails loudly rather than being absorbed here" — so
  # handing it a tuple raises. Rendering it as a 500 keeps that loudness (the shape IS a gap)
  # without turning every unknown refusal into a crash inside the controller.
  defp refuse(conn, reason) do
    Logger.error(
      "DispatchPlacementController has no clause for #{inspect(reason)}; answered 500. " <>
        "path=#{conn.request_path}"
    )

    error(conn, 500, "internal_error", %{
      message: "The server could not complete this request. It has been logged."
    })
  end

  defp error(conn, status, code, extra) do
    conn
    |> put_status(status)
    |> json(%{error: Map.merge(extra, %{status: status, code: code})})
  end
end
