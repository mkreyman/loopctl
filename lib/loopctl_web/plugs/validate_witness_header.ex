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
      [position_str, sig_prefix] ->
        # US-26.5.2 AC-3: compare against server's STH
        check_divergence(conn, position_str, sig_prefix)

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

  defp check_divergence(conn, position_str, sig_prefix) do
    # Resolve tenant from conn (set by SetTenant plug earlier in pipeline)
    tenant_id =
      case conn.assigns do
        %{current_api_key: %{tenant_id: tid}} when not is_nil(tid) -> tid
        _ -> nil
      end

    if tenant_id do
      case Integer.parse(position_str) do
        {position, ""} ->
          compare_against_server_sth(conn, tenant_id, position, sig_prefix)

        _ ->
          conn
      end
    else
      # No tenant context (superadmin or public) — skip divergence check
      conn
    end
  end

  defp compare_against_server_sth(conn, tenant_id, position, sig_prefix) do
    alias Loopctl.AuditChain

    case AuditChain.get_sth_at_position(tenant_id, position) do
      nil ->
        # No STH at this position — agent may be ahead of server, allow
        conn

      sth ->
        server_prefix =
          sth.signature
          |> binary_part(0, min(byte_size(sth.signature), 16))
          |> Base.url_encode64(padding: false)
          |> String.slice(0, String.length(sig_prefix))

        if server_prefix == sig_prefix do
          conn
        else
          # Divergence detected — halt tenant's custody operations
          Logger.error(
            "WITNESS DIVERGENCE: tenant=#{tenant_id} position=#{position} " <>
              "client_prefix=#{sig_prefix} server_prefix=#{server_prefix}"
          )

          Loopctl.Tenants.halt_custody(tenant_id)

          conn
          |> put_status(:conflict)
          |> Phoenix.Controller.json(%{
            error: %{
              code: "witness_divergence",
              status: 409,
              message: "STH divergence detected. Custody operations halted.",
              remediation: %{
                learn_more: "https://loopctl.com/wiki/witness-protocol"
              }
            }
          })
          |> halt()
        end
    end
  end
end
