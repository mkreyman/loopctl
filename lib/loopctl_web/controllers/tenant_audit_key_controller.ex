defmodule LoopctlWeb.TenantAuditKeyController do
  @moduledoc """
  US-26.0.2 / crypto-01 — Public key retrieval and key rotation for tenant
  audit signing keys.

  The public key endpoint is unauthenticated (intended for external
  verification). Rotation is gated by a real, two-step, challenge-bound
  WebAuthn reauthentication ceremony (GHSA-c3cw-5f7p-g76r):

    1. `POST /tenants/:id/rotate-audit-key/challenge` issues an
       authentication challenge bound to the tenant's enrolled root
       authenticators and stores it server-side (single-use, short TTL).
    2. `POST /tenants/:id/rotate-audit-key` verifies the client's assertion
       against that STORED challenge (origin, RP-ID, signature against the
       enrolled COSE key, sign-counter regression) before rotating.

  Both steps require `user` role (enforced by the router pipeline + the
  `RequireRole` plug) AND tenant ownership (checked here).
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Tenants
  alias Loopctl.WebAuthn.Reauth

  @rotate_purpose "rotate_audit_key"

  # Key management requires user role — agents must not rotate/bootstrap keys
  plug LoopctlWeb.Plugs.RequireRole,
       [role: :user] when action in [:rotate, :bootstrap, :challenge]

  tags(["Tenants"])

  operation(:show,
    summary: "Get tenant audit public key",
    description:
      "Returns the tenant's ed25519 audit signing public key as PEM (default) " <>
        "or JWK (Accept: application/jwk+json). Public — no authentication required.",
    parameters: [id: [in: :path, type: :string, description: "Tenant UUID"]],
    security: [],
    responses: %{
      200 =>
        {"Public key (PEM or JWK)", "application/x-pem-file", %OpenApiSpex.Schema{type: :string}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse}
    }
  )

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

  operation(:challenge,
    summary: "Issue an audit-key rotation reauth challenge",
    description:
      "Step 1 of the challenge-bound WebAuthn reauthentication ceremony. Issues " <>
        "an authentication challenge bound to the tenant's enrolled root " <>
        "authenticators, stores it server-side (single-use, short TTL) and returns " <>
        "the opaque `challenge_id`, the base64url challenge bytes, and the allowed " <>
        "credential ids. Requires user role and tenant ownership.",
    parameters: [id: [in: :path, type: :string, description: "Tenant UUID"]],
    responses: %{
      200 => {"Reauth challenge", "application/json", Schemas.ReauthChallengeResponse},
      403 => {"Forbidden", "application/json", Schemas.ErrorResponse},
      422 => {"No enrolled authenticators", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc """
  POST /api/v1/tenants/:id/rotate-audit-key/challenge

  Step 1 of the reauth ceremony. Mints a server-side, single-use,
  TTL-bounded authentication challenge bound to the caller's tenant and
  returns the opaque handle plus allowed credential ids.
  """
  def challenge(conn, %{"id" => tenant_id}) do
    if owns_tenant?(conn, tenant_id) do
      case Reauth.issue_challenge(tenant_id, @rotate_purpose) do
        {:ok, issued} ->
          conn
          |> put_status(:ok)
          |> json(%{
            data: %{
              challenge_id: issued.challenge_id,
              challenge: issued.challenge,
              allowed_credentials: issued.allowed_credentials,
              rp_id: issued.rp_id,
              expires_at: issued.expires_at
            }
          })

        {:error, :no_authenticators} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{
            error: %{
              message: "Tenant has no enrolled root authenticator to authorize rotation",
              code: "no_authenticators",
              status: 422
            }
          })

        {:error, _reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{error: %{message: "Failed to issue reauth challenge", status: 500}})
      end
    else
      forbidden(conn)
    end
  end

  operation(:rotate,
    summary: "Rotate the tenant audit signing key",
    description:
      "Step 2 of the challenge-bound WebAuthn reauthentication ceremony. Verifies " <>
        "the assertion against the STORED challenge from step 1 (challenge binding, " <>
        "origin, RP-ID, signature against the enrolled COSE key, sign-counter " <>
        "regression) and, on success, rotates the ed25519 audit keypair. Requires " <>
        "user role and tenant ownership.",
    parameters: [id: [in: :path, type: :string, description: "Tenant UUID"]],
    request_body: {"WebAuthn assertion", "application/json", Schemas.RotateAuditKeyRequest},
    responses: %{
      200 => {"Key rotated", "application/json", Schemas.AuditKeyResponse},
      401 => {"WebAuthn required or failed", "application/json", Schemas.ErrorResponse},
      403 => {"Forbidden", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 => {"No audit key to rotate", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc """
  POST /api/v1/tenants/:id/rotate-audit-key

  Step 2 of the reauth ceremony. Rotates the tenant's audit signing
  keypair. Requires:
  1. Authenticated with a user-role key (enforced by router pipeline)
  2. Caller owns the target tenant (checked here)
  3. A WebAuthn assertion verified against a STORED challenge from step 1
  """
  def rotate(conn, %{"id" => tenant_id} = params) do
    assertion = Map.get(params, "webauthn_assertion")

    cond do
      not owns_tenant?(conn, tenant_id) ->
        forbidden(conn)

      not is_map(assertion) ->
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
        do_rotate(conn, tenant_id, assertion)
    end
  end

  defp do_rotate(conn, tenant_id, assertion) do
    # Verify the assertion against the STORED challenge and the tenant's
    # enrolled authenticator (challenge binding, signature, counter). The
    # ceremony is single-use: the challenge is consumed here regardless of
    # outcome. On success `verified.signature` is the genuinely verified
    # assertion signature, persisted as the rotation proof.
    case Reauth.verify_and_consume(tenant_id, @rotate_purpose, assertion) do
      {:ok, verified} ->
        rotate_after_reauth(conn, tenant_id, verified.signature)

      {:error, _reason} ->
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

  defp rotate_after_reauth(conn, tenant_id, rotation_signature) do
    case Tenants.rotate_audit_key(tenant_id, rotation_signature) do
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
  end

  operation(:bootstrap,
    summary: "Bootstrap an audit signing keypair for a legacy tenant",
    description:
      "Generates the initial ed25519 audit keypair for a tenant that predates the " <>
        "Chain of Custody v2 signup ceremony. Requires user role and tenant " <>
        "ownership. Refuses (409) if a key already exists — use rotate-audit-key.",
    parameters: [id: [in: :path, type: :string, description: "Tenant UUID"]],
    responses: %{
      200 => {"Audit keypair bootstrapped", "application/json", Schemas.AuditKeyResponse},
      403 => {"Forbidden", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 => {"Key already exists", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc """
  POST /api/v1/tenants/:id/bootstrap-audit-key

  Generates the initial ed25519 audit keypair for a legacy tenant that
  predates the Chain of Custody v2 signup ceremony. Caller must own
  the target tenant. Refuses if a key already exists.
  """
  def bootstrap(conn, %{"id" => tenant_id}) do
    if owns_tenant?(conn, tenant_id) do
      do_bootstrap(conn, tenant_id)
    else
      forbidden(conn)
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

  # Ownership check: the caller's user-role key must belong to the target
  # tenant. This is the authorization gate that sits alongside (never
  # replaces) the WebAuthn crypto layer.
  defp owns_tenant?(conn, tenant_id) do
    case conn.assigns do
      %{current_api_key: %{tenant_id: tid}} -> tid == tenant_id
      _ -> false
    end
  end

  defp forbidden(conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: %{message: "Forbidden", status: 403}})
  end
end
