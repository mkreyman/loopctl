defmodule LoopctlWeb.StoryStatusController do
  @moduledoc """
  Controller for agent status transitions on stories.

  Implements the agent side of the two-tier trust model:
  - POST /stories/:id/contract -- acknowledge ACs (pending -> contracted)
  - POST /stories/:id/claim -- claim story (contracted -> assigned)
  - POST /stories/:id/start -- begin work (assigned -> implementing)
  - POST /stories/:id/request-review -- signal implementation ready for review
  - POST /stories/:id/report -- report done (implementing -> reported_done)
    (chain-of-custody: caller must be a DIFFERENT agent from the implementer)
  - POST /stories/:id/unclaim -- release story (any -> pending)
  - POST /stories/:id/renew-claim -- extend the claim's lease (#803)
  """

  use LoopctlWeb, :controller

  require Logger
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Capabilities
  alias Loopctl.Dispatches
  alias Loopctl.LogValue
  alias Loopctl.Progress
  alias Loopctl.Progress.StateMachine
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  # #621: the L1 capability layer's two refusal shapes. Both are rendered as 403 by
  # FallbackController (fallback_controller.ex:259, :272) but previously had no
  # clause in the controllers' case statements, so they raised CaseClauseError and
  # surfaced as 500s. Expressed as a guard so each action forwards them in ONE
  # branch — the controller actions sit at credo's cyclomatic-complexity limit.
  defguardp is_capability_error(reason)
            when reason in [:missing_capability, :capability_key_unavailable] or
                   (is_tuple(reason) and tuple_size(reason) == 2 and
                      elem(reason, 0) == :cap_rejected)

  # #803: refusals start/report forward unchanged. Folded into guards for the same
  # complexity reason as the one above.
  defguardp is_forwarded_start_error(reason)
            when is_capability_error(reason) or
                   reason in [:stale_claim_epoch, :must_contract_first, :must_claim_first]

  plug LoopctlWeb.Plugs.RequireRole,
       [exact_role: [:agent, :orchestrator]] when action in [:contract]

  plug LoopctlWeb.Plugs.RequireRole,
       [exact_role: [:agent, :orchestrator]] when action in [:report]

  # LCP-1 §9.3: under the `signed` custody profile, an enrolled caller's report
  # claim must carry a valid signature. No-op under the default `bearer` profile.
  plug LoopctlWeb.Plugs.RequireSignedClaim, [gate: "report"] when action in [:report]

  plug LoopctlWeb.Plugs.RequireRole,
       [exact_role: :agent]
       when action in [:claim, :start, :request_review, :unclaim, :renew_claim]

  # US-26.7.1 — work-breakdown surface requires a human-anchored tenant.
  plug LoopctlWeb.Plugs.RequireHumanAnchor
       when action in [
              :contract,
              :claim,
              :start,
              :report,
              :request_review,
              :unclaim,
              :renew_claim
            ]

  # The request-body shape of `claim_epoch`, shared by start, report and renew-claim.
  @claim_epoch_schema %OpenApiSpex.Schema{
    type: :integer,
    minimum: 0,
    description:
      "The `claim_epoch` the story's claim returned (#803). Optional on start and report: " <>
        "absent, no fence check runs (every client written before the fence); present and " <>
        "not the story's current epoch, the call is refused with 409 `stale_claim_epoch`. " <>
        "The delivery-loop runner sends it on every call, and that path makes it mandatory."
  }

  tags(["Progress"])

  operation(:contract,
    summary: "Contract story",
    description:
      "Agent acknowledges the story's acceptance criteria. " <>
        "Transitions pending -> contracted.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    request_body: {"Contract params", "application/json", Schemas.ContractRequest},
    responses: %{
      200 => {"Story contracted", "application/json", Schemas.StoryStatusResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 => {"Invalid transition", "application/json", Schemas.ErrorResponse},
      422 => {"Mismatch", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:claim,
    summary: "Claim story",
    description:
      "Agent claims a contracted story. Uses pessimistic locking. The response carries a " <>
        "`capability` (a start_cap) which the caller must present to POST /start; it is " <>
        "bound to the caller's dispatch lineage and expires. Claiming with a " <>
        "dispatch-minted key also records the implementer's dispatch on the story, which " <>
        "is what the downstream custody gates compare. Minting is ATOMIC with the claim: " <>
        "for a tenant with an audit signing key, a claim whose capability cannot be minted " <>
        "does not commit at all, so there is no state in which the story is claimed but " <>
        "unstartable. A mint failure that clears on its own — an unreachable secret store, " <>
        "or a rotation whose new private half is not deployed yet — is 503 " <>
        "`capability_mint_failed` with `retry-after`; an audit key that is ABSENT or " <>
        "CORRUPT is 503 `capability_key_unavailable` with none, because only an operator " <>
        "can clear it. The claim carries a LEASE and a FENCE: the returned story's " <>
        "`claimed_until` is when the claim may be released if not renewed " <>
        "(POST /stories/:id/renew-claim; default lease 24 hours, `STORY_CLAIM_LEASE_SECONDS`), " <>
        "and `claim_epoch` is incremented by this claim and by every release. Keep the " <>
        "epoch: renew-claim requires it, and start/report refuse a stale one with " <>
        "409 `stale_claim_epoch`.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    responses: %{
      200 => {"Story claimed", "application/json", Schemas.StoryStatusResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 =>
        {"Invalid transition or dependencies not met", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      503 =>
        {"The claim's capability could not be minted; nothing was claimed. Retryable only " <>
           "for `capability_mint_failed`", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:start,
    summary: "Start story",
    description:
      "Agent starts work on an assigned story. A tenant with an audit signing key must " <>
        "present the `start_cap` returned by the claim response (or recovered via " <>
        "POST /stories/:id/recover-cap) as `capability`; omitting it yields " <>
        "403 missing_capability. When a capability IS presented and there is no usable key " <>
        "to check it against (replaced without an archived history row, or advertised " <>
        "without a readable private half), the answer is 503 `capability_key_unavailable` " <>
        "— recovery cannot fix that one, only an operator can. A tenant with NO audit key " <>
        "at all — pre-v2, or one whose key was CLEARED — needs no capability and starts " <>
        "without one, dropping to pre-v2 custody strength.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    request_body:
      {"Start params", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           capability: %OpenApiSpex.Schema{
             type: :string,
             format: :uuid,
             description:
               "The start_cap `cap_id` issued to this caller's dispatch lineage. Accepted " <>
                 "as `cap_id` as well. Single-use, story-bound, lineage-bound, expiring."
           },
           claim_epoch: @claim_epoch_schema
         }
       }},
    responses: %{
      200 => {"Story started", "application/json", Schemas.StoryStatusResponse},
      403 =>
        {"Not assigned agent, or missing/rejected capability", "application/json",
         Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      400 =>
        {"claim_epoch is not a non-negative integer", "application/json", Schemas.ErrorResponse},
      409 =>
        {"Invalid transition, or stale_claim_epoch", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      503 =>
        {"The tenant's audit signing key is unavailable, so the capability could not be " <>
           "checked", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:request_review,
    summary: "Request review",
    description:
      "Assigned agent signals that implementation is complete and ready for review. " <>
        "Does NOT change status. Fires a story.review_requested webhook event. Ends the " <>
        "claim's lease: the story records `review_requested_at`, and from then on the " <>
        "reclaimer never releases it for an expired `claimed_until` (renewing does not " <>
        "re-arm it), because the work now waits on a different principal's report.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    responses: %{
      200 => {"Review requested", "application/json", Schemas.StoryStatusResponse},
      403 => {"Not assigned agent", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 => {"Story not in implementing status", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:report,
    summary: "Report story done",
    description:
      "A DIFFERENT agent (reviewer) reports story as done. " <>
        "The implementing agent cannot call this (chain-of-custody). " <>
        "No capability token is required or accepted: this transition is gated by " <>
        "structural lineage separation, not by L1, because a capability can only be " <>
        "bound to a lineage known when it is minted, and the reporter is by definition " <>
        "a principal distinct from the implementer who started the work. " <>
        "Optionally includes an artifact report and/or a token usage record.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    request_body:
      {"Report params (optional artifact and token_usage)", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           artifact: %OpenApiSpex.Schema{
             type: :object,
             description: "Optional artifact report to attach to this story",
             properties: %{
               artifact_type: %OpenApiSpex.Schema{type: :string},
               path: %OpenApiSpex.Schema{type: :string},
               exists: %OpenApiSpex.Schema{type: :boolean},
               details: %OpenApiSpex.Schema{type: :object, additionalProperties: true}
             }
           },
           token_usage: %OpenApiSpex.Schema{
             type: :object,
             description:
               "Optional token usage to report alongside the story completion. " <>
                 "When provided, creates a token_usage_report record for this story.",
             properties: %{
               input_tokens: %OpenApiSpex.Schema{
                 type: :integer,
                 minimum: 0,
                 description: "Input tokens consumed"
               },
               output_tokens: %OpenApiSpex.Schema{
                 type: :integer,
                 minimum: 0,
                 description: "Output tokens consumed"
               },
               model_name: %OpenApiSpex.Schema{
                 type: :string,
                 minLength: 1,
                 description: "LLM model name",
                 example: "claude-opus-4-5"
               },
               cost_millicents: %OpenApiSpex.Schema{
                 type: :integer,
                 minimum: 0,
                 description: "Cost in millicents (1/1000 of a cent)"
               },
               phase: %OpenApiSpex.Schema{
                 type: :string,
                 enum: ["planning", "implementing", "reviewing", "other"],
                 description: "Work phase (default: other)"
               },
               session_id: %OpenApiSpex.Schema{
                 type: :string,
                 nullable: true,
                 description: "Optional session identifier"
               }
             }
           },
           claim_epoch: @claim_epoch_schema
         }
       }},
    responses: %{
      200 => {"Story reported done", "application/json", Schemas.StoryStatusResponse},
      403 => {"Missing or rejected capability", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      400 =>
        {"claim_epoch is not a non-negative integer", "application/json", Schemas.ErrorResponse},
      409 =>
        {"Invalid transition, self-report blocked, or stale_claim_epoch", "application/json",
         Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:unclaim,
    summary: "Unclaim story",
    description:
      "Agent releases a story back to pending. A DELIVERY story whose stage row was in flight " <>
        "does not stay pending: giving it back spent an attempt, so it is re-contracted " <>
        "(`contracted`) below the retry ceiling `DISPATCH_MAX_ATTEMPTS`, and at the ceiling its " <>
        "stage row is escalated over `attempts_exhausted` for a human. The story returned is " <>
        "the story as the release left it.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    responses: %{
      200 => {"Story unclaimed", "application/json", Schemas.StoryStatusResponse},
      403 => {"Not assigned agent", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 => {"Invalid transition", "application/json", Schemas.ErrorResponse},
      422 =>
        {"The release's story-row write or its audit entry was rejected. Nothing was " <>
           "released and the story is unchanged.", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      500 =>
        {"`audit_chain_append_failed` — the release reached the retry ceiling and the chain " <>
           "entry its escalation must carry was refused. The WHOLE release rolled back: the " <>
           "story is unchanged.", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:renew_claim,
    summary: "Renew story claim",
    description:
      "The story's assigned agent extends its claim's lease: `claimed_until` becomes now " <>
        "plus the lease length (default 24 hours, `STORY_CLAIM_LEASE_SECONDS`) — measured " <>
        "from NOW, so renewing often never banks a longer lease. A claim not renewed " <>
        "before `claimed_until` is released back to `pending` by the reclaimer, which " <>
        "bumps `claim_epoch`. The caller must present the `claim_epoch` its claim returned. " <>
        "Refusals: 400 when `claim_epoch` is missing or not a non-negative integer; " <>
        "422 `not_claimed` when the story is not assigned or implementing; " <>
        "409 `stale_claim_epoch` when the epoch is not current (the claim has ended — " <>
        "stop working it); 409 `not_claimant` when the caller is not the assigned agent. " <>
        "A claim made before leases existed has no `claimed_until` and is never reclaimed; " <>
        "renewing it gives it a lease.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    request_body:
      {"Renew params", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:claim_epoch],
         properties: %{claim_epoch: @claim_epoch_schema}
       }},
    responses: %{
      200 => {"Claim renewed", "application/json", Schemas.StoryStatusResponse},
      400 => {"claim_epoch missing or malformed", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 => {"stale_claim_epoch or not_claimant", "application/json", Schemas.ErrorResponse},
      422 => {"not_claimed", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc """
  POST /api/v1/stories/:id/contract

  Agent acknowledges the story's acceptance criteria.
  Request body must include story_title and ac_count matching the actual story.
  """
  def contract(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    # #624(6): `:admin` was checked here but is not a role in the hierarchy
    # (superadmin > user > orchestrator > agent — see Loopctl.Auth.Role), so the
    # atom was dead. Removed rather than left as a misleading forward-reference.
    skip_check = api_key.role == :orchestrator

    opts =
      AuditContext.from_conn(conn)
      |> Keyword.merge(agent_id: api_key.agent_id)
      |> Keyword.put(:skip_contract_check, skip_check)

    case Progress.contract_story(tenant_id, story_id, params, opts) do
      {:ok, story} ->
        role = conn.assigns.current_api_key.role
        json(conn, %{story: story, next_actions: StateMachine.next_actions(story, role)})

      {:error, :title_mismatch} ->
        {:error, :unprocessable_entity, "story_title does not match"}

      {:error, {:contract_mismatch, _ctx} = err} ->
        {:error, err}

      {:error, {:invalid_transition, _ctx} = err} ->
        {:error, err}

      {:error, :invalid_transition} ->
        {:error, :conflict}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  POST /api/v1/stories/:id/claim

  Agent claims a contracted story. Uses pessimistic locking.
  """
  def claim(conn, %{"id" => story_id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    opts =
      AuditContext.from_conn(conn)
      |> Keyword.merge(agent_id: api_key.agent_id)
      |> Keyword.merge(custody_identity(api_key))

    case Progress.claim_story(tenant_id, story_id, opts) do
      {:ok, story} ->
        role = conn.assigns.current_api_key.role
        respond_with_story(conn, story, role)

      {:error, :must_contract_first} ->
        {:error, :must_contract_first}

      # The claim rolled back because its start_cap could not be minted: for a
      # keyed tenant a claim that cannot deliver a capability would leave a story
      # the agent can neither start nor recover, so it does not commit at all.
      # The two reasons answer differently on purpose — a secret-store blip is
      # retryable, an absent or superseded key is an operator condition and
      # advertising it as retryable turned agents into hot-loops.
      {:error, reason} when reason in [:capability_mint_failed, :capability_key_unavailable] ->
        {:error, reason}

      {:error, {:invalid_transition, _ctx} = err} ->
        {:error, err}

      {:error, :invalid_transition} ->
        {:error, :conflict}

      {:error, :dependencies_not_met} ->
        {:error, :conflict}

      {:error, :not_found} ->
        {:error, :not_found}

      # Anything else is a server-side failure of the claim's own transaction,
      # already logged with its step and rolled back. Without this clause an
      # enumerated `case` turned every such reason into a CaseClauseError — the
      # same 500 the multi had already handled correctly.
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  POST /api/v1/stories/:id/start

  Agent starts work on an assigned story.
  """
  def start(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    opts =
      AuditContext.from_conn(conn)
      |> Keyword.merge(agent_id: api_key.agent_id)
      |> Keyword.merge(custody_identity(api_key))
      |> Keyword.put(:cap_id, capability_param(params))

    with {:ok, opts} <- put_claim_epoch(opts, params) do
      do_start(conn, tenant_id, story_id, opts)
    end
  end

  defp do_start(conn, tenant_id, story_id, opts) do
    case Progress.start_story(tenant_id, story_id, opts) do
      {:ok, story} ->
        role = conn.assigns.current_api_key.role
        respond_with_story(conn, story, role)

      {:error, :not_assigned_agent} ->
        {:error, :forbidden}

      # #621: the capability layer's own refusals had NO clause here, so a missing
      # or rejected token raised CaseClauseError and surfaced as a 500 instead of
      # the documented 403 — the failure mode was indistinguishable from a crash.
      # FallbackController already renders both (fallback_controller.ex:259, :272);
      # they just have to reach it. The #803 fence and the ordering refusals take
      # the same single branch.
      {:error, reason} when is_forwarded_start_error(reason) ->
        {:error, reason}

      {:error, {:invalid_transition, _ctx} = err} ->
        {:error, err}

      {:error, :invalid_transition} ->
        {:error, :conflict}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  POST /api/v1/stories/:id/request-review

  Assigned agent signals that implementation is complete and ready for review.
  Fires a story.review_requested webhook event without changing status.
  """
  def request_review(conn, %{"id" => story_id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    opts = Keyword.merge(AuditContext.from_conn(conn), agent_id: api_key.agent_id)

    case Progress.request_review(tenant_id, story_id, opts) do
      {:ok, story} ->
        role = conn.assigns.current_api_key.role
        json(conn, %{story: story, next_actions: StateMachine.next_actions(story, role)})

      {:error, :not_assigned_agent} ->
        {:error, :forbidden}

      {:error, {:invalid_transition, _ctx} = err} ->
        {:error, err}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  POST /api/v1/stories/:id/report

  A DIFFERENT agent (reviewer) confirms that the implementation is done.
  Chain-of-custody: the implementing agent cannot report their own work.
  Optionally includes an artifact report.
  """
  def report(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    cond do
      is_nil(api_key.agent_id) ->
        {:error, :unprocessable_entity, "Agent ID required for chain-of-custody"}

      invalid_claim_epoch?(params) ->
        claim_epoch_error()

      true ->
        do_report(conn, tenant_id, api_key, story_id, params)
    end
  end

  defp do_report(conn, tenant_id, api_key, story_id, params) do
    opts =
      AuditContext.from_conn(conn)
      |> Keyword.merge(
        agent_id: api_key.agent_id,
        # Chain of custody: the reporter's lineage is resolved SERVER-SIDE from
        # the authenticating key's dispatch — never taken from the request body.
        reporter_lineage: Dispatches.lineage_for_api_key(tenant_id, api_key.id),
        # LCP-1 §9.4: the RequireSignedClaim plug stashed the verified signed claim
        # (nil under bearer); Progress records it in the hash-chained audit entry.
        custody_claim: conn.assigns[:custody_signed_claim]
      )
      # #621: report consumes NO capability — see Progress.start_story/3 for why a
      # report_cap cannot be bound to a principal permitted to report. The custody
      # gate fed by :reporter_lineage above is the enforcement. :dispatch_id is
      # still resolved server-side so the reporter's dispatch is recorded.
      |> Keyword.merge(custody_identity(api_key))
      |> maybe_add_token_usage(params)
      |> Keyword.put(:claim_epoch, params["claim_epoch"])

    artifact_params = extract_artifact_params(params)

    case Progress.report_story(tenant_id, story_id, opts, artifact_params) do
      {:ok, story} ->
        role = conn.assigns.current_api_key.role
        respond_with_story(conn, story, role)

      # Custody-gate failures pass through unchanged to the FallbackController:
      #   * :self_report_blocked        — reporter is the implementer.
      #   * :unresolvable_dispatch_lineage — declared implementer dispatch does not
      #     resolve; the guard fails closed on a lineage-integrity error, distinct
      #     from a self-report attempt.
      #   * :missing_assigned_agent     — custody-unattributed story; the guard
      #     fails closed rather than passing vacuously.
      {:error, reason}
      when reason in [
             :self_report_blocked,
             :unresolvable_dispatch_lineage,
             :missing_assigned_agent,
             # #803: the reporter presented an epoch from a claim that has ended.
             :stale_claim_epoch
           ] ->
        {:error, reason}

      {:error, {:invalid_transition, _ctx} = err} ->
        {:error, err}

      {:error, :invalid_transition} ->
        {:error, :conflict}

      {:error, :not_found} ->
        {:error, :not_found}

      # Cross-tenant / non-existent token_usage skill_version_id (tokens-10).
      {:error, :unprocessable_entity, message} ->
        {:error, :unprocessable_entity, message}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  POST /api/v1/stories/:id/unclaim

  Agent releases a story back to pending.
  """
  def unclaim(conn, %{"id" => story_id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    # `:actor_lineage` reaches the chain entry of an escalation the release may decide
    # (US-44.4), so it is resolved SERVER-SIDE from the authenticating key, like every other
    # lineage on this surface.
    opts =
      Keyword.merge(AuditContext.from_conn(conn),
        agent_id: api_key.agent_id,
        actor_lineage: Dispatches.lineage_for_api_key(tenant_id, api_key.id)
      )

    case Progress.unclaim_story(tenant_id, story_id, opts) do
      {:ok, story} ->
        role = conn.assigns.current_api_key.role
        json(conn, %{story: story, next_actions: StateMachine.next_actions(story, role)})

      {:error, :not_assigned_agent} ->
        {:error, :forbidden}

      {:error, :not_assigned_to_you} ->
        {:error, :forbidden}

      {:error, :invalid_transition} ->
        {:error, :conflict}

      {:error, :not_found} ->
        {:error, :not_found}

      # US-44.4: the release's escalation could not append its chain entry
      # (`Progress.unclaim_story/3`). The release rolled back; the story is unchanged.
      # FallbackController renders it as its own 500.
      {:error, :audit_chain_append_failed} = error ->
        error

      {:error, %Ecto.Changeset{}} = error ->
        error
    end
  end

  @doc """
  POST /api/v1/stories/:id/renew-claim

  The assigned agent extends its claim's lease, presenting the claim_epoch its claim
  returned (#803).
  """
  def renew_claim(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key

    opts =
      AuditContext.from_conn(conn)
      |> Keyword.merge(agent_id: api_key.agent_id)

    with {:ok, epoch} when is_integer(epoch) <- claim_epoch_param(params, :required),
         {:ok, story} <-
           Progress.renew_claim(
             api_key.tenant_id,
             story_id,
             Keyword.put(opts, :claim_epoch, epoch)
           ) do
      json(conn, %{story: story, next_actions: StateMachine.next_actions(story, api_key.role)})
    else
      error ->
        log_renew_refused(api_key, story_id, params, error)
        error
    end
  end

  # Issue #815: a claimant whose renewals are refused is about to lose its claim to the
  # reclaimer, and without this line nothing records why. The current epoch is read only
  # on this refusal path.
  defp log_renew_refused(api_key, story_id, params, error) do
    # The story id is the path segment and the epoch the body's: both are the client's, so
    # each is logged only in the shape it claims (`Loopctl.LogValue`).
    logged_story_id = LogValue.uuid(story_id)
    presented = LogValue.epoch(Map.get(params, "claim_epoch"))

    current =
      if is_binary(logged_story_id),
        do: Progress.current_claim_epoch(api_key.tenant_id, logged_story_id)

    Logger.info(
      "renew_claim refused: reason=#{inspect(refusal_reason(error))} " <>
        "story_id=#{inspect(logged_story_id)} " <>
        "presented_epoch=#{inspect(presented)} current_epoch=#{inspect(current)} " <>
        "agent_id=#{inspect(api_key.agent_id)} tenant_id=#{api_key.tenant_id}",
      story_id: logged_story_id,
      claim_epoch: presented
    )
  end

  defp refusal_reason({:error, reason}) when is_atom(reason), do: reason
  defp refusal_reason({:error, reason, _message}), do: reason
  defp refusal_reason({:error, %Ecto.Changeset{}}), do: :invalid_changeset
  defp refusal_reason(other), do: other

  # --- Private helpers ---

  # `:optional` (start/report): absent is fine. `:required` (renew-claim): absent is a 400.
  # A JSON integer only — a numeric string is refused rather than coerced, so a client
  # never learns to send the epoch in a shape the runner channel will not accept.
  defp claim_epoch_param(params, mode) do
    case {Map.get(params, "claim_epoch"), mode} do
      {nil, :optional} -> {:ok, nil}
      {epoch, _mode} when is_integer(epoch) and epoch >= 0 -> {:ok, epoch}
      _ -> claim_epoch_error()
    end
  end

  defp invalid_claim_epoch?(params),
    do: match?({:error, _, _}, claim_epoch_param(params, :optional))

  defp put_claim_epoch(opts, params) do
    with {:ok, epoch} <- claim_epoch_param(params, :optional) do
      {:ok, Keyword.put(opts, :claim_epoch, epoch)}
    end
  end

  defp claim_epoch_error,
    do: {:error, :bad_request, "claim_epoch must be a non-negative integer"}

  defp extract_artifact_params(%{"artifact" => artifact}) when is_map(artifact) do
    %{
      "artifact_type" => artifact["artifact_type"],
      "path" => artifact["path"],
      "exists" => artifact["exists"],
      "details" => artifact["details"]
    }
  end

  defp extract_artifact_params(_), do: nil

  # Resolves the caller's dispatch identity SERVER-SIDE from the authenticating
  # key. Never accepts a client-supplied dispatch id or lineage: a self-attested
  # lineage would defeat both the capability binding and the self-* custody gates.
  #
  # Returns `[lineage: []]` for a key not minted by a dispatch (a legacy env-var
  # key). `[]` is inert — it matches a cap minted for `[]` and is never a lineage
  # "match" for the custody gates (Dispatches.lineage_shares_prefix?/2), so such a
  # caller falls back to the agent-id checks rather than short-circuiting them.
  defp custody_identity(api_key) do
    case Dispatches.dispatch_for_api_key(api_key.tenant_id, api_key.id) do
      {:ok, dispatch} -> [dispatch_id: dispatch.id, lineage: dispatch.lineage_path]
      :none -> [lineage: []]
    end
  end

  # Accepts the capability under either key, matching the convention already used
  # by LoopctlWeb.Plugs.RequireSignedClaim (require_signed_claim.ex:54).
  defp capability_param(params) do
    params["capability"] || params["cap_id"]
  end

  # #621: returns the story plus, when the transition minted one, the capability
  # the caller needs for its NEXT custody op — under a top-level `capability` key
  # rather than inside the story object, since it is a credential for the caller
  # and not story state. Absent (rather than null) when nothing was minted.
  defp respond_with_story(conn, story, role) do
    body = %{story: story, next_actions: StateMachine.next_actions(story, role)}

    body =
      case story.minted_capability do
        nil -> body
        cap -> Map.put(body, :capability, Capabilities.serialize(cap))
      end

    json(conn, body)
  end

  defp maybe_add_token_usage(opts, %{"token_usage" => token_usage}) when is_map(token_usage) do
    Keyword.put(opts, :token_usage, token_usage)
  end

  defp maybe_add_token_usage(opts, _params), do: opts
end
