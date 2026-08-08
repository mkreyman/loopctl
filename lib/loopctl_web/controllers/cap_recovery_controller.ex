defmodule LoopctlWeb.CapRecoveryController do
  @moduledoc """
  Re-mints a capability token for a story the caller is already
  assigned to. Solves the session-crash problem: if an agent loses
  its cap, it can recover without being stuck.

  Security (L1 capability layer, chain-of-custody v2):

    * Recovery re-mints ONLY a `start_cap`. A client that supplies any
      other `cap_type` (e.g. `verify_cap`, `report_cap`,
      `review_complete_cap`) is rejected with 422 — an agent must never
      be able to mint a capability to verify/report/review its own work.
      A forged-cap-type attempt is an L1 forgery attempt: it is logged
      (Logger.warning) and recorded in the story's audit history
      (`cap_recovery_forgery_attempt`) so operators and L5/L6 detection
      can see it.
    * The lineage the cap is bound to is DERIVED SERVER-SIDE from the
      CALLER's own dispatch (`Dispatches.lineage_for_api_key/2`). A
      client-supplied `lineage` param is ignored entirely.

      It is deliberately NOT the story's recorded implementer lineage.
      `Capabilities.validate_cap/6` demands an EXACT lineage match at
      consume time, and the whole point of recovery is that the original
      session DIED — the agent comes back under a NEW dispatch with a new
      lineage, so a cap minted to the old one is unconsumable by the only
      principal entitled to spend it. The documented crash-recovery path
      failed precisely in the case it exists for. Binding to the caller
      grants nothing new: the caller has already been proven to be the
      story's `assigned_agent_id`, and `start_cap` gates only
      `POST /start`, which re-checks that same assignment
      (`Progress.validate_assigned_agent/2`).
    * Recovery NEVER rewrites `implementer_dispatch_id`. That field is the
      story's custody provenance — what report/review-complete/verify
      compare a caller's lineage against — and letting an agent re-anchor
      it by re-minting would hand it the separation the L4 gates exist to
      demand of it. Recovery therefore crosses dispatches AND TREES: the
      session that died may have taken the whole lineage with it, and the
      agent comes back rooted somewhere new. Demanding a shared ROOT of the
      caller (`Dispatches.lineage_shares_prefix?/2`) closed the path in
      exactly that case, while blocking nothing in the documented single-root
      tenant, where every dispatch shares element 0. What holds separation
      here is not the root: the caller is already proven to be the story's
      `assigned_agent_id`, the `start_cap` gates only `POST /start` (which
      re-checks that same assignment), and every L4 gate runs
      `assigned_agent_id` equality IN ADDITION to its lineage comparison, so
      a recovered agent still cannot report, review or verify its own work.
    * A caller with NO lineage of its own is refused
      (`caller_lineage_required`) on a story whose work WAS dispatch-minted.
      Minting an `[]`-lineage cap there would let an unlineaged legacy key
      start work that only a dispatch-minted principal could start.
    * The recorded implementer dispatch must not be REVOKED — that is an L6
      custody stop signal and recovery must not mint past it. An EXPIRED
      one is allowed: dispatch TTLs are bounded, so by the time an agent
      needs recovery its original dispatch has usually lapsed on its own,
      and refusing there re-created the same dead end from the other side.
    * The caller must own the story (`assigned_agent_id`). The role gate
      is `exact_role: :agent` (no hierarchy) to match the sibling
      agent-exclusive custody endpoints (claim/start/request_review/
      unclaim) — an orchestrator identity linked to the same agent_id
      must not be able to walk this gate where it couldn't walk claim.
  """

  use LoopctlWeb, :controller

  require Logger

  import Ecto.Query

  alias Loopctl.Audit
  alias Loopctl.Capabilities
  alias Loopctl.Dispatches
  alias Loopctl.WorkBreakdown.Story

  plug LoopctlWeb.Plugs.RequireRole, exact_role: :agent

  # US-26.7.1 — work-breakdown surface requires a human-anchored tenant.
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:recover]

  @doc "POST /api/v1/stories/:id/recover-cap"
  def recover(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    agent_id = api_key.agent_id

    with :ok <- validate_start_cap(params),
         {:ok, story} <- fetch_owned_story(tenant_id, agent_id, story_id),
         :ok <- implementer_dispatched?(tenant_id, story),
         {:ok, lineage} <- caller_lineage(tenant_id, api_key.id),
         {:ok, cap} <- Capabilities.mint(tenant_id, "start_cap", story.id, lineage) do
      conn
      |> put_status(:created)
      |> json(%{data: Capabilities.serialize(cap)})
    else
      {:error, :invalid_cap_type} ->
        log_forgery_attempt(conn, tenant_id, agent_id, story_id, Map.get(params, "cap_type"))
        error(conn, 422, "cap_type_not_recoverable", "cap recovery only re-mints start_cap")

      {:error, :not_found} ->
        error(conn, 404, "story_not_found", "Story not found or not assigned to you")

      {:error, :no_dispatch_lineage} ->
        error(
          conn,
          422,
          "no_dispatch_lineage",
          "No recorded dispatch lineage for this story — cannot recover a cap " <>
            "for a story you weren't dispatched to"
        )

      {:error, :dispatch_revoked} ->
        error(
          conn,
          422,
          "dispatch_revoked",
          "The story's implementer dispatch has been REVOKED — cannot recover a cap " <>
            "off a halted lineage. An expired dispatch is fine; a revoked one is a " <>
            "custody stop signal and needs an operator."
        )

      {:error, :caller_lineage_required} ->
        error(
          conn,
          409,
          "caller_lineage_required",
          "This story's work was dispatch-minted, so a recovered capability must bind to " <>
            "YOUR dispatch lineage — and your key was not minted by a dispatch, so it has " <>
            "none. Call again with an ephemeral key from POST /api/v1/dispatches."
        )

      # The remaining shapes are internal failures of the mint itself (an
      # unreachable secret store, a superseded key, a changeset). `inspect`ing the
      # term into the response body leaked internal error structure to an
      # agent-role caller and gave it no stable string to branch on. The term goes
      # to the log; the caller gets the code — and it gets it from
      # `FallbackController`, the same way `POST /claim` answers the IDENTICAL
      # condition, so status, code and retry semantics cannot drift between the
      # two paths (this used to answer 422 `cap_mint_failed` where claim answers
      # 503 `capability_mint_failed`, so a client branching on status class read a
      # transient fault as permanent).
      {:error, reason} ->
        Logger.error(
          "cap_recovery_mint_failed: could not mint a start_cap — " <>
            "story_id=#{story_id} tenant_id=#{tenant_id} " <>
            "caller_agent_id=#{inspect(agent_id)} reason=#{inspect(reason)}"
        )

        LoopctlWeb.FallbackController.call(
          conn,
          {:error, Capabilities.mint_failure_class(reason)}
        )
    end
  end

  # --- Private ---

  # Recovery only ever re-mints a start_cap. An absent cap_type defaults
  # to start_cap; anything else is a client trying to forge a higher-trust
  # capability and is rejected.
  defp validate_start_cap(params) do
    case Map.get(params, "cap_type") do
      nil -> :ok
      "start_cap" -> :ok
      _other -> {:error, :invalid_cap_type}
    end
  end

  # A key with NO agent_id (a legacy env-var agent key) can own nothing: the
  # comparison below is an interpolated `== nil`, which Ecto REFUSES with an
  # ArgumentError, so the documented 404 surfaced as a 500. Mirrors the explicit
  # nil clause on `Capabilities.list_for_assigned_agent/3`.
  defp fetch_owned_story(_tenant_id, nil, _story_id), do: {:error, :not_found}

  defp fetch_owned_story(tenant_id, agent_id, story_id) do
    story =
      from(s in Story,
        where:
          s.id == ^story_id and s.tenant_id == ^tenant_id and s.assigned_agent_id == ^agent_id
      )
      |> Loopctl.AdminRepo.one()

    if story, do: {:ok, story}, else: {:error, :not_found}
  end

  # Recovery is confined to DISPATCH-MINTED work: the story must carry a
  # resolvable implementer dispatch with a real lineage. That dispatch's lineage
  # is NOT what the cap binds to (see the moduledoc) — this is a gate on the
  # STORY, not the source of the token's scope.
  #
  # REVOKED is refused: revocation is a deliberate custody stop signal and
  # minting past it would undo it. EXPIRED is allowed: dispatch TTLs are bounded
  # and an agent that lost its session has almost always outlived its original
  # dispatch, so refusing there closed the recovery path in exactly the situation
  # it exists for.
  defp implementer_dispatched?(_tenant_id, %Story{implementer_dispatch_id: nil}),
    do: {:error, :no_dispatch_lineage}

  defp implementer_dispatched?(tenant_id, %Story{implementer_dispatch_id: dispatch_id}) do
    case Dispatches.get_dispatch(tenant_id, dispatch_id) do
      {:ok, %{revoked_at: revoked}} when not is_nil(revoked) -> {:error, :dispatch_revoked}
      {:ok, %{lineage_path: []}} -> {:error, :no_dispatch_lineage}
      {:ok, _dispatch} -> :ok
      _ -> {:error, :no_dispatch_lineage}
    end
  end

  # The CALLER's lineage, resolved from the key the request authenticated with —
  # never from the request body. `lineage_for_api_key/2` answers `[]` for a key no
  # live dispatch minted; binding a cap to `[]` here would let an unlineaged
  # legacy key start work that was claimed under a dispatch, so it is refused.
  defp caller_lineage(tenant_id, api_key_id) do
    case Dispatches.lineage_for_api_key(tenant_id, api_key_id) do
      [] -> {:error, :caller_lineage_required}
      lineage -> {:ok, lineage}
    end
  end

  # An agent asking recovery to mint it a verify_cap/report_cap/
  # review_complete_cap is forging the L1 capability layer. Surface it: a
  # Logger.warning (structured data in the message string, following
  # log_custody_orphaned) plus an audit entry so it appears in
  # GET /stories/:id/history and can feed anomaly detection. The audit
  # write is best-effort — it must never mask the 422.
  defp log_forgery_attempt(conn, tenant_id, agent_id, story_id, rejected_cap_type) do
    Logger.warning(
      "cap_recovery_forgery_attempt: agent attempted to mint a non-start_cap via cap " <>
        "recovery — rejected_cap_type=#{inspect(rejected_cap_type)} story_id=#{story_id} " <>
        "tenant_id=#{tenant_id} caller_agent_id=#{inspect(agent_id)}"
    )

    attrs =
      conn
      |> LoopctlWeb.AuditContext.from_conn()
      |> Map.new()
      |> Map.merge(%{
        entity_type: "story",
        entity_id: story_id,
        action: "cap_recovery_forgery_attempt",
        metadata: %{
          "rejected_cap_type" => to_string(rejected_cap_type),
          "caller_agent_id" => agent_id
        }
      })

    _ = Audit.create_log_entry(tenant_id, attrs)
    :ok
  end

  # Every refusal carries a STABLE `code` a client can branch on, matching the
  # convention `LoopctlWeb.FallbackController` uses everywhere else. Previously
  # the only discriminator was the prose message, and the catch-all's was built by
  # `inspect`ing an internal error term into the body.
  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message, status: status}})
  end
end
