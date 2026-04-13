---
title: "Tenant Signup — WebAuthn Enrollment Ceremony"
category: reference
scope: system
---

# Tenant Signup — WebAuthn Enrollment Ceremony

Every loopctl tenant begins with a human operator enrolling a hardware
authenticator. This ceremony is the Layer 0 anchor of the chain of
custody — without it, the entire trust model degrades to policy
enforcement.

## Requirements

- A FIDO2-compatible authenticator: YubiKey, Touch ID, Windows Hello,
  or any device implementing the WebAuthn standard
- A modern browser with WebAuthn support (Chrome 67+, Firefox 60+,
  Safari 14+, Edge 79+)

## The ceremony

1. Visit `https://loopctl.com/signup`
2. Enter your tenant name, slug, and contact email
3. Click "Enroll authenticator" — your browser prompts for a physical
   touch on your YubiKey or biometric confirmation
4. The server verifies the FIDO2 attestation cryptographically
5. Optionally enroll up to 4 backup authenticators in the same session
6. Submit — the tenant is created atomically with:
   - The tenant record (status: active)
   - Root authenticator record(s)
   - An ed25519 audit-signing keypair
   - The genesis audit chain entry

## Audit-signing keypair

At signup, loopctl generates an ed25519 keypair:
- **Public key** stored on the tenant record (visible via API)
- **Private key** stored as a Fly.io secret (never in the database,
  never accessible to agents)

This keypair signs every Signed Tree Head (STH) and capability token
for the tenant's audit chain.

## Key rotation

The audit key can be rotated via `POST /tenants/:id/rotate-audit-key`.
Rotation requires a fresh WebAuthn assertion — agents cannot rotate keys.

## Recovery

If all authenticators are lost and the Fly secret is deleted, tenant
recovery requires out-of-band contact with the loopctl maintainer.
This is intentionally difficult — it represents a total compromise of
the trust anchor.

## Related articles

- [Chain of Custody](/wiki/chain-of-custody) — the trust model
- [Discovery](/wiki/discovery) — the `.well-known` contract
