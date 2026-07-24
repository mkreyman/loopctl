LCP-1
=====

Custody Claims
--------------

`draft` `mandatory` `server` `agent`

**Status**: draft. Normative for loopctl deployments advertising `custody_profile` in
`/.well-known/loopctl`.

**Depends on**: LCP-2 (Dispatch Lineage), LCP-3 (Audit Chain and Signed Tree Heads).
Both are referenced normatively below and are expected to be extracted into their own
documents; until then the clauses in §5 and §8 are normative in place.

## Abstract

This document specifies the protocol by which a loopctl deployment records, and a third
party verifies, the claim that a unit of work was implemented by one party and confirmed
by a structurally independent party. It defines the custody state machine, the identity
and lineage model, the three custody gates and their exact rejection conditions, the
canonical serializations that are hashed and signed, and the security properties a
verifier may rely on.

The protocol's single guarantee is negative and should be read as such: **no party may
advance a work item to a verified state on the strength of its own assertion alone.**
Everything below exists to make that guarantee checkable by someone who did not write
the server.

## Motivation

An audit log records what happened. A custody protocol records *who was entitled to say
it happened*. The distinction matters as soon as more than one party relies on the
record.

Existing loopctl deployments enforce custody entirely server-side: a caller presents a
bearer credential, the server resolves that credential to an identity and a lineage, and
the server decides. This is sound against a dishonest *agent* and unsound against a
dishonest *operator* — the server that evaluates the gate is also the server that writes
the audit entry, so it can produce a well-formed custody record for work that never
happened. A tenant that does not operate the server has no way to tell the difference.

This document therefore defines two conformance profiles (§2). The `bearer` profile
specifies what a server-side deployment enforces and is honest about its limits. The
`signed` profile adds agent-held signing keys so that custody claims are attributable to
the agent rather than asserted by the operator, and are verifiable offline.

## Non-Goals

This document does not specify transport, authentication of humans, work-item schema, or
review content. It does not define how an implementation decides that work is *correct* —
only who is permitted to assert that it is. It does not defend against an adversary who
controls both the implementing agent's key and an independently-lineaged verifier's key;
see §10.3.

## 1. Conventions

The key words MUST, MUST NOT, REQUIRED, SHALL, SHOULD, SHOULD NOT, MAY, and OPTIONAL are
to be interpreted as described in RFC 2119.

`||` denotes octet-string concatenation. `LP(x)` denotes the length-prefixed encoding of
octet string `x`: the unsigned 64-bit big-endian length of `x`, followed by `x`.

## 2. Conformance Profiles

A deployment MUST advertise exactly one custody profile.

| Profile  | Custody decision | Claim attributable to | Operator can forge a claim |
|----------|------------------|-----------------------|----------------------------|
| `bearer` | server-side, from a bearer credential | the server | **yes** |
| `signed` | server-side, over an agent-signed claim | the agent keypair | no |

A `signed`-profile deployment MUST implement every requirement of the `bearer` profile in
addition to §9. The profiles are cumulative, not alternative: signatures augment the
gates, they never replace them.

### 2.1 Discovery

`GET /.well-known/loopctl` MUST include:

```json
{
  "spec_version": "2",
  "custody_profile": "bearer",
  "custody_spec": "https://loopctl.com/spec/LCP-1",
  "custody_gates": ["report", "review_complete", "verify"],
  "audit_leaf_hash_version": 1
}
```

`custody_profile` MUST be one of `bearer` or `signed`. A client that does not recognise
the advertised value MUST treat the deployment as providing no custody guarantee rather
than assuming a default.

Clients MUST NOT infer the profile from the presence or absence of a signature field on
any individual response. A deployment that has begun emitting signatures but still
accepts unsigned claims is a `bearer` deployment.

## 3. Definitions

- **Work item**: the unit under custody. Called a *story* in the loopctl data model.
- **Agent**: a non-human party executing work, identified by an agent identifier and, in
  the `signed` profile, a keypair.
- **Dispatch**: a delegation record binding a credential to a lineage path (§5).
- **Lineage path**: the ordered list of dispatch identifiers from a root dispatch to a
  given dispatch, inclusive.
- **Implementer**: the party recorded as having performed the work.
- **Custody claim**: an assertion that a work item has reached a custody state, submitted
  by a party other than the implementer.
- **Custody-orphaned work item**: a work item carrying no provenance for who performed
  the work (§7.1).
- **Verifier**: the party asserting that work satisfies its acceptance criteria.

## 4. Custody State Machine

