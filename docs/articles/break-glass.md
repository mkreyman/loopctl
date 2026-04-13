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

```bash
POST /api/v1/admin/tenants/:id/clear-halt
```

Requires a fresh WebAuthn assertion from a root authenticator.

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
