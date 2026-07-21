defmodule LoopctlWeb.CustodyClaimController do
  @moduledoc """
  US-41.7 (AC-41.7.5) — the agent-readable custody-claim surface. JSON only; no
  UI, matching the epic's agent-native design principle.

  ## Role: `:agent` (read)

  A claim is a READ of the tenant's own recorded egress facts, and the whole
  point is that an agent can verify a harvest AFTER the fact with the key it
  already holds — the same argument that puts `GET /egress/posture` at `:agent`.
  It grants no destructive capability and no ability to weaken any gate.

  ## Failure surface

  `GET /custody/failures` lists entries whose chain append was dropped. A
  recording failure must be legible rather than silently absent, because a
  missing claim must never read as a satisfied one.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Custody

  action_fallback LoopctlWeb.FallbackController

  tags(["Custody"])

  @json "application/json"
  @free_object %OpenApiSpex.Schema{type: :object, additionalProperties: true}

  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:show, :failures]

  operation(:show,
    summary: "Egress custody claim for an article or memory",
    description:
      "Returns the recorded per-operation egress postures for one article or memory row " <>
        "and the aggregate claim over them. Three states: 'no_claim_recorded', " <>
        "'claim_pending', or 'claim_recorded' (itself 'complete' or 'incomplete'). The " <>
        "claim attests ONLY to the endpoints loopctl called for the recorded operations on " <>
        "this row, on the egress paths listed in `coverage` — never to what those " <>
        "endpoints did with the data afterwards, and never to a path listed as uncovered. " <>
        "Role :agent.",
    parameters: [
      subject_type: [in: :path, type: :string, description: "article | memory", required: true],
      subject_id: [in: :path, type: :string, description: "Row UUID", required: true]
    ],
    responses: %{
      200 => {"Custody claim", @json, @free_object},
      400 => {"Invalid subject type", @json, Schemas.ErrorResponse},
      401 => {"Unauthorized", @json, Schemas.ErrorResponse}
    }
  )

  def show(conn, %{"subject_type" => subject_type, "subject_id" => subject_id}) do
    key = conn.assigns.current_api_key

    case Custody.claim(key.tenant_id, subject_type, subject_id) do
      {:ok, claim} ->
        json(conn, %{data: claim})

      {:error, :invalid_subject_type} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: %{
            message: "subject_type must be one of: article, memory",
            code: "invalid_subject_type",
            status: 400
          }
        })
    end
  end

  operation(:failures,
    summary: "Custody posture entries whose chain append was dropped",
    description:
      "Recording failures are surfaced, never silently dropped: each entry here degrades " <>
        "its row's claim to 'incomplete'. Role :agent.",
    responses: %{
      200 => {"Failed custody posture entries", @json, @free_object},
      401 => {"Unauthorized", @json, Schemas.ErrorResponse}
    }
  )

  def failures(conn, _params) do
    key = conn.assigns.current_api_key

    entries =
      key.tenant_id
      |> Custody.list_failures()
      |> Enum.map(
        &%{
          subject_type: &1.subject_type,
          subject_id: &1.subject_id,
          operation_sequence: &1.operation_sequence,
          operation: &1.operation,
          occurred_at: &1.occurred_at,
          local_endpoints_only: &1.local_endpoints_only,
          failure_reason: &1.failure_reason
        }
      )

    json(conn, %{data: entries, meta: %{count: length(entries)}})
  end
end
