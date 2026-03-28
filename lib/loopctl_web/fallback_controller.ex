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
  - `{:error, :rate_limited}` -> 429
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
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        message:
          "Cannot verify your own implementation. " <>
            "The orchestrator agent must be different from the implementing agent."
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

  def call(conn, {:error, :rate_limited}) do
    conn
    |> put_status(:too_many_requests)
    |> json(%{error: %{status: 429, message: "Too many requests"}})
  end

  def call(conn, {:error, %Changeset{} = changeset}) do
    details = format_changeset_errors(changeset)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{status: 422, message: "Validation failed", details: details}})
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
end
