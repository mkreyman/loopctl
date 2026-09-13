defmodule LoopctlWeb.GithubIntakeController do
  @moduledoc """
  The public GitHub webhook of the agent delivery loop (issue #803):
  `POST /api/v1/intake/github/:source_id`.

  Not authenticated by API key. Authenticated by `X-Hub-Signature-256`, an HMAC-SHA256
  over the RAW body under the intake source's secret, checked before the JSON is trusted
  (`Loopctl.Intake.receive_github_delivery/2`). The raw body is captured ahead of
  `Plug.Parsers` by `LoopctlWeb.Plugs.IntakeRawBody`; if it is absent the delivery is
  refused like any other unauthenticated one, because verifying anything else would verify
  the wrong bytes.

  Every authentication failure — unknown or revoked source, suspended tenant, missing or
  wrong signature, a payload for a different repository — gets the same 401 body.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Intake
  alias LoopctlWeb.Plugs.IntakeRawBody
  alias OpenApiSpex.Schema

  tags(["Intake"])

  @max_body_bytes Intake.max_body_bytes()

  operation(:deliver,
    summary: "Receive a GitHub webhook delivery",
    description:
      "The webhook URL of an intake source (`POST /api/v1/intake/sources` returns it). " <>
        "Configure the GitHub repository webhook with this URL, content type " <>
        "`application/json` (form-encoded is also accepted), the returned secret, and the " <>
        "`Issues` event. No API key: the request is authenticated by `X-Hub-Signature-256`, " <>
        "an HMAC-SHA256 of the raw body under the source's secret. The body may be at most " <>
        "#{@max_body_bytes} bytes (413 `payload_too_large`). The payload's " <>
        "`repository.full_name` must equal the source's repository. An unknown or revoked " <>
        "source, a suspended tenant, a missing or wrong signature and a repository mismatch " <>
        "are all answered with the same 401 `invalid_signature`. `X-GitHub-Delivery` is the " <>
        "idempotency key: a replayed or redelivered delivery changes nothing and answers " <>
        "200 with outcome `duplicate`. `ping` answers outcome `ping`; `issues` with action " <>
        "opened, edited, reopened, closed, labeled or unlabeled answers `recorded`; every other " <>
        "event " <>
        "or action is acknowledged with `ignored`. Issue text is stored only as untrusted " <>
        "data and never becomes a story. Throttled per client IP (429).",
    security: [],
    parameters: [
      source_id: [in: :path, type: :string, description: "Intake source UUID"],
      "X-Hub-Signature-256": [
        in: :header,
        type: :string,
        required: true,
        description: "sha256=<hex HMAC-SHA256 of the raw body>"
      ],
      "X-GitHub-Event": [in: :header, type: :string, required: true],
      "X-GitHub-Delivery": [in: :header, type: :string, required: true]
    ],
    request_body:
      {"GitHub webhook payload", "application/json",
       %Schema{type: :object, additionalProperties: true}},
    responses: %{
      200 =>
        {"Accepted", "application/json",
         %Schema{
           type: :object,
           required: [:status, :outcome],
           properties: %{
             status: %Schema{type: :string, enum: ["ok"]},
             outcome: %Schema{type: :string, enum: ["ping", "recorded", "ignored", "duplicate"]}
           }
         }},
      400 =>
        {"Signed but malformed: `invalid_payload` or `invalid_delivery_headers`",
         "application/json", Schemas.ErrorResponse},
      401 => {"`invalid_signature`", "application/json", Schemas.ErrorResponse},
      413 => {"`payload_too_large`", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "POST /api/v1/intake/github/:source_id"
  def deliver(conn, %{"source_id" => source_id}) do
    case conn.private[IntakeRawBody.private_key()] do
      raw_body when is_binary(raw_body) ->
        conn |> receive_delivery(source_id, raw_body)

      nil ->
        Logger.error(
          "intake: no raw body captured; IntakeRawBody is not mounted ahead of parsers"
        )

        unauthorized(conn)
    end
  end

  defp receive_delivery(conn, source_id, raw_body) do
    input = %{
      raw_body: raw_body,
      signature: header(conn, "x-hub-signature-256"),
      event: header(conn, "x-github-event"),
      delivery_id: header(conn, "x-github-delivery"),
      content_type: header(conn, "content-type")
    }

    case Intake.receive_github_delivery(source_id, input) do
      {:ok, outcome} ->
        json(conn, %{status: "ok", outcome: outcome})

      {:error, :unauthorized} ->
        unauthorized(conn)

      {:error, {:bad_request, code}} ->
        error(conn, 400, code, "The signed delivery is malformed.")

      {:error, reason} ->
        Logger.error("intake: delivery failed: #{inspect(reason)}")
        error(conn, 500, "intake_failed", "The delivery could not be recorded. Redeliver it.")
    end
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp unauthorized(conn),
    do: error(conn, 401, "invalid_signature", "The delivery could not be authenticated.")

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{status: status, code: code, message: message}})
  end
end