A work item carries two independent status fields. Implementations MUST NOT collapse them
into one.

- `agent_status` — self-reported by the working party.
- `verified_status` — set only through the `verify` gate.

The transitions under custody control are:

| Transition | Gate | §  |
|------------|------|----|
| → `reported_done` | `report` | 7.2 |
| → review recorded | `review_complete` | 7.3 |
| → `verified` | `verify` | 7.4 |

A verifier reading a work item MUST treat `agent_status` as an unverified assertion by
the working party regardless of its value, and MUST derive trust only from
`verified_status` together with the audit chain entries that produced it.

## 5. Identity and Lineage

### 5.1 Server-side derivation

The caller's lineage path MUST be derived server-side from the credential that
authenticated the request. Implementations MUST NOT accept a lineage path, an agent
identifier, or a dispatch identifier from the request body, query string, or any
client-controlled header for the purpose of evaluating a custody gate.

A credential not minted by a dispatch MUST resolve to the empty lineage `[]`. A credential
whose dispatch is revoked MUST resolve to `[]`.

### 5.2 Lineage separation predicate

Two lineage paths are *separated* if and only if they do not share a root.

```
SHARES_ROOT(a, b) =
  false                     if a = [] or b = []
  true                      if a[0] = b[0]
  false                     otherwise
```

This is a shared-**root** test, not a general common-prefix test. Every dispatch descended
from a common root shares element 0, and that is what "same lineage" means for custody
purposes. Implementations MUST NOT substitute a longest-common-prefix comparison: doing so
would treat two siblings under one root as separated.

`SHARES_ROOT` returning `false` for an empty operand is a deliberate property of the
predicate and is **not** by itself a permit. Callers MUST consult §7.5 for how an
unresolvable lineage is handled at each gate, because the answer is not uniform.

### 5.3 Verifier selection

Where a deployment selects a verifier automatically, the selection MUST exclude every
candidate whose lineage shares a root with the implementer's, and the exclusion MUST be
applied both in the candidate query and again after the query returns. Selection MUST be
deterministic given the work item, and MUST NOT be predictable by the party requesting it;
seeding the selection index from `SHA-256(tenant_audit_public_key || work_item_id)`
satisfies this.

Where the implementer lineage is `[]`, the exclusion is inert and selection MAY return a
same-lineage candidate. Deployments MUST NOT treat successful selection as evidence of
separation; separation is established at gate-evaluation time (§7), not at selection time.

## 6. Claim Envelope

Every custody claim is submitted as an envelope:

```json
{
  "gate": "verify",
  "work_item_id": "<uuid>",
  "capability": "<capability token id>",
  "body": { },
  "claim_sig": "<base64url, signed profile only>",
  "agent_pubkey": "<base64url, signed profile only>"
}
```

In the `bearer` profile `claim_sig` and `agent_pubkey` MUST be absent, and a server
receiving them MUST reject the request rather than ignoring the fields. In the `signed`
profile both are REQUIRED and are specified in §9.

## 7. The Custody Gates

Each gate is specified as an ordered sequence of clauses. Implementations MUST evaluate
the clauses in the order given and MUST return on the first clause that matches. The order
is normative: several clauses are reachable only because an earlier clause did not
short-circuit them.

Throughout, `caller_id` is the caller's agent identifier and `caller_lineage` is the
caller's lineage path, both derived per §5.1.

### 7.1 Custody-orphan predicates

```
UNATTRIBUTED(w)     = w.assigned_agent_id = nil AND w.implementer_dispatch_id = nil
ORPHANED(w)         = UNATTRIBUTED(w) AND w is reported-done AND w is not verified
```

These predicates are the sole enforcement for a work item that was never dispatched. A
database constraint of the form "reported-done requires an assigned agent" is satisfied
whenever `implementer_dispatch_id IS NULL`, which is exactly the orphaned shape, and
therefore does **not** close this case. Implementations MUST NOT remove either predicate on
the grounds that a constraint appears to cover it.

The rejection exists because the identity comparisons below would otherwise pass
*vacuously*: a non-nil caller is never equal to a nil implementer.

### 7.2 `report`

Advances `agent_status` to `reported_done`.

```
1. caller_id = nil                        → REJECT self_report_blocked
2. UNATTRIBUTED(w)                        → REJECT missing_assigned_agent   [log]
3. LINEAGE_CONFLICT(w, caller_lineage)    → REJECT self_report_blocked
4. w.assigned_agent_id ≠ nil
     AND w.assigned_agent_id = caller_id  → REJECT self_report_blocked
5. otherwise                              → PERMIT
```

