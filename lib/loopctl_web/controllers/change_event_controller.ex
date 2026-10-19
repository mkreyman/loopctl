defmodule LoopctlWeb.ChangeEventController do
  @moduledoc """
  chg-server's event webhook (US-47.3, Epic 47 PRD §5):
  `POST /api/v1/change_events/:source_id`.

  A machine endpoint: chg-server calls it, never a session, so it has no MCP tool (the same
  exemption as the GitHub intake webhook and the runner socket). Not authenticated by API
  key, so it carries no lineage and can perform no custody act. It is authenticated by
  `X-Chg-Signature`, an HMAC over `"<X-Chg-Timestamp>.<raw body>"` under the source's
  `change_events_secret`, checked before the JSON is parsed
  (`Loopctl.Changes.Events.receive_push/3`). The raw body is captured ahead of `Plug.Parsers`
  by `LoopctlWeb.Plugs.IntakeRawBody`; if it is absent the event is refused like any other
  unauthenticated one.

  The request makes no outbound call (AC-47.3.5): it answers from its own transaction.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Changes.Events
  alias Loopctl.Changes.Signature
  alias LoopctlWeb.Plugs.IntakeRawBody
  alias OpenApiSpex.Schema

  action_fallback LoopctlWeb.FallbackController

  tags(["Change protocol"])

  @max_body_bytes Events.max_body_bytes()
  @window_seconds Signature.window_seconds()

  operation(:create,
    summary: "Receive a chg change event (chg-server only)",
    description:
      "chg-server delivers each change's event log here, one event per request. A machine " <>
        "endpoint with no MCP tool. No API key: the request is authenticated by " <>
        "`X-Chg-Signature: sha256=<hex HMAC-SHA256>` over `\"<X-Chg-Timestamp>.<raw body>\"` " <>
        "keyed by the intake source's `change_events_secret`, with `X-Chg-Timestamp` in unix " <>
        "seconds and within #{@window_seconds} seconds of loopctl's clock. An unknown, " <>
        "revoked or non-`chg` source, a suspended tenant, a missing or wrong signature, a " <>
        "timestamp outside the window, an envelope naming another repository and a source " <>
        "whose `chg_root_dispatch_id` is no longer a parentless, unrevoked orchestrator root " <>
        "of the tenant are ALL answered with the same 401 `invalid_signature`, and write " <>
        "nothing. The body may be at most #{@max_body_bytes} bytes (413 " <>
        "`payload_too_large`). Body: the v1 envelope `{v, repo, change_id, event_seq, kind, " <>
        "revision, sha, occurred_at, data}`. Idempotent on (repo, change_id, event_seq): a " <>
        "redelivery answers 200 with `duplicate: true` and applies nothing twice; the same " <>
        "key with different content is 409 `event_conflict`. Events apply in `event_seq` " <>
        "order per change: one arriving ahead of a gap answers 200 with outcome `held` and " <>
        "applies when the gap fills. A kind loopctl does not map is recorded and applied as " <>
        "a no-op, so it never leaves a gap. Lock contention is 503 `busy` with " <>
        "`retry-after`: redeliver. Throttled per client IP (429).",
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
      {"chg event envelope (v1)", "application/json",
       %Schema{
         type: :object,
         required: [
           :v,
           :repo,
           :change_id,
           :event_seq,
           :kind,
           :revision,
           :sha,
           :occurred_at,
           :data
         ],
         properties: %{
           v: %Schema{type: :integer, enum: [1]},
           repo: %Schema{type: :string, description: "owner/name; must be the source's"},
           change_id: %Schema{type: :string},
           event_seq: %Schema{type: :integer, minimum: 1},
           kind: %Schema{type: :string},
           revision: %Schema{type: :integer, minimum: 1},
           sha: %Schema{type: :string, pattern: "^[0-9a-f]{40}([0-9a-f]{24})?$"},
           occurred_at: %Schema{type: :string, format: :"date-time"},
           data: %Schema{type: :object, additionalProperties: true}
         }
       }},
    responses: %{
      200 =>
        {"Accepted", "application/json",
         %Schema{
           type: :object,
           required: [:status, :outcome, :duplicate, :applied_seq],
           properties: %{
             status: %Schema{type: :string, enum: ["ok"]},
             outcome: %Schema{type: :string, enum: ["applied", "held", "duplicate"]},
             duplicate: %Schema{type: :boolean},
             applied_seq: %Schema{
               type: :integer,
               description: "The highest event_seq of this change now applied"
             }
           }
         }},
      400 => {"Signed but malformed: `invalid_event`", "application/json", Schemas.ErrorResponse},
      401 => {"`invalid_signature`", "application/json", Schemas.ErrorResponse},
      409 =>
        {"`event_conflict`: this key is stored with different content", "application/json",
         Schemas.ErrorResponse},
      413 => {"`payload_too_large`", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      503 => {"`busy`: redeliver after `retry-after`", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc "POST /api/v1/change_events/:source_id"
  def create(conn, %{"source_id" => source_id}) do
    case conn.private[IntakeRawBody.private_key()] do
      raw_body when is_binary(raw_body) ->
        receive_event(conn, source_id, raw_body)

      nil ->
        Logger.error(
          "change events: no raw body captured; IntakeRawBody is not mounted ahead of parsers"
        )

        unauthorized(conn)
    end
  end

  defp receive_event(conn, source_id, raw_body) do
    input = %{
      raw_body: raw_body,
      timestamp: header(conn, "x-chg-timestamp"),
      signature: header(conn, "x-chg-signature")
    }

    case Events.receive_push(source_id, input) do
      {:ok, %{outcome: outcome, applied_seq: applied_seq}} ->
        json(conn, %{
          status: "ok",
          outcome: outcome,
          duplicate: outcome == :duplicate,
          applied_seq: applied_seq
        })

      {:error, :unauthorized} ->
        unauthorized(conn)

      {:error, {:bad_request, code}} ->
        error(conn, 400, code, "The signed event is not a valid v1 envelope.")

      {:error, :event_conflict} ->
        error(
          conn,
          409,
          "event_conflict",
          "An event with this change_id and event_seq is already stored with different content."
        )

      {:error, :busy} ->
        {:error, :busy}

      {:error, _reason} ->
        error(conn, 500, "change_event_failed", "The event could not be recorded. Redeliver it.")
    end
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp unauthorized(conn),
    do: error(conn, 401, "invalid_signature", "The event could not be authenticated.")

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{status: status, code: code, message: message}})
  end
end
