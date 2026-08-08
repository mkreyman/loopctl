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
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Capabilities
  alias Loopctl.Dispatches
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

  plug LoopctlWeb.Plugs.RequireRole,
       [exact_role: [:agent, :orchestrator]] when action in [:contract]

  plug LoopctlWeb.Plugs.RequireRole,
       [exact_role: [:agent, :orchestrator]] when action in [:report]

  # LCP-1 §9.3: under the `signed` custody profile, an enrolled caller's report
  # claim must carry a valid signature. No-op under the default `bearer` profile.
  plug LoopctlWeb.Plugs.RequireSignedClaim, [gate: "report"] when action in [:report]

  plug LoopctlWeb.Plugs.RequireRole,
       [exact_role: :agent] when action in [:claim, :start, :request_review, :unclaim]

  # US-26.7.1 — work-breakdown surface requires a human-anchored tenant.
  plug LoopctlWeb.Plugs.RequireHumanAnchor
       when action in [:contract, :claim, :start, :report, :request_review, :unclaim]

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
        "unstartable. A transient mint failure is 503 `capability_mint_failed` with " <>
        "`retry-after`; an audit key that is ABSENT or SUPERSEDED is 503 " <>
        "`capability_key_unavailable` with none, because only an operator can clear it.",
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
        "403 missing_capability. A tenant whose audit key cannot be USED at all (cleared, " <>
        "or replaced without an archived history row) yields 503 " <>
        "`capability_key_unavailable` instead — recovery cannot fix that one, only an " <>
        "operator can. A pre-v2 tenant with no audit key needs no capability.",
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
           }
         }
       }},
    responses: %{
      200 => {"Story started", "application/json", Schemas.StoryStatusResponse},
      403 =>
        {"Not assigned agent, or missing/rejected capability", "application/json",
         Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 => {"Invalid transition", "application/json", Schemas.ErrorResponse},
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
        "Does NOT change status. Fires a story.review_requested webhook event.",
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
           }
         }
       }},
    responses: %{
      200 => {"Story reported done", "application/json", Schemas.StoryStatusResponse},
      403 => {"Missing or rejected capability", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 =>
        {"Invalid transition or self-report blocked", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:unclaim,
    summary: "Unclaim story",
    description: "Agent releases a story back to pending.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    responses: %{
      200 => {"Story unclaimed", "application/json", Schemas.StoryStatusResponse},
      403 => {"Not assigned agent", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 => {"Invalid transition", "application/json", Schemas.ErrorResponse},
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
      # they just have to reach it.
      {:error, reason} when is_capability_error(reason) ->
        {:error, reason}

      {:error, :must_contract_first} ->
        {:error, :must_contract_first}

      {:error, :must_claim_first} ->
        {:error, :must_claim_first}

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

    if is_nil(api_key.agent_id) do
      {:error, :unprocessable_entity, "Agent ID required for chain-of-custody"}
    else
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
             :missing_assigned_agent
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
    opts = Keyword.merge(AuditContext.from_conn(conn), agent_id: api_key.agent_id)

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
    end
  end

  # --- Private helpers ---

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