Clause 1 is normative: an unknown identity is untrusted, never permissive.

### 7.3 `review_complete`

Records a review outcome.

```
1. ORPHANED(w)                            → REJECT missing_assigned_agent   [log]
2. caller_id = nil                        → PERMIT                          [see below]
3. LINEAGE_CONFLICT(w, caller_lineage)    → REJECT self_review_blocked
4. w.assigned_agent_id ≠ nil
     AND w.assigned_agent_id = caller_id  → REJECT self_review_blocked
5. otherwise                              → PERMIT
```

**Clause 2 is the single documented departure from "nil is never permissive" and it is
load-bearing in three places at once.** A nil caller identity at this gate denotes a human
operator on a human-role credential, who is structurally distinct from any agent and
therefore cannot equal the implementer. The permit is only sound while all three of the
following hold, and an implementation changing any one of them MUST change all three
together:

- (a) the transport gate admits only human-role and orchestrator-role credentials at this
  endpoint, so an agent credential is rejected before the clause is reached;
- (b) the request handler rejects an orchestrator-role credential that carries no agent
  identifier, so nil unambiguously means "human" rather than "agent that omitted its id" —
  there is no sentinel value standing in for a human;
- (c) this clause itself.

Removing (a) or (b) while leaving (c) converts clause 2 into an unauthenticated bypass of
the entire gate.

Note that clause 1 uses `ORPHANED`, not `UNATTRIBUTED`: this gate runs only against
reported-done work.

### 7.4 `verify`

Sets `verified_status`.

```
1. caller_id = nil                        → REJECT self_verify_blocked
2. ORPHANED(w)                            → REJECT missing_assigned_agent   [log]
3. w.implementer_dispatch_id ≠ nil
     AND w.verifier_dispatch_id ≠ nil     → evaluate SEPARATED (§7.4.1)
4. w.assigned_agent_id ≠ nil
     AND w.assigned_agent_id = caller_id  → REJECT self_verify_blocked
5. otherwise                              → PERMIT
```

#### 7.4.1 SEPARATED

Let `impl` and `verif` be the lineage paths resolved from
`w.implementer_dispatch_id` and `w.verifier_dispatch_id`. An unresolvable dispatch
resolves to `[]`.

```
1. impl = [] OR verif = []                → REJECT self_verify_blocked      [log]
2. SHARES_ROOT(impl, verif)               → REJECT self_verify_blocked
3. w.assigned_agent_id ≠ nil
     AND w.assigned_agent_id = caller_id  → REJECT self_verify_blocked
4. otherwise                              → PERMIT
```

Both halves of this clause are normative and are frequently got wrong:

- Clause 1 makes an unresolvable dispatch **fail closed**. Without it, `SHARES_ROOT([], x)
  = false` would cause a dispatch row that cannot be loaded — because it was deleted,
  revoked, or never existed — to read as *independent lineage*, which is the opposite of
  the truth.
- Clause 3 evaluates identifier equality **in addition to** the lineage comparison, not
  instead of it. An implementation that returns PERMIT immediately upon finding separated
  lineages skips it.

### 7.5 LINEAGE_CONFLICT, and the non-uniform treatment of unresolvable lineage

```
LINEAGE_CONFLICT(w, caller_lineage) =
  false                                   if w.implementer_dispatch_id = nil
  false                                   if caller_lineage = []
  SHARES_ROOT(impl, caller_lineage)       otherwise, where impl resolves
                                          w.implementer_dispatch_id, [] if unresolvable
```

**Implementations MUST NOT assume the three gates treat an unresolvable lineage
identically.** They do not:

| Situation | `verify` | `report` / `review_complete` |
|-----------|----------|------------------------------|
| Caller lineage `[]` (legacy or revoked credential) | n/a — verify compares stored dispatch rows | falls through to identifier equality (clause 4) |
| Implementer dispatch unresolvable | **rejects** (§7.4.1 clause 1) | falls through to identifier equality (clause 4) |

At `report` and `review_complete` an unresolvable or revoked lineage therefore degrades
the gate to plain identifier equality rather than blocking. This is weaker than `verify`.
It is specified here as the current normative behaviour so that a verifier does not
over-rely on it; see §10.2 for what this means for the guarantee, and §12 for the open
question of whether to align the three.

### 7.6 Capability binding

Where a deployment issues capability tokens, a custody gate MUST additionally require a
valid token, and the token MUST be:

