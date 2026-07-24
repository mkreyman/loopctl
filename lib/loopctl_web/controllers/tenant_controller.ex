defmodule LoopctlWeb.TenantController do
  @moduledoc """
  Controller for tenant profile management.

  - `GET /api/v1/tenants/me` — authenticated, returns current tenant profile
  - `PATCH /api/v1/tenants/me` — authenticated, updates current tenant

  Prior to Chain of Custody v2 (US-26.0.1) this controller also hosted
  `POST /api/v1/tenants/register`. That endpoint is removed —
  `/signup` (the WebAuthn-gated LiveView) is now the only path to
  create a tenant.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Dispatches
  alias Loopctl.Tenants
  alias Loopctl.Tenants.TierCapabilities

  action_fallback LoopctlWeb.FallbackController

  # Agents and orchestrators can view tenant profile but only users+ can modify settings
  plug LoopctlWeb.Plugs.RequireRole, [role: :user] when action in [:update, :register_owner_key]

  # LCP-1 §9.2: registering the custody OWNER key is a root-of-trust action — it
  # must come from a human-anchored tenant (the owner establishing the key the
  # whole attestation chain hangs from), never a self-minted agent-rooted key.
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:register_owner_key]

  tags(["Tenants"])

  operation(:show,
    summary: "Get current tenant profile",
    description: "Returns the tenant profile for the authenticated API key.",
    responses: %{
      200 => {"Tenant profile", "application/json", Schemas.TenantResponse},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:update,
    summary: "Update current tenant profile",
    description:
      "Updates the tenant profile. Requires user+ role. " <>
        "`slug` is immutable post-creation (it keys the audit-key secret) and is " <>
        "not part of the request body — see rls-02.",
    request_body: {"Update params", "application/json", Schemas.TenantUpdateRequest},
    responses: %{
      200 => {"Updated tenant", "application/json", Schemas.TenantResponse},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:register_owner_key,
    summary: "Register the LCP-1 custody owner key",
    description:
      "Registers or rotates the tenant's LCP-1 §9.2 owner key — the root of the " <>
        "custody-attestation chain. The private half stays with the owner. Requires " <>
        "user+ role and a human-anchored tenant.",
    request_body:
      {"Owner key", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:owner_pubkey],
         properties: %{
           owner_pubkey: %OpenApiSpex.Schema{
             type: :string,
             description: "Hex-encoded 32-byte Ed25519 public key"
           },
           alg: %OpenApiSpex.Schema{type: :string, enum: ["ed25519"], example: "ed25519"},
           rotation_proof: %OpenApiSpex.Schema{
             type: :string,
             nullable: true,
             description:
               "Required only when ROTATING an existing owner key: hex Ed25519 signature " <>
                 "by the OUTGOING owner key over owner_rotation_preimage(tenant_id, " <>
                 "new_pubkey, new_alg). Omit on first registration."
           }
         }
       }},
    responses: %{
      200 => {"Owner key registered", "application/json", Schemas.TenantResponse},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      403 => {"Custody tier required", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc """
  GET /api/v1/tenants/me

  Returns the current tenant profile based on the authenticated API key.
  """
  def show(conn, _params) do
    with {:ok, tenant} <- require_tenant(conn) do
      conn
      |> put_status(:ok)
      |> json(%{tenant: tenant_json(tenant)})
    end
  end

  @doc """
  PATCH /api/v1/tenants/me

  Updates the current tenant profile.
  """
  def update(conn, params) do
    with {:ok, tenant} <- require_tenant(conn) do
      case Tenants.update_tenant(tenant, params) do
        {:ok, updated} ->
          conn
          |> put_status(:ok)
          |> json(%{tenant: tenant_json(updated)})

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  POST /api/v1/tenants/me/custody-owner-key

  Registers or rotates the LCP-1 §9.2 owner key (root of the custody-attestation
  chain). Body: `%{"owner_pubkey" => <hex>, "alg" => "ed25519"}`. The private half
  stays with the owner. Human-anchored + `:user` role.
  """
  def register_owner_key(conn, params) do
    with {:ok, tenant} <- require_tenant(conn),
         {:ok, pubkey} <- decode_owner_pubkey(params["owner_pubkey"]),
         {:ok, rotation_proof} <- decode_rotation_proof(params["rotation_proof"]) do
      alg = params["alg"] || "ed25519"

      # LCP-1 §9.2: attribute the root-key registration/rotation to the ACTING key's
      # dispatch lineage in the tamper-evident chain — re-rooting trust must not be
      # recorded with an empty actor. `rotation_proof` (proof of possession of the
      # OUTGOING owner key) is required by the context only when a key already
      # exists; first registration ignores it.
      opts =
        [
          actor_lineage:
            Dispatches.lineage_for_api_key(tenant.id, conn.assigns.current_api_key.id)
        ]
        |> maybe_put_rotation_proof(rotation_proof)

      case Tenants.register_custody_owner_key(tenant.id, pubkey, alg, opts) do
        {:ok, updated} ->
          conn |> put_status(:ok) |> json(%{tenant: tenant_json(updated)})

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}

        {:error, reason}
        when reason in [:owner_rotation_proof_required, :owner_rotation_proof_invalid] ->
          {:error, :unprocessable_entity, rotation_proof_error_message(reason)}
      end
    end
  end

  defp maybe_put_rotation_proof(opts, nil), do: opts
  defp maybe_put_rotation_proof(opts, proof), do: Keyword.put(opts, :rotation_proof, proof)

  defp rotation_proof_error_message(:owner_rotation_proof_required),
    do:
      "This tenant already has a custody owner key, so rotating it requires proof of " <>
        "possession of the OUTGOING owner private key. Sign owner_rotation_preimage" <>
        "(tenant_id, new_pubkey, new_alg) with the current owner key and send it as " <>
        "`rotation_proof` (hex)."

  defp rotation_proof_error_message(:owner_rotation_proof_invalid),
    do:
      "The `rotation_proof` did not verify against the current owner key. Re-sign the " <>
        "exact owner_rotation_preimage(tenant_id, new_pubkey, new_alg) with the OUTGOING owner key."

  defp decode_owner_pubkey(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, :unprocessable_entity, "owner_pubkey must be hex-encoded"}
    end
  end

  defp decode_owner_pubkey(_), do: {:error, :unprocessable_entity, "owner_pubkey is required"}

  # `rotation_proof` is optional (absent on first registration). When present it must
  # decode as hex; the signature is verified server-side by the Tenants context.
  defp decode_rotation_proof(nil), do: {:ok, nil}
  defp decode_rotation_proof(""), do: {:ok, nil}

  defp decode_rotation_proof(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, :unprocessable_entity, "rotation_proof must be hex-encoded"}
    end
  end

  defp decode_rotation_proof(_),
    do: {:error, :unprocessable_entity, "rotation_proof must be a hex string"}

  defp tenant_json(tenant) do
    %{
      id: tenant.id,
      name: tenant.name,
      slug: tenant.slug,
      email: tenant.email,
      settings: tenant.settings,
      status: tenant.status,
      trust_tier: tenant.trust_tier,
      # LCP-1 §9.2: the owner key (hex) so a third party can verify root
      # enrollment attestations. Public by design; the private half is owner-held.
      custody_owner_pubkey:
        tenant.custody_owner_pubkey && Base.encode16(tenant.custody_owner_pubkey, case: :lower),
      custody_owner_alg: tenant.custody_owner_alg,
      # #505 — advertise the tier's surfaces UP FRONT so a caller can tell which
      # operations its tenant includes without probing for a 403 on each write.
      # Same map the `custody_tier_required` 403 embeds; one derivation, so the
      # advertised set and the enforced gate cannot drift.
      capabilities: TierCapabilities.for_tenant(tenant),
      token_data_retention_days: tenant.token_data_retention_days,
      inserted_at: tenant.inserted_at,
      updated_at: tenant.updated_at
    }
  end

  defp require_tenant(conn) do
    case conn.assigns[:current_tenant] do
      %{id: _} = tenant -> {:ok, tenant}
      _ -> {:error, :bad_request, "Superadmin must use X-Impersonate-Tenant header"}
    end
  end
end
