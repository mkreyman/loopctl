defmodule LoopctlWeb.TenantAuditKeyController do
  @moduledoc """
  US-26.0.2 — Public key retrieval and key rotation for tenant audit signing keys.

  The public key endpoint is unauthenticated (intended for external
  verification). The rotation endpoint requires WebAuthn + user role.
  """

  use LoopctlWeb, :controller

  alias Loopctl.Tenants
  alias Loopctl.WebAuthn

  # Key management requires user role — agents must not rotate/bootstrap keys
  plug LoopctlWeb.Plugs.RequireRole, [role: :user] when action in [:rotate, :bootstrap]

  @doc """
  GET /api/v1/tenants/:id/audit_public_key

  Returns the tenant's ed25519 public key. Supports two formats:
  - PEM (default, Content-Type: application/x-pem-file)
  - JWK (Accept: application/jwk+json)

  Public endpoint — no authentication required.
  """
  def show(conn, %{"id" => tenant_id}) do
    case Tenants.get_tenant(tenant_id) do
      {:ok, %{audit_signing_public_key: pub}} when not is_nil(pub) ->
        accept = get_req_header(conn, "accept") |> List.first("")

        if String.contains?(accept, "application/jwk+json") do
          conn
          |> put_resp_content_type("application/jwk+json")
          |> json(encode_jwk(pub))
        else
          conn
          |> put_resp_content_type("application/x-pem-file")
          |> text(encode_pem(pub))
        end

      _ ->
        # Uniform 404 for missing tenant or missing key (prevents enumeration)
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Not found", status: 404}})
    end
  end

  @doc """
  POST /api/v1/tenants/:id/rotate-audit-key

  Rotates the tenant's audit signing keypair. Requires:
  1. Authenticated with user-role key (enforced by router pipeline)
  2. Caller owns the target tenant (checked here)
  3. Valid WebAuthn assertion in the request body
  """
  def rotate(conn, %{"id" => tenant_id} = params) do
    # Ownership check: caller must own the target tenant
    caller_tenant_id =
      case conn.assigns do
        %{current_api_key: %{tenant_id: tid}} -> tid
        _ -> nil
      end

    cond do
      caller_tenant_id != tenant_id ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: %{message: "Forbidden", status: 403}})

      is_nil(Map.get(params, "webauthn_assertion")) ->
        conn
        |> put_status(:unauthorized)
        |> json(%{
          error: %{
            message: "WebAuthn assertion required for key rotation",
            code: "webauthn_required",
            status: 401
          }
        })

      true ->
        do_rotate(conn, tenant_id, params)
    end
  end

  defp do_rotate(conn, tenant_id, params) do
    assertion_b64 = Map.fetch!(params, "webauthn_assertion")
    assertion_bytes = decode_assertion(assertion_b64)

    # Verify the WebAuthn assertion against the tenant's enrolled authenticators
    case verify_webauthn_assertion(tenant_id, assertion_bytes) do
      {:ok, _} ->
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
            |> json(%{error: %{message: "Not found", status: 404}})

          {:error, :no_existing_key} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: %{message: "No audit key to rotate", status: 422}})

          {:error, {:audit_key_storage_failed, _reason}} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{
              error: %{
                message: "Failed to store the new audit key. Please retry.",
                code: "audit_key_storage_failed",
                status: 500
              }
            })

          {:error, _reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: %{message: "Key rotation failed", status: 500}})
        end

      {:error, _} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{
          error: %{
            message: "WebAuthn assertion verification failed",
            code: "webauthn_failed",
            status: 401
          }
        })
    end
  end

  defp verify_webauthn_assertion(tenant_id, assertion_bytes) do
    # Use the WebAuthn adapter to verify the assertion. For now,
    # we pass the assertion as a payload map that the adapter expects.
    challenge = WebAuthn.new_authentication_challenge([])

    WebAuthn.verify_authentication(
      %{
        credential_id: assertion_bytes,
        authenticator_data: assertion_bytes,
        signature: assertion_bytes,
        client_data_json: assertion_bytes
      },
      challenge,
      tenant_id: tenant_id
    )
  end

  @doc """
  POST /api/v1/tenants/:id/bootstrap-audit-key

  Generates the initial ed25519 audit keypair for a legacy tenant that
  predates the Chain of Custody v2 signup ceremony. Caller must own
  the target tenant. Refuses if a key already exists.
  """
  def bootstrap(conn, %{"id" => tenant_id}) do
    caller_tenant_id =
      case conn.assigns do
        %{current_api_key: %{tenant_id: tid}} -> tid
        _ -> nil
      end

    if caller_tenant_id != tenant_id do
      conn
      |> put_status(:forbidden)
      |> json(%{error: %{message: "Forbidden", status: 403}})
    else
      do_bootstrap(conn, tenant_id)
    end
  end

  defp do_bootstrap(conn, tenant_id) do
    case Tenants.bootstrap_audit_key(tenant_id) do
      {:ok, tenant} ->
        json(conn, %{
          data: %{
            tenant_id: tenant.id,
            audit_signing_public_key: Base.encode64(tenant.audit_signing_public_key),
            message: "Audit keypair generated. Trust layers L1, L2, L5, L6 are now active."
          }
        })

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: %{message: "Not found", status: 404}})

      {:error, :key_already_exists} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: %{
            message: "Tenant already has an audit key. Use rotate-audit-key instead.",
            status: 409
          }
        })

      {:error, {:audit_key_storage_failed, _reason}} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: %{message: "Failed to store the audit key. Please retry.", status: 500}})

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: %{message: "Key bootstrap failed", status: 500}})
    end
  end

  # Encode ed25519 public key as SubjectPublicKeyInfo DER wrapped in PEM.
  # OID for Ed25519: 1.3.101.112 → {0x06, 0x03, 0x2B, 0x65, 0x70}
  # SubjectPublicKeyInfo ::= SEQUENCE { algorithm AlgorithmIdentifier, subjectPublicKey BIT STRING }
  defp encode_pem(public_key_bytes) when is_binary(public_key_bytes) do
    # AlgorithmIdentifier for Ed25519: SEQUENCE { OID 1.3.101.112 }
    alg_id = <<0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70>>
    # BIT STRING wrapping: 0x03, length+1, 0x00 (no unused bits), then the key
    bit_string = <<0x03, byte_size(public_key_bytes) + 1, 0x00>> <> public_key_bytes
    # SEQUENCE wrapping
    inner = alg_id <> bit_string
    der = <<0x30, byte_size(inner)>> <> inner

    b64 =
      der
      |> Base.encode64()
      |> String.graphemes()
      |> Enum.chunk_every(64)
      |> Enum.map_join("\n", &Enum.join/1)

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