- typed to the gate, and rejected on type mismatch;
- bound to the work item, and rejected on mismatch;
- bound to the caller's lineage by **exact equality** of the lineage path, not by
  `SHARES_ROOT`;
- rejected when expired;
- consumed atomically, such that a second presentation of the same token is rejected as a
  replay. The consume operation MUST be a single conditional update predicated on the
  not-yet-consumed state. A read-then-write sequence is non-conforming: it reintroduces
  the replay window it exists to close.

A deployment that conditions capability enforcement on tenant state (for example,
exempting tenants provisioned before capability support existed) MUST emit a distinguishable
warning and a counter for each exempted call, so that the set of degraded tenants is
observable rather than silent.

## 8. Audit Chain Serialization

Every gate decision, permit or reject, MUST append an entry to a per-tenant hash chain.

### 8.1 Leaf hash, version 1

Version 1 is the construction currently deployed. It is specified here for completeness
and for verifiers of existing chains. **It MUST NOT be used for new chains** and is
deprecated by §8.2.

```
H1 = SHA-256(
       tenant_id ||
       decimal(chain_position) ||
       prev_entry_hash ||
       JSON({action, actor_lineage, entity_id, entity_type, payload}) ||
       iso8601(inserted_at)
     )
```

Version 1 has two defects that a third-party verifier MUST be aware of:

1. **The JSON encoding is not canonicalized.** Key order is whatever the serializer
   produces for the runtime's map representation, which is not a specified property and is
   not guaranteed stable across runtime versions or across atom-keyed and string-keyed
   representations of the same logical payload. A verifier reading a payload back from
   storage MAY therefore be unable to reproduce the hash that was computed at write time.
2. **Fields are concatenated without separation.** `decimal(chain_position)` is
   variable-length and directly abuts a fixed-length predecessor, so distinct field tuples
   can in principle produce identical preimages.

### 8.2 Leaf hash, version 2

```
H2 = SHA-256(
       LP("loopctl/audit-leaf/2") ||
       LP(tenant_id) ||
       uint64_be(chain_position) ||
       LP(prev_entry_hash) ||
       LP(action) ||
       LP(canonical_json(actor_lineage)) ||
       PRESENT(entity_type) ||
       PRESENT(entity_id) ||
       LP(canonical_json(payload)) ||
       LP(rfc3339_utc(inserted_at))
     )
```

where `PRESENT(x)` is `0x00` when `x` is absent, and `0x01 || LP(x)` when present.

The genesis entry MUST use 32 zero octets as `prev_entry_hash`.

`tenant_id` MUST lead the preimage. This binds chain identity to the tenant, so that an
entry cannot be lifted out of one tenant's chain and re-verified inside another.

`PRESENT` is REQUIRED rather than encoding absence as an empty string: without it, an
absent field and a present-but-empty field produce identical preimages.

`canonical_json` is defined in §8.3. Serialization failure MUST be a hard error. An
implementation MUST NOT substitute an empty value for a payload it failed to serialize —
doing so produces a hash that commits to nothing.

### 8.3 canonical_json

```
canonical_json(object) = "{" ⟨ key ":" canonical_json(value) ⟩ *("," …) "}"
                         with keys sorted ascending by their UTF-8 octet sequence
canonical_json(array)  = "[" ⟨ canonical_json(element) ⟩ *("," …) "]"
canonical_json(scalar) = the shortest JSON encoding of the scalar
```

Object keys MUST be compared as octet sequences after UTF-8 encoding. Implementations
MUST normalize keys to strings before sorting; a runtime that distinguishes symbol keys
from string keys MUST NOT sort them in the runtime's native term order, because that order
differs from octet order.

### 8.4 Version negotiation

Each entry MUST record the leaf-hash version used to produce it. A verifier MUST use the
recorded version and MUST NOT assume the current one. `/.well-known/loopctl` MUST advertise
`audit_leaf_hash_version` for entries the deployment is currently writing.

### 8.5 Independent recomputation

A conforming deployment MUST expose sufficient data for a third party to recompute every
leaf hash from entry content and compare it against the stored hash. A deployment that
verifies only chain *linkage* (`prev_entry_hash` matches the predecessor) and inclusion
proofs against stored hashes does **not** conform: those checks prove the sequence is
intact, not that any hash commits to the content of its own entry.

### 8.6 Signed Tree Heads

A deployment MUST periodically publish a signed head over the chain:

```
message   = tenant_id || decimal(chain_position) || merkle_root || iso8601(signed_at)
signature = Ed25519(tenant_audit_private_key, message)
```

