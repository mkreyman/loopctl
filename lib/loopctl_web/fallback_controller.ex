defmodule LoopctlWeb.FallbackController do
  @moduledoc """
  Centralized error handling for all API controllers.

  Maps error tuples and exceptions to consistent JSON error responses.
  Controllers use `action_fallback LoopctlWeb.FallbackController` to
  delegate error rendering to this module.

  ## Supported error shapes

  - `{:error, :not_found}` -> 404
  - `{:error, :unauthorized}` -> 401
  - `{:error, :forbidden}` -> 403
  - `{:error, :conflict}` -> 409
  - `{:error, :already_claimed}` -> 409 (US-40.B1: a coordination handoff ref was already claimed by another agent)
  - `{:error, :ambiguous_resolution}` -> 409 (a fuzzy identifier matched >1 active project)
  - `{:error, :must_contract_first}` -> 409 (claim before contracting)
  - `{:error, :must_claim_first}` -> 409 (start before claiming)
  - `{:error, :self_verify_blocked}` -> 409 (same agent implemented and tries to verify)
  - `{:error, :self_report_blocked}` -> 409 (implementer tries to report their own work)
  - `{:error, :self_review_blocked}` -> 409 (implementer tries to review their own work)
  - `{:error, :missing_assigned_agent}` -> 409 (reported_done story has no assigned agent/dispatch lineage; custody chain broken)
  - `{:error, :unresolvable_dispatch_lineage}` -> 409 (a dispatch the story references — implementer, or verifier on verify — could not be resolved; custody gate failed closed on an integrity error, tenant NOT halted)
  - `{:error, :rate_limited}` -> 429 with retry_after_seconds from header
  - `{:error, :ingestion_backlog_exceeded, retry_after}` -> 429 with `Retry-After` header and
    a machine-readable `code: "ingestion_backlog_exceeded"` (US-36.3 ingest backpressure —
    the backlog is at/over threshold OR it could not be measured and the bounded fail-open
    allowance is spent; distinct from the generic Hammer request-rate 429, which has no `code`)
  - `{:error, :ingestion_gate_unavailable, retry_after}` -> 503 with `Retry-After` and
    `code: "ingestion_gate_unavailable"` (the same gate refusing for a fault that is NOT
    backlog pressure, so the refusal does not claim a backlog nobody measured)
  - `{:error, %Ecto.Changeset{}}` -> 422 with field-level details
  - `{:error, :bad_request, message}` -> 400 with custom message
  - `{:error, :unprocessable_entity, message}` -> 422 with custom message
  - `{:error, :audit_write_failed}` -> 500 (US-39.7 redact path: a hard delete whose
    audit insert failed, rolling the delete back — never masked as a 404)
  - `{:error, %Postgrex.Error{}}` -> 504/503/500 by SQLSTATE class (US-27.3)
  - `{:error, %DBConnection.ConnectionError{}}` -> 503 with Retry-After (US-27.3)
  """

  use LoopctlWeb, :controller

  alias Ecto.Changeset
  alias Loopctl.ApiSpec.Messages
  alias Loopctl.Llm.Remediation
  alias LoopctlWeb.DBError
  alias LoopctlWeb.DBErrorLogger

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{status: 404, message: "Not found"}})
  end

  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: %{status: 401, message: "Unauthorized"}})
  end

  def call(conn, {:error, :forbidden}) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: %{status: 403, message: "Forbidden"}})
  end

  def call(conn, {:error, :conflict}) do
    conn
    |> put_status(:conflict)
    |> json(%{error: %{status: 409, message: "Conflict"}})
  end

  # A fuzzy identifier (repo_url or name) matched more than one active project,
  # so resolution refused to silently attach new work to whichever is older.
  def call(conn, {:error, :ambiguous_resolution}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "ambiguous_resolution",
        message:
          "The supplied identifier matches more than one active project. " <>
            "Disambiguate with an exact slug (or a fully-qualified, single-host repo_url)."
      }
    })
  end

  # US-40.B1: a coordination handoff `ref` is already claimed — the loser of an
  # INSERT-to-claim race on the (tenant_id, project_id, ref) unique index. A distinct
  # `code` so a losing agent learns the ref is taken and moves on (never confused with
  # the generic 409 conflict). The message does NOT assert "another agent": the true
  # owner re-claiming its own ACTIVE ref is served idempotently (200) upstream, so a
  # 409 here means either a PEER owns the ref or the caller already completed it — in
  # both cases the caller should move on rather than retry the same ref.
  def call(conn, {:error, :already_claimed}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "already_claimed",
        message:
          "This ref is already claimed (by another agent, or already completed by you). Do not retry the same ref; move on to other work."
      }
    })
  end

  def call(conn, {:error, {:invalid_transition, ctx}}) do
    current_agent = ctx |> Map.get(:current_agent_status) |> to_string()
    current_verified = ctx |> Map.get(:current_verified_status) |> to_string()
    attempted = Map.get(ctx, :attempted_action, "transition")
    hint = Map.get(ctx, :hint)

    message =
      if hint do
        "Cannot #{attempted}: story is in agent_status='#{current_agent}', " <>
          "verified_status='#{current_verified}'. #{hint}"
      else
        "Cannot #{attempted}: story is in agent_status='#{current_agent}', " <>
          "verified_status='#{current_verified}'"
      end

    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        message: message,
        context: %{
          current_agent_status: current_agent,
          current_verified_status: current_verified,
          attempted_action: attempted
        }
      }
    })
  end

  def call(conn, {:error, {:contract_mismatch, ctx}}) do
    expected = Map.get(ctx, :expected_ac_count)
    provided = Map.get(ctx, :provided_ac_count)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        message:
          "Contract mismatch: expected ac_count #{expected} but got #{provided}. " <>
            "Story has #{expected} acceptance criteria.",
        context: %{expected_ac_count: expected, provided_ac_count: provided}
      }
    })
  end

  def call(conn, {:error, :must_contract_first}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        message:
          "Story must be contracted before claiming. " <>
            "Call POST /stories/:id/contract first."
      }
    })
  end

  def call(conn, {:error, :must_claim_first}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        message:
          "Story must be claimed before starting. " <>
            "Call POST /stories/:id/claim first."
      }
    })
  end

  def call(conn, {:error, :self_verify_blocked}) do
    # L6: self-verify is a byzantine condition — halt the tenant
    halt_tenant_on_violation(conn, "self_verify_blocked")

    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "self_verify_blocked",
        message: "Cannot verify your own implementation. Custody operations halted.",
        remediation: %{learn_more: "https://loopctl.com/wiki/self-verify-blocked"}
      }
    })
  end

  def call(conn, {:error, :missing_assigned_agent}) do
    # INVARIANT 1: verify/review attempted on a custody-orphaned reported_done
    # story (no assigned agent, no dispatch lineage). This is a data-integrity /
    # custody-chain violation, NOT a byzantine self-verify attempt, so we do NOT
    # halt the tenant — we return a clear 409 so the caller re-establishes
    # provenance (the DB CHECK stories_reported_done_requires_agent makes this
    # unreachable for well-formed data).
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "missing_assigned_agent",
        message:
          "Story is reported_done but has no assigned agent or dispatch lineage. " <>
            "Its custody chain is broken, so it cannot be verified or reviewed. " <>
            "Re-establish provenance (claim/report or backfill) before proceeding.",
        remediation: %{learn_more: "https://loopctl.com/wiki/chain-of-custody"}
      }
    })
  end

  def call(conn, {:error, :unresolvable_dispatch_lineage}) do
    # A custody gate (report/review/verify) failed CLOSED because a dispatch this
    # story references — the implementer's (report/review/verify) or, on verify,
    # the verifier's — could not be resolved (e.g. it belongs to another tenant, or
    # the row is gone). This is a lineage-INTEGRITY failure, not a byzantine
    # self-claim attempt, so — like :missing_assigned_agent — we do NOT halt the
    # tenant; we return a clear 409 whose code names the real cause rather than
    # mislabeling it self_report/self_review/self_verify.
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "unresolvable_dispatch_lineage",
        message:
          "A dispatch referenced by this story could not be resolved, so the custody " <>
            "gate cannot prove the caller's lineage is separated from the implementer's. " <>
            "This is a lineage-integrity failure; re-establish the dispatch provenance " <>
            "before reporting, reviewing, or verifying.",
        remediation: %{learn_more: "https://loopctl.com/wiki/chain-of-custody"}
      }
    })
  end

  def call(conn, {:error, :self_report_blocked}) do
    halt_tenant_on_violation(conn, "self_report_blocked")

    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "self_report_blocked",
        message: "Cannot report your own implementation. Custody operations halted.",
        remediation: %{learn_more: "https://loopctl.com/wiki/self-report-blocked"}
      }
    })
  end

  def call(conn, {:error, :missing_capability}) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: %{
        status: 403,
        code: "missing_capability",
        message: "A capability token is required for this operation.",
        remediation: %{learn_more: "https://loopctl.com/wiki/capability-tokens"}
      }
    })
  end

  def call(conn, {:error, {:cap_rejected, reason}}) do
    halt_tenant_on_violation(conn, "cap_rejected")

    conn
    |> put_status(:forbidden)
    |> json(%{
      error: %{
        status: 403,
        code: "cap_rejected",
        message: "Capability token rejected: #{reason}. Custody operations halted.",
        remediation: %{learn_more: "https://loopctl.com/wiki/capability-tokens"}
      }
    })
  end

  def call(conn, {:error, :self_review_blocked}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        message:
          "Cannot review your own implementation. " <>
            "The reviewer agent must be different from the implementing agent."
      }
    })
  end

  def call(conn, {:error, :review_required}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        message:
          "Review evidence required. " <>
            "Include 'review_type' (e.g. 'enhanced', 'team', 'adversarial') and " <>
            "a non-empty 'summary' describing review findings. " <>
            "Verification without independent review is not allowed."
      }
    })
  end

  def call(conn, {:error, :review_not_conducted}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        message:
          "No review record found for this story. " <>
            "Run the review pipeline and call POST /stories/:id/review-complete " <>
            "before attempting to verify. " <>
            "The review must be completed AFTER the story was reported done."
      }
    })
  end

  def call(conn, {:error, :story_not_reported_done}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        message:
          "Story must be in reported_done status before a review record can be created. " <>
            "The agent must call POST /stories/:id/report first."
      }
    })
  end

  def call(conn, {:error, :rate_limited}) do
    retry_after = conn |> get_resp_header("retry-after") |> List.first() || "60"

    conn
    |> put_status(:too_many_requests)
    |> json(%{
      error: %{
        status: 429,
        message: "Too many requests. Retry after #{retry_after} seconds.",
        retry_after_seconds: String.to_integer(retry_after)
      }
    })
  end

  # US-36.3: batch-ingest backlog backpressure. The calling tenant's in-flight
  # :ingestion backlog is at/over the OBAN_INGEST_BACKLOG_MAX threshold, so the whole
  # batch was rejected all-or-nothing (ZERO jobs enqueued). A distinct `code` and the
  # `Retry-After` header make this unambiguously distinguishable from the Hammer
  # request-rate 429 (`message: "Rate limit exceeded"`, no `code`).
  def call(conn, {:error, :ingestion_backlog_exceeded, retry_after})
      when is_integer(retry_after) and retry_after > 0 do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_status(:too_many_requests)
    |> json(%{
      error: %{
        status: 429,
        code: "ingestion_backlog_exceeded",
        # #558: does NOT assert a measured backlog. This code now has TWO causes — the
        # backlog is genuinely at/over threshold, OR the server could not measure it and
        # the bounded fail-open allowance is spent. On the second, nothing was counted and
        # the real backlog may be zero, so the old copy ("already has too many ... once the
        # backlog drains") told the client a fact the server does not have, and pointed it
        # at a remedy that may not apply.
        # ONE definition, shared with the published OpenAPI example/body (#558) so the spec
        # cannot keep telling clients something this response stopped saying.
        message: Messages.ingestion_backlog_exceeded(retry_after),
        retry_after_seconds: retry_after
      }
    })
  end

  # #558: the SAME admission gate, refusing for a fault that is NOT backlog pressure — the
  # backlog could not be measured (a driver/config fault, or a defect in the counting code)
  # and the bounded fail-open allowance for it is spent. Answering `429
  # ingestion_backlog_exceeded` there asserted a backlog nobody counted and pointed the client
  # at a drain that a deterministic fault never reaches; this is a server-side condition, so it
  # gets the server-side status. `Retry-After` is still set — retrying is all the client can do.
  def call(conn, {:error, :ingestion_gate_unavailable, retry_after})
      when is_integer(retry_after) and retry_after > 0 do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_status(:service_unavailable)
    |> json(%{
      error: %{
        status: 503,
        code: "ingestion_gate_unavailable",
        message:
          "Ingestion is shedding for this tenant: the in-flight backlog could not be " <>
            "measured, and the bounded allowance for admitting unmeasured work is spent. " <>
            "This is a server-side condition, not your backlog. Nothing from this request " <>
            "was enqueued. Retry after #{retry_after} seconds.",
        retry_after_seconds: retry_after
      }
    })
  end

  # US-27.3: map a recognized DB exception (returned as a tuple by a controller
  # that rescued it) to a pinned status + safe body + structured error log
  # carrying the real SQLSTATE. NEVER leaks SQL/params/vectors/stack traces.
  def call(conn, {:error, %Postgrex.Error{} = error}), do: render_db_error(conn, error)

  def call(conn, {:error, %DBConnection.ConnectionError{} = error}),
    do: render_db_error(conn, error)

  # US-39.7 redact path: a channel-post HARD delete could not be durably recorded
  # in the audit trail, so the whole transaction rolled back and the post STILL
  # EXISTS. Fail-safe-on-security-path: a rolled-back redaction is NEVER reported as
  # a 404 ("already gone/handled") — that would let an agent believe a leaked secret
  # was removed when it was not. A 500 tells the caller the delete did NOT happen so
  # it retries the redaction.
  def call(conn, {:error, :audit_write_failed}) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{
      error: %{
        status: 500,
        code: "audit_write_failed",
        message:
          "The delete could not be recorded in the audit trail and was rolled back; " <>
            "the post still exists. Retry the request."
      }
    })
  end

  def call(conn, {:error, %Changeset{} = changeset}) do
    details = format_changeset_errors(changeset)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        message: changeset_error_message(changeset),
        details: details
      }
    })
  end

  # US-41.3 (AC-41.3.3): a chat-endpoint write refused by the credential rule or by
  # the config-time probe. The details map is built by `Loopctl.Llm.ChatProbe` and
  # is SECRET-FREE: it echoes the endpoint URL (the tenant's own declared host) and
  # a machine-readable `code` + ACTION-REQUIRED `remediation`, never the key.
  # Nothing was persisted.
  def call(conn, {:error, refusal, %{code: code, message: message} = details})
      when is_atom(refusal) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        code: code,
        message: message,
        remediation: Map.get(details, :remediation, %{})
      }
    })
  end

  def call(conn, {:error, :bad_request, message}) when is_binary(message) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{status: 400, message: message}})
  end

  def call(conn, {:error, :unprocessable_entity, message}) when is_binary(message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{status: 422, message: message}})
  end

  # Epic 28 (#179): mandatory BYO — a tenant knowledge-LLM operation was blocked
  # because the tenant has no Anthropic key configured. Carries a machine-readable
  # `code` PLUS a structured, self-service `remediation` (naming the `set_llm_config`
  # MCP tool, the REST endpoint, a copy-paste example, and the onboarding docs) so a
  # stranger agent can provision its own key from the response ALONE — no human
  # needed. Ingest is always the Anthropic path, so the missing credential is the
  # `api_key`.
  def call(conn, {:error, :no_api_key_configured, message}) when is_binary(message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        code: "no_api_key",
        message: message,
        remediation: Remediation.for_credential(:anthropic)
      }
    })
  end

  # US-27.3: shared DB-error rendering for both Postgrex.Error and
  # DBConnection.ConnectionError. `DBError.map/1` returns the pinned status,
  # safe client message, and the real SQLSTATE for the log. A non-DB error
  # never reaches here (the call/2 clauses only match the two DB structs).
  defp render_db_error(conn, error) do
    case DBError.map(error) do
      {:ok, mapping} ->
        DBErrorLogger.log(conn, error, mapping)

        conn
        |> maybe_put_retry_after(mapping.retry_after)
        |> put_status(mapping.status)
        |> json(%{
          error: %{status: mapping.status, code: mapping.code, message: mapping.message}
        })

      :unmapped ->
        # Should be unreachable: call/2 only dispatches here for the two DB
        # structs DBError knows. Re-raise rather than silently swallow.
        raise error
    end
  end

  defp maybe_put_retry_after(conn, nil), do: conn

  defp maybe_put_retry_after(conn, seconds) when is_integer(seconds) do
    put_resp_header(conn, "retry-after", Integer.to_string(seconds))
  end

  defp format_changeset_errors(changeset) do
    Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # Translate recognized changeset errors into actionable domain messages.
  # Falls back to the generic "Validation failed" when no domain rule matches
  # so callers still get the field-level details array.
  defp changeset_error_message(%Changeset{data: %mod{}} = changeset)
       when mod in [Loopctl.WorkBreakdown.Epic, Loopctl.WorkBreakdown.Story] do
    if unique_constraint_violation?(changeset) do
      number = Changeset.get_field(changeset, :number)
      entity = if mod == Loopctl.WorkBreakdown.Epic, do: "Epic", else: "Story"

      "#{entity} #{number} already exists in this project. " <>
        "Pick a different number, or use the import endpoint with `merge=true` " <>
        "to update the existing record."
    else
      "Validation failed"
    end
  end

  defp changeset_error_message(_), do: "Validation failed"

  # Epic/Story schemas put a single unique_constraint on (tenant_id,
  # project_id, number); Ecto auto-names the index to include "_number_index".
  # We detect the number-collision case by inspecting constraint_name so that
  # future schemas adding unrelated unique constraints (e.g. external_id,
  # slug) don't get falsely reported as "X already exists".
  defp unique_constraint_violation?(%Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique and
        (Keyword.get(opts, :constraint_name) || "") |> String.contains?("number")
    end)
  end

  # L6: halt the tenant's custody operations on trust violations
  defp halt_tenant_on_violation(conn, violation_type) do
    tenant_id =
      case conn.assigns do
        %{current_api_key: %{tenant_id: tid}} when not is_nil(tid) -> tid
        _ -> nil
      end

    if tenant_id do
      Loopctl.Tenants.halt_custody(tenant_id)

      Loopctl.AuditChain.append(tenant_id, %{
        action: "custody_halted",
        actor_lineage: [],
        entity_type: "tenant",
        entity_id: tenant_id,
        payload: %{"reason" => violation_type}
      })
    end
  rescue
    _ -> :ok
  end
end
