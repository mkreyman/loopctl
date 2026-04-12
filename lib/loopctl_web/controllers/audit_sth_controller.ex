defmodule LoopctlWeb.AuditSthController do
  @moduledoc """
  US-26.1.2 — Public endpoint for retrieving Signed Tree Heads.

  No authentication required. STHs are designed for public verification.
  """

  use LoopctlWeb, :controller

  alias Loopctl.AuditChain

  @doc """
  GET /api/v1/audit/sth/:tenant_id

  Returns the latest STH for the tenant. Optionally, pass `?at=<position>`
  to get the smallest STH covering that chain position.
  """
  def show(conn, %{"tenant_id" => tenant_id} = params) do
    sth =
      case Map.get(params, "at") do
        nil ->
          AuditChain.get_latest_sth(tenant_id)

        at_str ->
          case Integer.parse(at_str) do
            {position, ""} -> AuditChain.get_sth_at_position(tenant_id, position)
            _ -> nil
          end
      end

    case sth do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Not found", status: 404}})

      sth ->
        json(conn, %{
          data: %{
            tenant_id: sth.tenant_id,
            chain_position: sth.chain_position,
            merkle_root: Base.url_encode64(sth.merkle_root, padding: false),
            signed_at: sth.signed_at,
            signature: Base.url_encode64(sth.signature, padding: false)
          }
        })
    end
  end
end
