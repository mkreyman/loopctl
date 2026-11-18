defmodule LoopctlWeb.ChangeEventController do
  @moduledoc """
  The chg change-events webhook (US-47.3, Epic 47 PRD §5) and its cursor read (US-50.2):
  `POST /api/v1/change_events/:source_id` and `GET /api/v1/change_events/:source_id/cursor`.

  Machine endpoints: a fleet machine's chg outbox sender calls them, never a session, so they
  have no MCP tool (the same exemption as the GitHub intake webhook and the runner socket).
  Not authenticated by API key, so they carry no lineage and can perform no custody act. They
  are authenticated by `X-Chg-Signature`, an HMAC over `"<X-Chg-Timestamp>.<raw body>"` (a
  POST) or `"<X-Chg-Timestamp>.GET.<path>?<query>"` (a GET) under the source's
  `change_events_secret`, checked before anything is parsed (`Loopctl.Changes.Events`). The
  raw body is captured ahead of `Plug.Parsers` by `LoopctlWeb.Plugs.IntakeRawBody`; if it is
  absent the event is refused like any other unauthenticated one.

  Neither request makes an outbound call (AC-47.3.5): each answers from its own transaction.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Changes.Events
  alias Loopctl.Changes.ReviewDispatches
  alias Loopctl.Changes.Signature
  alias Loopctl.Dispatches
  alias LoopctlWeb.Plugs.IntakeRawBody
  alias OpenApiSpex.Schema

  action_fallback LoopctlWeb.FallbackController

  tags(["Change protocol"])

  @max_body_bytes Events.max_body_bytes()
  @window_seconds Signature.window_seconds()

  # The 500's message, held here for the response and the operation spec alike.
  @apply_failed_message "The event could not be recorded. Redeliver it."

  @cursor_schema %Schema{
    type: :object,
    required: [:change_id, :applied_through, :held],
    properties: %{
      change_id: %Schema{type: :string},
      applied_through: %Schema{
        type: :integer,
        description: "Every event_seq at or below this is applied; resend from the next"
      },
      held: %Schema{
        type: :array,
        items: %Schema{type: :integer},
        description:
          "Stored event_seqs waiting behind a gap, lowest first, at most 500. Non-empty " <>
            "means the sender should resend from applied_through + 1."
      }
    }
  }

  operation(:create,
    summary: "Receive a chg change event (fleet chg sender only)",
    description:
      "A fleet machine's chg outbox delivers each change's event log here, one event per " <>
        "request. A machine " <>
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
        "a no-op, so it never leaves a gap. Every 200 carries the change's `cursor`: when " <>
        "its `held` list is non-empty, resend from `applied_through + 1`. Lock contention " <>
        "is 503 `busy` with `retry-after`: redeliver. Throttled per client IP (429).",
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
           required: [:status, :outcome, :duplicate, :applied_seq, :cursor],
           properties: %{
             status: %Schema{type: :string, enum: ["ok"]},
             outcome: %Schema{type: :string, enum: ["applied", "held", "duplicate"]},
             duplicate: %Schema{type: :boolean},
             applied_seq: %Schema{
               type: :integer,
               description: "The highest event_seq of this change now applied"
             },
             cursor: @cursor_schema
           }
         }},
      400 => {"Signed but malformed: `invalid_event`", "application/json", Schemas.ErrorResponse},
      401 => {"`invalid_signature`", "application/json", Schemas.ErrorResponse},
      409 =>
        {"`event_conflict`: this key is stored with different content", "application/json",
         Schemas.ErrorResponse},
      413 => {"`payload_too_large`", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      500 =>
        {"`change_event_failed`: nothing was recorded. #{@apply_failed_message}",
         "application/json", Schemas.ErrorResponse},
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
      {:ok, %{outcome: outcome, applied_seq: applied_seq, cursor: cursor}} ->
        json(conn, %{
          status: "ok",
          outcome: outcome,
          duplicate: outcome == :duplicate,
          applied_seq: applied_seq,
          cursor: cursor
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
        error(conn, 500, "change_event_failed", @apply_failed_message)
    end
  end

  operation(:cursor,
    summary: "Read a chg change's cursor (fleet chg sender only)",
    description:
      "What loopctl holds of one change, for a sender deciding what to resend (US-50.2). " <>
        "loopctl never pulls events: a sender that sees `held` non-empty resends from " <>
        "`applied_through + 1`. A machine endpoint with no MCP tool. Signed like the event " <>
        "POST, but over `\"<X-Chg-Timestamp>.GET.<path>?<query>\"` with the path and query " <>
        "exactly as sent. Every refusal is the same 401 `invalid_signature` the POST gives. " <>
        "A change loopctl has never seen answers `applied_through: 0, held: []`, never a " <>
        "404, so a change id cannot be probed. A missing `change_id` is 400 " <>
        "`change_id_required`. Throttled per client IP (429).",
    security: [],
    parameters: [
      source_id: [in: :path, type: :string, description: "Intake source UUID"],
      change_id: [in: :query, type: :string, required: true, description: "The change id"],
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
        description: "sha256=<hex HMAC-SHA256 of \"<timestamp>.GET.<path>?<query>\">"
      ]
    ],
    responses: %{
      200 => {"The change's cursor", "application/json", @cursor_schema},
      400 => {"`change_id_required`", "application/json", Schemas.ErrorResponse},
      401 => {"`invalid_signature`", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      503 => {"`busy`: retry after `retry-after`", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc "GET /api/v1/change_events/:source_id/cursor"
  def cursor(conn, %{"source_id" => source_id} = params) do
    input = %{
      path: conn.request_path,
      query: conn.query_string,
      change_id: params["change_id"],
      timestamp: header(conn, "x-chg-timestamp"),
      signature: header(conn, "x-chg-signature")
    }

    case Events.read_cursor(source_id, input) do
      {:ok, view} ->
        json(conn, view)

      {:error, :unauthorized} ->
        unauthorized(conn)

      {:error, {:bad_request, code}} ->
        error(conn, 400, code, "The change_id query parameter is required.")

      {:error, :busy} ->
        {:error, :busy}

      {:error, _reason} ->
        error(conn, 500, "change_cursor_failed", "The cursor could not be read. Retry.")
    end
  end

  operation(:review_dispatch,
    summary: "Mint a chg review dispatch under the source's root (fleet chgd only)",
    description:
      "US-50.3. A fleet machine's chgd asks for the key a review of one `(change_id, " <>
        "revision)` records its verdict with. A machine endpoint with no MCP tool, signed " <>
        "exactly like the event POST. loopctl mints an `:orchestrator` child of the source's " <>
        "`chg_root_dispatch_id`, attributed to the per-source system agent, living " <>
        "#{Dispatches.max_expires_seconds()} seconds. It records a review on that revision " <>
        "(`commit_sha` = the revision's sha) and is refused claim, report, verify and reject. " <>
        "Whoever holds the source's `change_events_secret` can mint these; the root key's " <>
        "expiry does not matter, its revocation does. Every authentication refusal, a revoked " <>
        "root included, is the event POST's 401 `invalid_signature`. The revision must have " <>
        "an applied `submitted` event from this source (422 `revision_not_submitted`). One " <>
        "live dispatch per revision: a repeat request revokes the earlier dispatch and mints " <>
        "afresh, so a lost answer is safe to retry, until any of them has recorded a review, " <>
        "after which it is 409 `review_already_recorded`. A tenant under a custody halt is " <>
        "503 `tenant_halted`. Lock contention is 503 `busy`.",
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
      {"The review to mint for", "application/json",
       %Schema{
         type: :object,
         required: [:change_id, :revision],
         properties: %{
           change_id: %Schema{type: :string},
           revision: %Schema{type: :integer, minimum: 1}
         }
       }},
    responses: %{
      201 =>
        {"Minted", "application/json",
         %Schema{
           type: :object,
           required: [:dispatch_id, :api_key, :expires_at],
           properties: %{
             dispatch_id: %Schema{type: :string, format: :uuid},
             api_key: %Schema{type: :string, description: "Shown once"},
             expires_at: %Schema{type: :string, format: :"date-time"}
           }
         }},
      400 => {"`invalid_request`", "application/json", Schemas.ErrorResponse},
      401 => {"`invalid_signature`", "application/json", Schemas.ErrorResponse},
      409 => {"`review_already_recorded`", "application/json", Schemas.ErrorResponse},
      422 => {"`revision_not_submitted`", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      503 =>
        {"`busy`: retry after `retry-after`; or `tenant_halted`", "application/json",
         Schemas.ErrorResponse}
    }
  )

  @rejection_messages %{
    "revision_not_submitted" =>
      "No submitted event from this source has been applied for that change and revision.",
    "review_already_recorded" =>
      "A review dispatch for this revision has already recorded its verdict; it is not re-minted.",
    "tenant_halted" =>
      "The tenant's custody operations are halted; no review dispatch is minted until it clears."
  }

  @doc "POST /api/v1/change_events/:source_id/review_dispatch"
  def review_dispatch(conn, %{"source_id" => source_id}) do
    case conn.private[IntakeRawBody.private_key()] do
      raw_body when is_binary(raw_body) ->
        input = %{
          raw_body: raw_body,
          timestamp: header(conn, "x-chg-timestamp"),
          signature: header(conn, "x-chg-signature")
        }

        answer_review_dispatch(conn, ReviewDispatches.request(source_id, input))

      nil ->
        Logger.error(
          "review dispatch: no raw body captured; IntakeRawBody is not mounted ahead of parsers"
        )

        unauthorized(conn)
    end
  end

  defp answer_review_dispatch(conn, {:ok, minted}),
    do: conn |> put_status(201) |> json(minted)

  defp answer_review_dispatch(conn, {:error, :unauthorized}), do: unauthorized(conn)

  defp answer_review_dispatch(conn, {:error, {:bad_request, code}}),
    do: error(conn, 400, code, "The signed body must be {\"change_id\": ..., \"revision\": n}.")

  defp answer_review_dispatch(conn, {:error, {:rejected, status, code}}),
    do: error(conn, status, code, Map.fetch!(@rejection_messages, code))

  defp answer_review_dispatch(_conn, {:error, :busy}), do: {:error, :busy}

  defp answer_review_dispatch(conn, {:error, _reason}),
    do: error(conn, 500, "review_dispatch_failed", "The review dispatch could not be minted.")

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