The corresponding public key MUST be retrievable by any party that can identify the
tenant. Inclusion proofs MUST verify against a published head.

**The STH signature is only as meaningful as §8.5.** A signature over a Merkle root
computed from leaf hashes that nobody can reproduce from content authenticates the
server's bookkeeping, not the events. Deployments MUST NOT describe an STH as evidence of
event integrity unless §8.5 holds.

## 9. Signed Profile

This section applies only to deployments advertising `custody_profile: "signed"`.

### 9.1 Keys

Each agent MUST hold an Ed25519 keypair whose private half is never transmitted to the
server and never leaves the agent's execution environment. The agent's public key is
recorded on its dispatch.

Compromise of an agent private key MUST NOT imply compromise of any other key. In
particular it MUST NOT imply compromise of the credential that authorized the dispatch.

### 9.2 Dispatch attestation

A dispatch in the `signed` profile is an authorization credential over the agent's own
public key, not a bearer token issued in place of one. The authorizing party signs:

```
preimage = "loopctl/dispatch-attestation/1" ||
           LP(tenant_id) ||
           LP(agent_pubkey) ||
           LP(canonical_json(lineage_path)) ||
           LP(conditions)
attestation = Ed25519(authorizer_private_key, SHA-256(preimage))
```

`conditions` is a UTF-8 string of zero or more `&`-separated clauses, each of the form
`gate=<name>` or `expires<unix-timestamp>`. Whitespace is not permitted. A leading `&`,
trailing `&`, or `&&` is malformed and MUST be rejected. Decimal values MUST be canonical
base-10 with no leading zeros except `0`.

Verifiers MUST evaluate every clause and MUST reject an attestation carrying an
unrecognised clause. The `conditions` string is part of the signed preimage: implementations
MUST NOT reorder, deduplicate, or normalize it before verifying.

An attestation whose authorizer public key equals `agent_pubkey` is a self-attestation and
MUST be rejected.

The attestation authorizes; it does not transfer authorship. A verifier MUST treat
`agent_pubkey` as the sole author of any claim carrying the attestation, and MUST NOT
attribute the claim to the authorizer or merge it into the authorizer's activity.

### 9.3 Claim signature

```
preimage  = "loopctl/custody-claim/1" ||
            LP(tenant_id) ||
            LP(gate) ||
            LP(work_item_id) ||
            LP(canonical_json(body)) ||
            LP(capability_id) ||
            uint64_be(claimed_at)
claim_sig = Ed25519(agent_private_key, SHA-256(preimage))
```

A server MUST reject a claim whose signature does not verify against the `agent_pubkey`
recorded on the caller's dispatch, **before** evaluating any clause of §7. Signature
failure MUST NOT be reported as a custody rejection: the two are different conditions and
a client's recovery differs.

`claimed_at` is agent-declared and therefore agent-controlled. Servers requiring freshness
MUST enforce it against their own clock independently; the signature proves authorship,
not timeliness.

### 9.4 Audit binding

An entry recording a signed-profile gate decision MUST include `agent_pubkey` and
`claim_sig` within the hashed `payload`, so that the chain commits to the signature and a
verifier replaying the chain can re-check authorship offline without querying the server.

## 10. Security Properties

### 10.1 What both profiles guarantee

Given an intact chain and an honest server, no single agent identity, and no set of agent
identities sharing a lineage root, can carry a work item from implementation to verified
without a party outside that root acting.

### 10.2 What the `bearer` profile does not guarantee

The operator can forge any custody claim. The server resolves identity, evaluates the
gate, and writes the entry; nothing in the record distinguishes an entry produced by a
real agent from one produced by the server. A tenant that does not control the server MUST
NOT treat a `bearer`-profile custody record as evidence against the operator.

Additionally, per §7.5, the `report` and `review_complete` gates degrade to identifier
equality when a lineage cannot be resolved. An adversary able to cause an implementer's
dispatch row to become unresolvable — by revoking it, for example — weakens those two
gates to the pre-lineage guarantee. `verify` is not affected.

### 10.3 What neither profile guarantees

Neither profile defends against an adversary holding both an implementing key and a key
whose lineage is genuinely separated from it. Structural separation is a statement about
delegation topology, not about the real-world independence of the parties holding the
keys. Deployments requiring the latter MUST obtain it by other means — independent
re-execution of acceptance criteria, or verifier keys held by a distinct principal.

