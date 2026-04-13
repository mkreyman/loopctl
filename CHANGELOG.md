# Changelog

All notable changes to loopctl are documented here.

## [1.0.0] — 2026-04-12 — Chain of Custody v2

27 stories across 7 phases implementing a six-layer trust model for
AI agent development loops. Full spec: `docs/chain-of-custody-v2.md`.

### Added — Chain of Custody v2 / US-26.0.1

- **Tenant signup ceremony with WebAuthn enrollment**.
  - New public LiveView at `/signup` that collects tenant metadata and
    initiates a FIDO2 registration ceremony via `navigator.credentials.create()`.
    Supports both cross-platform authenticators (YubiKey, etc.) and platform
    authenticators (Touch ID, Windows Hello).
  - `tenant_root_authenticators` table storing `credential_id`, COSE public
    key, attestation format, sign counter, and friendly label per enrolled
    key. One-to-many from tenant to authenticator, unique on
    `(tenant_id, credential_id)`, RLS-enabled.
  - `tenants.status` gains a `:pending_enrollment` value; an Oban cron
    worker (`PendingEnrollmentCleanupWorker`, every 5 minutes) deletes
    tenants stuck in that state past the 15-minute TTL.
  - `Loopctl.WebAuthn.Behaviour` + `Loopctl.WebAuthn.Wax` adapter, wired
    via config-based DI so tests can swap in `Loopctl.MockWebAuthn`.
  - `Loopctl.Tenants.signup/1` atomically creates the tenant, persists
    every verified authenticator, flips the status to `:active`, and
    writes the audit log genesis entry in a single `Ecto.Multi`.
  - OpenAPI schemas: `TenantSignupRequest`, `WebAuthnChallenge`,
    `WebAuthnAttestation`; `TenantResponse` updated to surface the new
    `pending_enrollment` status.
  - New post-signup onboarding LiveView at `/tenants/:id/onboarding`
    that scaffolds the four-step operator checklist (audit key
    generation, system article tour, first project, first agent).
  - JavaScript `WebAuthn` hook in `assets/js/hooks/webauthn.js`.
  - `CoreComponents` module providing `<.input>`, `<.icon>`, and
    `<.flash_group>` in the design-system palette.

### Removed

- `POST /api/v1/tenants/register` and the `Loopctl.Auth.register_tenant/1`
  helper it called. Chain of Custody v2 requires a WebAuthn-gated signup
  ceremony; the legacy unauthenticated tenant creation path has no
  replacement and any request to it now 404s. This enforces AC-26.0.1.7.
