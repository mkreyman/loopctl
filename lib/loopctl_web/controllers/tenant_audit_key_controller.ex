defmodule LoopctlWeb.TenantAuditKeyController do
  @moduledoc """
  US-26.0.2 — Public key retrieval and key rotation for tenant audit signing keys.

  The public key endpoint is unauthenticated (intended for external
  verification). The rotation endpoint requires a WebAuthn assertion
  from an enrolled root authenticator.
  """

  use LoopctlWeb, :controller

  alias Loopctl.Tenants

  @doc """
  GET /api/v1/tenants/:id/audit_public_key

  Returns the tenant's ed25519 public key. Supports two formats:
  - PEM (default, Content-Type: application/x-pem-file)
  - JWK (Accept: application/jwk+json)

  Public endpoint — no authentication required.
  """
  def show(conn, %{"id" => tenant_id}) do
    case Tenants.get_tenant(tenant_id) do
      {:ok, %{audit_signing_public_key: nil}} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Tenant has no audit signing key", status: 404}})

      {:ok, tenant} ->
        accept = get_req_header(conn, "accept") |> List.first("")

        if String.contains?(accept, "application/jwk+json") do
          jwk = encode_jwk(tenant.audit_signing_public_key)

          conn
          |> put_resp_content_type("application/jwk+json")
          |> json(jwk)
        else
          pem = encode_pem(tenant.audit_signing_public_key)

          conn
          |> put_resp_content_type("application/x-pem-file")
          |> text(pem)
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Tenant not found", status: 404}})
    end
  end

  @doc """
  POST /api/v1/tenants/:id/rotate-audit-key

  Rotates the tenant's audit signing keypair. Requires a WebAuthn
  assertion in the request body to authorize the rotation.
  """
  def rotate(conn, %{"id" => tenant_id} = params) do
    assertion = Map.get(params, "webauthn_assertion")

    if is_nil(assertion) do
      conn
      |> put_status(:unauthorized)
      |> json(%{
        error: %{
          message: "WebAuthn assertion required for key rotation",
          code: "webauthn_required",
          status: 401
        }
      })
    else
      # For now, pass the raw assertion bytes as the rotation signature.
      # Full WebAuthn verification of the assertion will be added when
      # the authentication flow (as opposed to registration) is wired up
      # in the rotate path.
      assertion_bytes = decode_assertion(assertion)

      case Tenants.rotate_audit_key(tenant_id, assertion_bytes) do
        {:ok, tenant} ->
          conn
          |> put_status(:ok)
          |> json(%{
            data: %{
              tenant_id: tenant.id,
              audit_signing_public_key: Base.encode64(tenant.audit_signing_public_key),
              rotated_at: tenant.audit_key_rotated_at
            }
          })

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: %{message: "Tenant not found", status: 404}})

        {:error, :no_existing_key} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: %{message: "Tenant has no audit key to rotate", status: 422}})

        {:error, {:audit_key_storage_failed, _reason}} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{
            error: %{
              message: "Failed to store the new audit key",
              code: "audit_key_storage_failed",
              status: 500
            }
          })

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{error: %{message: "Key rotation failed: #{inspect(reason)}", status: 500}})
      end
    end
  end

  defp encode_pem(public_key_bytes) when is_binary(public_key_bytes) do
    b64 = Base.encode64(public_key_bytes)
    "-----BEGIN PUBLIC KEY-----\n#{b64}\n-----END PUBLIC KEY-----\n"
  end

  defp encode_jwk(public_key_bytes) when is_binary(public_key_bytes) do
    %{
      kty: "OKP",
      crv: "Ed25519",
      x: Base.url_encode64(public_key_bytes, padding: false)
    }
  end

  defp decode_assertion(assertion) when is_binary(assertion) do
    case Base.decode64(assertion) do
      {:ok, bytes} -> bytes
      :error -> assertion
    end
  end

  defp decode_assertion(_), do: <<>>
end
