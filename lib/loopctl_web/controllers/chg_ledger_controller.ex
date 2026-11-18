defmodule LoopctlWeb.ChgLedgerController do
  @moduledoc """
  The chg ledger batch endpoint (US-50.1): `POST /api/v1/chg_ledger/:source_id`.

  A machine endpoint: a fleet machine's chg outbox sender calls it, never a session, so it has
  no MCP tool (the change-events webhook's exemption). It carries no API key, so no lineage and
  no custody act. It is authenticated exactly as `LoopctlWeb.ChangeEventController`'s POST,
  by `X-Chg-Signature` over `"<X-Chg-Timestamp>.<raw body>"` under the source's
  `change_events_secret`, through `Loopctl.Changes.Events.signed/4`. The raw body is captured
  ahead of `Plug.Parsers` by `LoopctlWeb.Plugs.IntakeRawBody`.

  The request makes no outbound call.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Changes.Ledger
  alias Loopctl.Changes.Signature
  alias LoopctlWeb.Plugs.IntakeRawBody
  alias OpenApiSpex.Schema

  action_fallback LoopctlWeb.FallbackController

  tags(["Change protocol"])

  @max_batch Ledger.max_batch()
  @max_body_bytes Ledger.max_body_bytes()
  @window_seconds Signature.window_seconds()
  @reasons Ledger.rejection_reasons()

  operation(:create,
    summary: "Receive a batch of chg ledger rows (fleet chg sender only)",
    description:
      "A fleet machine's chg outbox delivers its shadow-ledger rows here in batches " <>
        "(US-50.1). A machine endpoint with no MCP tool. No API key: signed exactly like " <>
        "`POST /api/v1/change_events/:source_id`, `X-Chg-Signature: sha256=<hex HMAC-SHA256>` " <>
        "over `\"<X-Chg-Timestamp>.<raw body>\"` keyed by the intake source's " <>
        "`change_events_secret`, the timestamp within #{@window_seconds} seconds. Every " <>
        "refusal (unknown, revoked or non-`chg` source, suspended tenant, bad signature or " <>
        "timestamp, a source whose chg root is no longer valid) is the same 401 " <>
        "`invalid_signature`, and writes nothing. The body may be at most #{@max_body_bytes} " <>
        "bytes (413 `payload_too_large`) and must be `{\"rows\": [...]}` with 1 to " <>
        "#{@max_batch} rows (400 `invalid_batch`). Each row is judged alone: a row that fails " <>
        "is listed in `rejected` by index with reason " <>
        Enum.map_join(@reasons, " or ", &"`#{&1}`") <>
        " and never fails the batch. Every row needs `v`, `kind`, `repo`, `host`, `at_ms`; " <>
        "`chg` and `gate` rows also need `sha`, `verdict` (pass|fail|error|skipped) and `ms`. " <>
        "A row naming another repository than the source's is `repo_mismatch`. Idempotent: " <>
        "a row already stored for this source and host is counted in `duplicates`. Lock " <>
        "contention is 503 `busy` with `retry-after`: resend. Throttled per client IP (429).",
    security: [],
    parameters: [
      source_id: [in: :path, type: :string, description: "Intake source UUID"],
      "X-Chg-Timestamp": [
        in: :header,
        type: :string,
        required: true,
        description: "Unix seconds at signing"
      ],
      "X-Chg-Signature": [
        in: :header,
        type: :string,
        required: true,
        description: "sha256=<hex HMAC-SHA256 of \"<timestamp>.<raw body>\">"
      ]
    ],
    request_body:
      {"Ledger batch", "application/json",
       %Schema{
         type: :object,
         required: [:rows],
         properties: %{
           rows: %Schema{
             type: :array,
             minItems: 1,
             maxItems: @max_batch,
             items: %Schema{type: :object, additionalProperties: true}
           }
         }
       }},
    responses: %{
      200 =>
        {"Batch recorded", "application/json",
         %Schema{
           type: :object,
           required: [:inserted, :duplicates, :rejected],
           properties: %{
             inserted: %Schema{type: :integer},
             duplicates: %Schema{type: :integer},
             rejected: %Schema{
               type: :array,
               items: %Schema{
                 type: :object,
                 required: [:index, :reason],
                 properties: %{
                   index: %Schema{type: :integer},
                   reason: %Schema{type: :string, enum: @reasons}
                 }
               }
             }
           }
         }},
      400 => {"Signed but malformed: `invalid_batch`", "application/json", Schemas.ErrorResponse},
      401 => {"`invalid_signature`", "application/json", Schemas.ErrorResponse},
      413 => {"`payload_too_large`", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      500 =>
        {"`chg_ledger_failed`: nothing was recorded; resend", "application/json",
         Schemas.ErrorResponse},
      503 => {"`busy`: resend after `retry-after`", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc "POST /api/v1/chg_ledger/:source_id"
  def create(conn, %{"source_id" => source_id}) do
    case conn.private[IntakeRawBody.private_key()] do
      raw_body when is_binary(raw_body) ->
        receive_batch(conn, source_id, raw_body)

      nil ->
        Logger.error(
          "chg ledger: no raw body captured; IntakeRawBody is not mounted ahead of parsers"
        )

        unauthorized(conn)
    end
  end

  defp receive_batch(conn, source_id, raw_body) do
    input = %{
      raw_body: raw_body,
      timestamp: header(conn, "x-chg-timestamp"),
      signature: header(conn, "x-chg-signature")
    }

    case Ledger.receive_batch(source_id, input) do
      {:ok, result} ->
        json(conn, result)

      {:error, :unauthorized} ->
        unauthorized(conn)

      {:error, {:bad_request, code}} ->
        error(
          conn,
          400,
          code,
          "The signed body must be {\"rows\": [...]} with 1 to #{@max_batch} rows."
        )

      {:error, :busy} ->
        {:error, :busy}

      {:error, _reason} ->
        error(conn, 500, "chg_ledger_failed", "The batch could not be recorded. Resend it.")
    end
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  # The same body the change-events webhook refuses with, so a refusal says nothing about
  # which endpoint or which check.
  defp unauthorized(conn),
    do: error(conn, 401, "invalid_signature", "The event could not be authenticated.")

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{status: status, code: code, message: message}})
  end
end
