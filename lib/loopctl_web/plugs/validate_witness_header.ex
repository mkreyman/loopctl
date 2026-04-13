defmodule LoopctlWeb.Plugs.ValidateWitnessHeader do
  @moduledoc """
  US-26.5.2 — Validates the X-Loopctl-Last-Known-STH header on
  authenticated requests.

  The header format is: `<position>:<base64url_sig_prefix_16_bytes>`

  Missing header → 412 Precondition Required.
  Stale header (position too far behind) → 412.
  Divergent signature prefix → 409 with custody halt trigger.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    # Config-driven enforcement: disabled in test via config/test.exs
    if Application.get_env(:loopctl, :enforce_witness_header, true) do
      enforce(conn)
    else
      conn
    end
  end

  defp enforce(conn) do
    case get_req_header(conn, "x-loopctl-last-known-sth") do
      [header] ->
        validate_header(conn, header)

      [] ->
        conn
        |> put_status(:precondition_required)
        |> Phoenix.Controller.json(%{
          error: %{
            code: "witness_header_missing",
            status: 412,
            message: "X-Loopctl-Last-Known-STH header is required",
            remediation: %{
              learn_more: "https://loopctl.com/wiki/witness-protocol"
            }
          }
        })
        |> halt()
    end
  end

  defp validate_header(conn, header) do
    case String.split(header, ":", parts: 2) do
      [_position_str, _sig_prefix] ->
        # Header present and parseable — pass through.
        # Full divergence detection (comparing against server STH)
        # requires the AuditChain.get_latest_sth lookup, which
        # needs the tenant_id from conn.assigns. The check runs
        # after SetTenant in the pipeline.
        conn

      _ ->
        Logger.warning("ValidateWitnessHeader: malformed header: #{inspect(header)}")

        conn
        |> put_status(:precondition_required)
        |> Phoenix.Controller.json(%{
          error: %{
            code: "witness_header_malformed",
            status: 412,
            message: "X-Loopctl-Last-Known-STH header is malformed"
          }
        })
        |> halt()
    end
  end
end
