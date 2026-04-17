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
  - `{:error, :must_contract_first}` -> 409 (claim before contracting)
  - `{:error, :must_claim_first}` -> 409 (start before claiming)
  - `{:error, :self_verify_blocked}` -> 409 (same agent implemented and tries to verify)
  - `{:error, :self_report_blocked}` -> 409 (implementer tries to report their own work)
  - `{:error, :self_review_blocked}` -> 409 (implementer tries to review their own work)
  - `{:error, :rate_limited}` -> 429 with retry_after_seconds from header
  - `{:error, %Ecto.Changeset{}}` -> 422 with field-level details
  - `{:error, :bad_request, message}` -> 400 with custom message
  - `{:error, :unprocessable_entity, message}` -> 422 with custom message
  """

  use LoopctlWeb, :controller

  alias Ecto.Changeset

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

  defp unique_constraint_violation?(%Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique
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
