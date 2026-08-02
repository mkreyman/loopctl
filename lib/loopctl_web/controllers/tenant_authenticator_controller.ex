defmodule LoopctlWeb.TenantAuthenticatorController do
  @moduledoc """
  US-26.7.2 — opt-in WebAuthn trust-tier upgrade ceremony
  (agent_rooted -> human_anchored) and authenticator revocation.

  Endpoints, mirroring `LoopctlWeb.TenantAuditKeyController`'s
  challenge/act shape:

    0. `GET /tenants/:id/authenticators` — lists the tenant's enrolled
       authenticators (id, label, format, timestamps — never credential
       material). The row id is the handle the rename and revoke endpoints key
       on, and a browser ceremony discards the 201 body, so without this index
       an operator has no way to discover it.
    1. `POST /tenants/:id/authenticators/challenge` — issues a registration
       challenge (AC-26.7.2.1/.2). If the tenant is already `human_anchored`,
       ALSO issues a fresh-assertion (reauth) challenge for an existing
       authenticator (`reauth_required: true`) — a subsequent enrollment
       must prove possession of an already-enrolled device.
    2. `POST /tenants/:id/authenticators` — completes enrollment in a
       TWO-PHASE shape (AC-26.7.2.3), mirroring `Reauth.verify_and_consume/3`:
       PHASE 1 atomically consumes the registration challenge in its own
       committed transaction (and, when human_anchored, ALSO verifies +
       consumes the required `add_authenticator` assertion — the CRITICAL
       anti-soft-recovery-backdoor gate); PHASE 2 size-caps and verifies the
       attestation OUTSIDE any transaction; PHASE 3 is the DB-only
       `Loopctl.Tenants.Enrollment.enroll/2` Multi (insert + guarded tier
       flip + audit).
    3. `POST /tenants/:id/authenticators/revoke-challenge` — issues a
       `revoke_authenticator` reauth challenge.
    4. `DELETE /tenants/:id/authenticators/:auth_id` — verifies the
       assertion against that challenge, then race-safe revokes
       (`Loopctl.Tenants.Enrollment.revoke/2`) — refuses to strip the last
       authenticator off a human_anchored tenant.

  ## Not tier-gated (US-26.7.1 pattern)

  None of these actions carry `RequireHumanAnchor`, deliberately: `challenge`
  and `create` ARE the upgrade path — an agent-rooted caller is the intended
  audience for the FIRST enrollment. `revoke-challenge`/`delete` and any
  SUBSEQUENT enrollment are protected by fresh, per-operation WebAuthn
  assertions (`Loopctl.WebAuthn.Reauth`), a STRONGER control than the tier
  gate. All of them require `role: :user` + tenant ownership
  (`owns_tenant?/2`, mirroring `TenantAuditKeyController`).
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Tenants
  alias Loopctl.Tenants.Enrollment
  alias Loopctl.Tenants.RootAuthenticators
  alias Loopctl.Tenants.TierCapabilities
  alias Loopctl.WebAuthn
  alias Loopctl.WebAuthn.Enrollment, as: RegistrationChallenges
  alias Loopctl.WebAuthn.Reauth

  @add_authenticator_purpose "add_authenticator"
  @revoke_purpose "revoke_authenticator"

  # Reject attestation fields larger than this BEFORE base64-decoding them,
  # bounding per-call CBOR-decode cost. Mirrors signup_live.ex's
  # @max_attestation_field_bytes — a real FIDO2 attestation object is well
  # under 8 KB.
  @max_attestation_field_bytes 8 * 1024

  # Matches RootAuthenticator's `validate_length(:friendly_name, max: 120)`.
  @max_friendly_name_bytes 120

  # WebAuthn verification (and, for revoke, the assertion verify) is
  # CPU-bound and abusable. A tighter, per-tenant budget on top of the
  # blanket RateLimiter plug, mirroring signup_live.ex's ensure_action_budget/1.
  @enroll_rate_window_ms 60_000 * 60
  @max_enroll_actions_per_window 30

  # Rename does no crypto, so it gets its own far looser bucket rather than
  # spending the ceremony budget. It still needs a per-tenant ceiling: each
  # rename appends to the hash-chained audit log, and that append serializes
  # per tenant against genuine custody writes.
  @max_rename_actions_per_window 300

  @pub_key_cred_params [
    %{type: "public-key", alg: -7},
    %{type: "public-key", alg: -257}
  ]

  # Authenticator enrollment/revocation requires user role — agents must not
  # perform trust-tier operations.
  plug LoopctlWeb.Plugs.RequireRole,
       [role: :user]
       when action in [:index, :challenge, :create, :revoke_challenge, :delete, :rename]

  tags(["Tenants"])

  operation(:index,
    summary: "List a tenant's enrolled authenticators",
    description:
      "Returns the enrolled authenticators' ids and display labels — the handle " <>
        "the rename (PATCH) and revoke (DELETE) endpoints key on. NO credential " <>
        "material (credential_id, public_key) is ever returned. Requires user role " <>
        "and tenant ownership.",
    parameters: [id: [in: :path, type: :string, description: "Tenant UUID"]],
    responses: %{
      200 => {"Enrolled authenticators", "application/json", Schemas.AuthenticatorListResponse},
      403 => {"Forbidden", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc """
  GET /api/v1/tenants/:id/authenticators
  """
  def index(conn, %{"id" => tenant_id}) do
    if owns_tenant?(conn, tenant_id) do
      data =
        tenant_id
        |> RootAuthenticators.list_by_tenant()
        |> Enum.map(
          &%{
            id: &1.id,
            friendly_name: &1.friendly_name,
            attestation_format: &1.attestation_format,
            inserted_at: &1.inserted_at,
            last_used_at: &1.last_used_at
          }
        )

      conn |> put_status(:ok) |> json(%{data: data})
    else
      forbidden(conn)
    end
  end

  operation(:challenge,
    summary: "Issue a WebAuthn enrollment registration challenge",
    description:
      "Step 1 of the opt-in trust-tier upgrade ceremony (US-26.7.2). Requires user " <>
        "role and tenant ownership. Not tier-gated.",
    parameters: [id: [in: :path, type: :string, description: "Tenant UUID"]],
    responses: %{
      200 => {"Enrollment challenge", "application/json", Schemas.AuthenticatorChallengeResponse},
      403 => {"Forbidden", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limited", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc """
  POST /api/v1/tenants/:id/authenticators/challenge

  Step 1 of the enrollment ceremony. Mints a server-side, single-use,
  TTL-bounded registration challenge. When the tenant is already
  `human_anchored`, also mints a fresh `add_authenticator` reauth challenge
  for an existing authenticator.
  """
  def challenge(conn, %{"id" => tenant_id}) do
    if owns_tenant?(conn, tenant_id) do
      do_challenge(conn, tenant_id)
    else
      forbidden(conn)
    end
  end

  defp do_challenge(conn, tenant_id) do
    with :ok <- check_rate_limit(tenant_id),
         {:ok, tenant} <- Tenants.get_tenant(tenant_id),
         {:ok, issued} <- RegistrationChallenges.issue(tenant_id) do
      render_challenge(conn, tenant, issued)
    else
      {:error, :rate_limited} -> rate_limited(conn)
      {:error, :not_found} -> not_found(conn)
      {:error, _reason} -> internal_error(conn, "Failed to issue enrollment challenge")
    end
  end

  defp render_challenge(conn, tenant, issued) do
    rp_opts = WebAuthn.rp_opts()

    base = %{
      challenge_id: issued.challenge_id,
      challenge: issued.challenge_bytes,
      expires_at: issued.expires_at,
      rp: %{id: Keyword.get(rp_opts, :rp_id), name: Keyword.get(rp_opts, :rp_name)},
      user: webauthn_user(tenant),
      pub_key_cred_params: @pub_key_cred_params
    }

    case tenant.trust_tier do
      :human_anchored ->
        render_subsequent_challenge(conn, tenant, base)

      :agent_rooted ->
        conn |> put_status(:ok) |> json(%{data: Map.put(base, :reauth_required, false)})
    end
  end

  defp render_subsequent_challenge(conn, tenant, base) do
    case Reauth.issue_challenge(tenant.id, @add_authenticator_purpose) do
      {:ok, reauth} ->
        data =
          Map.merge(base, %{
            reauth_required: true,
            reauth_challenge: %{
              challenge_id: reauth.challenge_id,
              challenge: reauth.challenge,
              allowed_credentials: reauth.allowed_credentials,
              rp_id: reauth.rp_id,
              expires_at: reauth.expires_at
            }
          })

        conn |> put_status(:ok) |> json(%{data: data})

      {:error, _reason} ->
        internal_error(conn, "Failed to issue reauth challenge")
    end
  end

  # Opaque, per-tenant, non-PII WebAuthn user handle. Not a login identity —
  # only used to populate navigator.credentials.create()'s required
  # `user.id`. Documented per AC-26.7.2.2: derived server-side from the
  # tenant, never client-supplied.
  defp webauthn_user(tenant) do
    %{
      id: Base.url_encode64(Ecto.UUID.dump!(tenant.id), padding: false),
      name: tenant.slug,
      display_name: tenant.name
    }
  end

  operation(:create,
    summary: "Complete WebAuthn authenticator enrollment",
    description:
      "Step 2 of the opt-in trust-tier upgrade ceremony. Two-phase: consumes the " <>
        "registration challenge (and, if already human_anchored, verifies a fresh " <>
        "add_authenticator assertion) FIRST, then verifies the attestation, then " <>
        "atomically inserts the authenticator and guard-flips trust_tier. Requires " <>
        "user role and tenant ownership. Not tier-gated.",
    parameters: [id: [in: :path, type: :string, description: "Tenant UUID"]],
    request_body:
      {"Enrollment attestation", "application/json", Schemas.EnrollAuthenticatorRequest},
    responses: %{
      201 => {"Authenticator enrolled", "application/json", Schemas.AuthenticatorEnrollResponse},
      401 =>
        {"Challenge/assertion/attestation invalid", "application/json", Schemas.ErrorResponse},
      403 => {"Forbidden", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 => {"Too many authenticators", "application/json", Schemas.ErrorResponse},
      422 => {"Validation failed", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limited", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc """
  POST /api/v1/tenants/:id/authenticators

  Step 2 of the enrollment ceremony.
  """
  def create(conn, %{"id" => tenant_id} = params) do
    if owns_tenant?(conn, tenant_id) do
      do_create(conn, tenant_id, params)
    else
      forbidden(conn)
    end
  end

  defp do_create(conn, tenant_id, params) do
    with :ok <- check_rate_limit(tenant_id),
         {:ok, friendly_name} <- friendly_name(params),
         {:ok, tenant} <- Tenants.get_tenant(tenant_id),
         {:ok, challenge} <- consume_registration_challenge(tenant_id, params),
         {:ok, assertion_verified?} <-
           maybe_require_add_authenticator_assertion(tenant, params),
         :ok <- ensure_attestation_size(params),
         {:ok, decoded} <- decode_attestation(params),
         {:ok, verified} <- WebAuthn.verify_registration(decoded, challenge, WebAuthn.rp_opts()) do
      complete_enroll(conn, tenant_id, verified, friendly_name, assertion_verified?)
    else
      {:error, :rate_limited} ->
        rate_limited(conn)

      {:error, :friendly_name_too_long} ->
        friendly_name_too_long(conn)

      {:error, :not_found} ->
        not_found(conn)

      {:error, :challenge_invalid} ->
        challenge_invalid(conn)

      {:error, :reauth_required} ->
        reauth_required(conn)

      {:error, :reauth_failed} ->
        reauth_failed(conn)

      {:error, :attestation_too_large} ->
        attestation_too_large(conn)

      {:error, :invalid_encoding} ->
        bad_request(conn, "Attestation fields must be base64url-encoded")

      {:error, _reason} ->
        webauthn_failed(conn)
    end
  end

  # PHASE 1 (part 1): consume the registration challenge in its OWN
  # committed transaction FIRST (AC-26.7.2.3), so a later attestation
  # failure never un-burns it.
  defp consume_registration_challenge(tenant_id, params) do
    challenge_id = Map.get(params, "challenge_id")

    case RegistrationChallenges.consume(tenant_id, challenge_id) do
      {:ok, challenge} -> {:ok, challenge}
      {:error, _reason} -> {:error, :challenge_invalid}
    end
  end

  # PHASE 1 (part 2): the CRITICAL backup-enrollment gate. An agent_rooted
  # tenant (zero authenticators — legitimate bootstrap) needs nothing more
  # than ownership + a fresh registration attestation, so no assertion is
  # verified here (`{:ok, false}`). An already human_anchored tenant
  # additionally requires a fresh assertion from an ALREADY-enrolled
  # authenticator, verified + consumed here (`{:ok, true}`) — this is what
  # closes the "stolen role:user key grafts an attacker's own hardware onto
  # the tenant's root of trust" backdoor (docs/chain-of-custody-v2.md §9.3).
  #
  # The returned boolean is threaded into `Enrollment.enroll/3`, which
  # RE-ENFORCES this gate under the tenant-row lock against the authoritative
  # (post-lock) tier — so a tenant that races from agent_rooted to
  # human_anchored between this pre-lock read and Phase 3 still cannot enroll
  # a backup without an assertion.
  defp maybe_require_add_authenticator_assertion(%{trust_tier: :agent_rooted}, _params),
    do: {:ok, false}

  defp maybe_require_add_authenticator_assertion(
         %{trust_tier: :human_anchored, id: tenant_id},
         params
       ) do
    case Map.get(params, "reauth_assertion") do
      assertion when is_map(assertion) ->
        case Reauth.verify_and_consume(tenant_id, @add_authenticator_purpose, assertion) do
          {:ok, _verified} -> {:ok, true}
          {:error, _reason} -> {:error, :reauth_failed}
        end

      _ ->
        {:error, :reauth_required}
    end
  end

  defp ensure_attestation_size(params) do
    within? =
      ["attestation_object", "client_data_json", "credential_id"]
      |> Enum.all?(fn key -> field_within_size?(Map.get(params, key, "")) end)

    if within?, do: :ok, else: {:error, :attestation_too_large}
  end

  defp field_within_size?(value) when is_binary(value),
    do: byte_size(value) <= @max_attestation_field_bytes

  defp field_within_size?(_value), do: true

  # PHASE 2: decode + verify OUTSIDE any open transaction — CPU-bound
  # CBOR/COSE work never holds a DB connection (AC-26.7.2.3).
  defp decode_attestation(params) do
    with {:ok, attestation_object} <- decode_b64url(Map.get(params, "attestation_object", "")),
         {:ok, client_data_json} <- decode_b64url(Map.get(params, "client_data_json", "")),
         {:ok, credential_id} <- decode_b64url(Map.get(params, "credential_id", "")) do
      {:ok,
       %{
         attestation_object: attestation_object,
         client_data_json: client_data_json,
         credential_id: credential_id
       }}
    end
  end

  defp decode_b64url(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_encoding}
    end
  end

  defp decode_b64url(_value), do: {:error, :invalid_encoding}

  # AC-26.7.2.3: friendly_name is "validated 1..120" — an over-120-byte name
  # is REJECTED (422), never silently truncated and persisted. An absent /
  # blank name defaults to "Authenticator". The byte cap mirrors signup's
  # @max_friendly_name_bytes; RootAuthenticator.create_changeset/2 re-validates
  # length 1..120 as defense in depth.
  defp friendly_name(params) do
    case Map.get(params, "friendly_name") do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        cond do
          trimmed == "" -> {:ok, "Authenticator"}
          byte_size(trimmed) > @max_friendly_name_bytes -> {:error, :friendly_name_too_long}
          true -> {:ok, trimmed}
        end

      _ ->
        {:ok, "Authenticator"}
    end
  end

  # PHASE 3: the DB-only Multi (insert + guarded tier flip + audit).
  defp complete_enroll(conn, tenant_id, verified, friendly_name, assertion_verified?) do
    attrs =
      verified
      |> Map.take([:credential_id, :public_key, :attestation_format, :sign_count])
      |> Map.put(:friendly_name, friendly_name)
      |> Map.put_new(:sign_count, 0)

    case Enrollment.enroll(tenant_id, attrs, assertion_verified?) do
      {:ok, %{tenant: tenant, authenticator: auth, upgraded: upgraded}} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            tenant_id: tenant.id,
            trust_tier: Atom.to_string(tenant.trust_tier),
            upgraded: upgraded,
            # #505 — the enrollment upgrade is the moment the tier CHANGES, so
            # ship the newly-unlocked surface map with it rather than making the
            # caller re-fetch GET /tenants/me to learn what it just gained.
            capabilities: TierCapabilities.for_tenant(tenant),
            authenticator: %{
              id: auth.id,
              friendly_name: auth.friendly_name,
              attestation_format: auth.attestation_format,
              inserted_at: auth.inserted_at
            }
          }
        })

      {:error, :not_found} ->
        not_found(conn)

      # The under-lock backup-enrollment gate rejected this: a concurrent
      # first-enroll flipped the tenant to human_anchored between the
      # controller's pre-lock read and Phase 3, so this request now needs an
      # add_authenticator assertion it didn't supply. Same 401 as the pre-lock
      # gate — the caller must retry WITH a fresh existing-authenticator
      # assertion.
      {:error, :reauth_required} ->
        reauth_required(conn)

      {:error, :too_many_authenticators} ->
        too_many_authenticators(conn)

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset_error(conn, changeset)
    end
  end

  operation(:revoke_challenge,
    summary: "Issue an authenticator-revocation reauth challenge",
    description:
      "Issues a fresh-assertion challenge (purpose revoke_authenticator) for an " <>
        "existing authenticator. Requires user role and tenant ownership.",
    parameters: [id: [in: :path, type: :string, description: "Tenant UUID"]],
    responses: %{
      200 => {"Reauth challenge", "application/json", Schemas.ReauthChallengeResponse},
      403 => {"Forbidden", "application/json", Schemas.ErrorResponse},
      422 => {"No enrolled authenticators", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limited", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc """
  POST /api/v1/tenants/:id/authenticators/revoke-challenge
  """
  def revoke_challenge(conn, %{"id" => tenant_id}) do
    if owns_tenant?(conn, tenant_id) do
      do_revoke_challenge(conn, tenant_id)
    else
      forbidden(conn)
    end
  end

  defp do_revoke_challenge(conn, tenant_id) do
    with :ok <- check_rate_limit(tenant_id),
         {:ok, issued} <- Reauth.issue_challenge(tenant_id, @revoke_purpose) do
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
    else
      {:error, :rate_limited} ->
        rate_limited(conn)

      {:error, :no_authenticators} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{
            status: 422,
            code: "no_authenticators",
            message: "Tenant has no enrolled root authenticator to authorize revocation"
          }
        })

      {:error, _reason} ->
        internal_error(conn, "Failed to issue reauth challenge")
    end
  end

  operation(:delete,
    summary: "Revoke an enrolled authenticator",
    description:
      "Verifies the WebAuthn assertion against the STORED revoke_authenticator " <>
        "challenge, then race-safe deletes the target authenticator. Refuses (409) " <>
        "to remove the LAST authenticator on a human_anchored tenant — no " <>
        "auto-downgrade. Requires user role and tenant ownership.",
    parameters: [
      id: [in: :path, type: :string, description: "Tenant UUID"],
      auth_id: [in: :path, type: :string, description: "Authenticator UUID"]
    ],
    request_body: {"WebAuthn assertion", "application/json", Schemas.RevokeAuthenticatorRequest},
    responses: %{
      200 => {"Authenticator revoked", "application/json", Schemas.RevokeAuthenticatorResponse},
      401 => {"WebAuthn required or failed", "application/json", Schemas.ErrorResponse},
      403 => {"Forbidden", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 => {"Last authenticator", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc """
  DELETE /api/v1/tenants/:id/authenticators/:auth_id
  """
  def delete(conn, %{"id" => tenant_id, "auth_id" => auth_id} = params) do
    assertion = Map.get(params, "webauthn_assertion")

    cond do
      not owns_tenant?(conn, tenant_id) ->
        forbidden(conn)

      not is_map(assertion) ->
        unauthorized(
          conn,
          "webauthn_required",
          "WebAuthn assertion required to revoke an authenticator"
        )

      true ->
        do_revoke(conn, tenant_id, auth_id, assertion)
    end
  end

  defp do_revoke(conn, tenant_id, auth_id, assertion) do
    case Reauth.verify_and_consume(tenant_id, @revoke_purpose, assertion) do
      {:ok, _verified} ->
        case Enrollment.revoke(tenant_id, auth_id) do
          {:ok, auth} ->
            conn
            |> put_status(:ok)
            |> json(%{data: %{tenant_id: tenant_id, authenticator_id: auth.id, revoked: true}})

          {:error, :not_found} ->
            not_found(conn)

          {:error, :last_authenticator} ->
            last_authenticator(conn)
        end

      {:error, _reason} ->
        unauthorized(conn, "webauthn_failed", "WebAuthn assertion verification failed")
    end
  end

  operation(:rename,
    summary: "Rename an enrolled authenticator",
    description:
      "Updates the operator-facing display label of an enrolled authenticator. " <>
        "Requires user role and tenant ownership. Unlike revocation this needs NO " <>
        "WebAuthn assertion: a rename is reversible, destroys nothing, and changes " <>
        "no credential material — only `friendly_name` is writable. The change is " <>
        "recorded in the append-only audit chain, stamped with the CALLING KEY " <>
        "(actor_type api_key) and the old and new label. `friendly_name` is " <>
        "trimmed, must be non-blank (422 friendly_name_blank) and is capped at " <>
        "#{@max_friendly_name_bytes} bytes (422 friendly_name_too_long).",
    parameters: [
      id: [in: :path, type: :string, description: "Tenant UUID"],
      auth_id: [in: :path, type: :string, description: "Authenticator UUID"]
    ],
    request_body:
      {"Rename request", "application/json", Schemas.RenameAuthenticatorRequest, required: true},
    responses: %{
      200 => {"Authenticator renamed", "application/json", Schemas.RenameAuthenticatorResponse},
      400 => {"Bad request", "application/json", Schemas.ErrorResponse},
      403 => {"Forbidden", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 => {"Validation failed", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limited", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc """
  PATCH /api/v1/tenants/:id/authenticators/:auth_id

  Relabels an enrolled authenticator. Deliberately NOT behind the
  `@max_enroll_actions_per_window` budget that the ceremony endpoints share:
  that budget bounds CPU-bound WebAuthn verification, and spending one of a
  tenant's 30 hourly enroll actions on a label edit could 429 an operator out
  of their own enrollment ceremony. It gets its own, far looser per-tenant
  bucket instead — every rename appends to the hash-chained audit log, whose
  per-tenant append serializes against genuine custody writes, so "no
  tenant-scoped ceiling at all" is not an option either.

  `friendly_name` is TRIMMED before validation, mirroring the enroll path's
  `friendly_name/1`, so the two write paths agree on what a label is.
  """
  def rename(conn, %{"id" => tenant_id, "auth_id" => auth_id} = params) do
    raw = Map.get(params, "friendly_name")
    friendly_name = if is_binary(raw), do: String.trim(raw), else: raw

    cond do
      not owns_tenant?(conn, tenant_id) ->
        forbidden(conn)

      not is_binary(friendly_name) ->
        bad_request(conn, "friendly_name is required and must be a string")

      friendly_name == "" ->
        friendly_name_blank(conn)

      byte_size(friendly_name) > @max_friendly_name_bytes ->
        friendly_name_too_long(conn)

      true ->
        do_rename(conn, tenant_id, auth_id, friendly_name)
    end
  end

  defp do_rename(conn, tenant_id, auth_id, friendly_name) do
    case check_rename_rate_limit(tenant_id) do
      :ok -> complete_rename(conn, tenant_id, auth_id, friendly_name)
      {:error, :rate_limited} -> rate_limited(conn)
    end
  end

  defp complete_rename(conn, tenant_id, auth_id, friendly_name) do
    case Enrollment.rename(tenant_id, auth_id, friendly_name, audit_actor(conn)) do
      {:ok, auth} ->
        conn
        |> put_status(:ok)
        |> json(%{
          data: %{
            tenant_id: tenant_id,
            authenticator_id: auth.id,
            friendly_name: auth.friendly_name
          }
        })

      {:error, :not_found} ->
        not_found(conn)

      {:error, :audit_failed} ->
        internal_error(conn, "Failed to record the rename in the audit log")

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset_error(conn, changeset)
    end
  end

  # --- Shared helpers ---

  defp check_rate_limit(tenant_id) do
    gate("enroll:actions:#{tenant_id}", @max_enroll_actions_per_window)
  end

  defp check_rename_rate_limit(tenant_id) do
    gate("rename:actions:#{tenant_id}", @max_rename_actions_per_window)
  end

  defp gate(bucket, max) do
    # FAIL-CLOSED anti-abuse gate (WebAuthn enroll/revoke is CPU-bound): on a
    # limiter fault deny rather than unlock the throttle. `gate_ok?/3` also
    # absorbs the behaviour's `{:error, _}` shape so a soft-error can't raise.
    if Loopctl.RateLimiter.gate_ok?(bucket, @enroll_rate_window_ms, max) do
      :ok
    else
      {:error, :rate_limited}
    end
  end

  # Rename proves no device possession, so the acting key IS the evidence.
  # Mirrors egress_controller.ex:420's audit-actor shape.
  defp audit_actor(conn) do
    case conn.assigns do
      %{current_api_key: %{id: id, role: role, name: name}} ->
        [actor_id: id, actor_label: "#{role}:#{name}"]

      _ ->
        []
    end
  end

  # Ownership check: the caller's user-role key must belong to the target
  # tenant. Mirrors TenantAuditKeyController.owns_tenant?/2.
  defp owns_tenant?(conn, tenant_id) do
    case conn.assigns do
      %{current_api_key: %{tenant_id: tid}} -> tid == tenant_id
      _ -> false
    end
  end

  defp forbidden(conn) do
    conn |> put_status(:forbidden) |> json(%{error: %{status: 403, message: "Forbidden"}})
  end

  defp not_found(conn) do
    conn |> put_status(:not_found) |> json(%{error: %{status: 404, message: "Not found"}})
  end

  defp rate_limited(conn) do
    conn
    |> put_status(:too_many_requests)
    |> json(%{
      error: %{
        status: 429,
        code: "rate_limited",
        message: "Too many authenticator enrollment actions. Please try again later."
      }
    })
  end

  defp challenge_invalid(conn) do
    unauthorized(
      conn,
      "challenge_invalid",
      "Registration challenge missing, expired, already used, or does not belong to this tenant"
    )
  end

  defp reauth_required(conn) do
    unauthorized(
      conn,
      "reauth_required",
      "A fresh WebAuthn assertion from an existing authenticator is required to " <>
        "enroll an additional authenticator on a human-anchored tenant"
    )
  end

  defp reauth_failed(conn) do
    unauthorized(conn, "reauth_failed", "WebAuthn assertion verification failed")
  end

  defp webauthn_failed(conn) do
    unauthorized(conn, "webauthn_failed", "WebAuthn attestation verification failed")
  end

  defp attestation_too_large(conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{status: 400, message: "Attestation payload too large"}})
  end

  defp friendly_name_too_long(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        code: "friendly_name_too_long",
        message: "friendly_name must be at most #{@max_friendly_name_bytes} bytes"
      }
    })
  end

  defp friendly_name_blank(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        code: "friendly_name_blank",
        message: "friendly_name must not be blank"
      }
    })
  end

  defp bad_request(conn, message) do
    conn |> put_status(:bad_request) |> json(%{error: %{status: 400, message: message}})
  end

  defp too_many_authenticators(conn) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "too_many_authenticators",
        message:
          "Tenant already has the maximum number of enrolled authenticators " <>
            "(#{Enrollment.max_authenticators()})"
      }
    })
  end

  defp last_authenticator(conn) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "last_authenticator",
        message: "Cannot revoke the last enrolled authenticator on a human-anchored tenant"
      }
    })
  end

  defp unauthorized(conn, code, message) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: %{status: 401, code: code, message: message}})
  end

  defp internal_error(conn, message) do
    conn |> put_status(:internal_server_error) |> json(%{error: %{status: 500, message: message}})
  end

  defp changeset_error(conn, changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        message: "Validation failed",
        details: format_changeset_errors(changeset)
      }
    })
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
