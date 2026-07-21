---
title: "Break Glass — Emergency Override Procedures"
category: reference
scope: system
---

# Break Glass

In rare cases, the chain-of-custody invariants may need to be overridden.
This article documents the emergency procedures.

## When to use break-glass

- All authenticators for a tenant are lost
- The audit chain is corrupted and cannot be repaired
- A tenant is halted due to a false-positive divergence detection

## Clearing a custody halt

Clearing a halt is a mandatory **two-step, challenge-bound** WebAuthn ceremony.
A superadmin key alone is NOT sufficient — each clear must be authorized by a
fresh, single-use assertion from one of the target tenant's enrolled root
authenticators. Both steps require superadmin.

**Step 1 — request a challenge:**

```bash
POST /api/v1/admin/tenants/:id/clear-halt/challenge
```

Mints a server-side, single-use, TTL-bounded challenge bound to the target
tenant and returns `challenge_id`, `challenge`, `allowed_credentials`, `rp_id`,
and `expires_at`. Returns `422 no_authenticators` if the tenant has no enrolled
root authenticator.

**Step 2 — present the assertion:**

```bash
POST /api/v1/admin/tenants/:id/clear-halt
```

Send the WebAuthn assertion (in the `webauthn_assertion` field) produced for the
challenge from step 1. The server verifies the assertion against the STORED
challenge (challenge binding, origin, RP-ID, signature against the enrolled COSE
key, sign-counter regression) and, on success, clears the halt. The challenge is
consumed exactly once — one challenge authorizes exactly one attempt, and replay
is rejected. Rejected attempts are recorded in the tenant's tamper-evident audit
chain.

## Key recovery

If the Fly secret containing the audit signing key is deleted, contact
the loopctl maintainer. Recovery requires:
1. Proof of tenant ownership (WebAuthn assertion)
2. A new keypair generation
3. A key-rotation audit entry signed by the new key
4. Manual update of the Fly secret

This is intentionally difficult — it represents a total compromise of
the trust anchor.

See [Tenant Signup](/wiki/tenant-signup) for normal key management.