An agent that backdates or misreports its own `claimed_at`, work content, or review
findings is not detected by this protocol. Detecting *dishonest but well-formed* work is
out of scope; see the behavioural-detection and independent-re-execution layers of the
system design.

## 11. Test Vectors

> **Status: not yet generated.** Vectors MUST be produced by executing the reference
> implementation rather than hand-derived, and committed alongside this document at
> `docs/spec/vectors/LCP-1/`. A spec whose vectors were written by hand tests the
> author's understanding, not the implementation.

The following vectors are REQUIRED before this document leaves `draft`:

1. **`SHARES_ROOT` truth table** — every combination of empty, single-element, and
   multi-element paths with matching and non-matching roots, including the sibling case
   (`[r, a]` vs `[r, b]` → `true`) that distinguishes a shared-root test from a
   longest-common-prefix test.
2. **Gate decision matrix** — for each of the three gates, one vector per clause,
   constructed so that exactly one clause matches. Each vector states the clause it is
   intended to exercise, so that a reordering regression fails loudly rather than
   returning the right answer for the wrong reason.
3. **`canonical_json`** — nested objects with keys requiring octet-order rather than
   lexicographic-by-code-point sorting; mixed-case keys; keys differing only past a common
   prefix; empty object and empty array; and the same logical payload expressed with
   symbol keys and with string keys, which MUST produce identical output.
4. **Leaf hash v2** — a genesis entry and its successor, with absent and present optional
   fields, demonstrating that `PRESENT` distinguishes absent from empty.
5. **Signed profile** — a dispatch attestation and a claim signature with published
   private keys, in the style of the worked example in §9.

### 11.1 Invalid Vectors

Verifiers MUST reject each of the following. These are REQUIRED as executable negative
tests, not prose.

- A claim carrying `claim_sig` or `agent_pubkey` in a `bearer`-profile deployment.
- A dispatch attestation whose authorizer public key equals `agent_pubkey`.
- An attestation `conditions` string of `gate=verify&` (trailing delimiter).
- An attestation `conditions` string containing `expires<01` (non-canonical decimal).
- An attestation `conditions` string containing an unrecognised clause.
- A well-formed claim signature over a `body` that differs from the submitted `body`.
- A capability token bound to a lineage that merely *shares a root* with the caller's
  rather than being equal to it.
- A second presentation of an already-consumed capability token.
- A `verify` call on a work item whose implementer dispatch cannot be resolved.
- A `verify` call where lineages are separated but `assigned_agent_id` equals the caller —
  the §7.4.1 clause 3 case that a short-circuiting implementation would permit.
- A `report` call on a work item with nil `assigned_agent_id` and nil
  `implementer_dispatch_id`.
- A `review_complete` call by an agent-role credential carrying no agent identifier,
  which would otherwise reach the §7.3 clause 2 human permit.
- A leaf-hash recomputation of a v1 entry using the v2 construction.

## 12. Open Questions

These MUST be resolved before this document leaves `draft`.

1. **Should `report` and `review_complete` fail closed on an unresolvable lineage, as
   `verify` does (§7.5)?** Aligning them strengthens the guarantee and removes a
   documented asymmetry that implementers will otherwise get wrong. It also means a
   revoked dispatch begins blocking operations that previously succeeded, which is a
   behavioural change for existing deployments and needs a migration story.
2. **Where does an agent private key live in practice, and what is the threat model for
   its storage?** §9.1 states the requirement and not the mechanism. A key sitting in a
   file next to the credential it replaces defeats much of the point against a local
   attacker, though not against a dishonest operator, which is the threat §9 exists to
   address.
3. **Should capability-token message construction adopt the §1 `LP` framing?** The
   currently deployed construction concatenates variable-length fields without separation,
   which is the same defect §8.1 documents for leaf hashes and should be fixed in the same
   pass rather than separately.
4. **Does `signed` profile require the *operator* to hold no agent private keys, and if so
   how is that attested?** Without an answer, a deployment can advertise `signed` while
   generating agent keys server-side, which reduces the profile to `bearer` with extra
   steps.

## 13. Relationship to Other Documents

- `docs/chain-of-custody-v2.md` — design rationale and threat model. Non-normative;
  where it and this document disagree about enforced behaviour, this document is wrong and
  MUST be corrected against the implementation.
- `.claude/skills/chain-of-custody/SKILL.md` — implementer-facing code map with file and
  line citations. Non-normative and deliberately coupled to the source layout.
- This document is the only one of the three intended to be implementable by a party
  without access to the loopctl source.
