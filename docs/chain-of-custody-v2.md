# Chain of Custody v2

Loopctl is an agent-only platform. Every actor inside the system — orchestrators, implementers, reviewers, verifiers — is an LLM agent with full source access, the ability to read its own constraints, and strong incentives to take shortcuts that look like efficiency. The system's value is preventing those agents from (a) approving their own work and (b) declaring incomplete work complete.

This document is the authoritative specification for how loopctl enforces honest behavior. Every invariant described here is self-advertising: agents encountering the system for the first time can discover it through the `.well-known/loopctl` endpoint, the system-scoped knowledge wiki, and machine-readable error responses. Nothing in this document requires an agent to read source code or prior documentation.

## 1. Threat model

Two adversary profiles, both handled as first-class.

### 1.1 The sneaky adversary

An agent that understands the chain-of-custody rules and tries to bypass them without tripping a block. Signatures:

- Uses one identity to implement and a second identity (same underlying process) to "independently" approve
- Mints credentials for itself or manipulates identity metadata to satisfy literal equality checks while violating the spirit
- Exploits advisory checks (read-then-act, policy-level gates) that the application layer can reach around
- Relies on nil / empty / missing fields as permissive defaults
- Provides unverifiable evidence (a commit SHA, a test name) without the system confirming it exists

### 1.2 The lazy adversary

An agent that declares work done without actually finishing it. Signatures:

- Reports `reported_done` with acceptance criteria unmet
- Marks failing tests as skipped or flaky, then passes precommit
- Commits a subset of the change and stops
- Dispatches a sub-agent to "review" and has it rubber-stamp immediately
- Cites "efficiency" to justify incomplete work
- Invokes handwave phrases like "substantially complete" to push a transition through

### 1.3 What loopctl does not defend against

- A compromised LLM model provider. If the model itself is backdoored, every signed attestation will validate. Defense: external audit of model selection + diverse verification.
- A compromised operator who loses control of their hardware authenticator AND their Fly secrets simultaneously. Defense: tenant recovery ceremony, which is loud and manual.
- Physical coercion of the human operator. Out of scope.
- Novel prompt-injection attacks that hijack agent behavior via malicious story descriptions. Mitigation is upstream (story review) but not part of the trust model.

## 2. Design principles

Eight principles that govern every enforcement decision.

### 2.1 Structural over policy

A policy check says "if (condition) then :ok else :error". A structural check makes the forbidden operation unreachable — the caller cannot construct the action because no capability to perform it exists in their namespace. Structural enforcement cannot be reached around by a creative adversary. Every invariant in this document is implemented structurally wherever possible; application-level policy checks are defense-in-depth, not primary.

### 2.2 Nil is never permissive

Whenever identity, role, or evidence is absent, the default is reject. "Unknown" is treated as adversarial. A check that says `if is_nil(reviewer_agent_id), do: :ok` is a bug, regardless of rationalization. Loopctl contains zero such checks after this redesign.

### 2.3 Every response is a teaching moment

Successful and unsuccessful responses both carry self-descriptive instructions. A naive agent that has never seen loopctl can follow a chain of API calls from first contact to story verification without reading any external documentation. Every error response includes a reason code, a machine-readable remediation, and a link to an authoritative system article. Every successful custody operation includes the next legal action and, where applicable, the capability token required for it.

### 2.4 Advisory checks must be backstopped

Every invariant has a primary enforcement layer and at least one lower-trust backstop. A capability check in the controller is backstopped by a database constraint. A database constraint is backstopped by a cryptographic signature on the request. If the primary enforcement is compromised, the backstop catches the failure.

### 2.5 Independent re-execution beats self-reporting

The verifier of a piece of work does not trust the implementer's report. The verifier independently fetches the artifact, re-runs the tests, and checks each acceptance criterion against the actual code. This is mandatory for lazy-bastard resistance; there is no alternative.

### 2.6 Multi-agent witnesses defeat single-point tampering

A per-tenant audit chain is tamper-evident not because a single trusted third party watches it, but because every agent in the tenant holds its own cached view of the chain. Divergence between what an agent saw and what the server now claims is cryptographic evidence of tampering. The more active agents a tenant has, the harder tampering becomes.

### 2.7 Halt on byzantine conditions

When the system detects a chain-of-custody violation, a capability violation, or a witness divergence, it halts the offending tenant's custody operations pending human review. Liveness is sacrificed to preserve safety. This mirrors the FLP impossibility result: you cannot have safety, liveness, and asynchrony; when byzantine conditions appear, liveness is the one you give up.

### 2.8 Honest work is the path of least resistance

Dishonest work requires custom attack development for every bypass attempt. Honest work is assisted by pre-minted capability tokens, inline next-action guidance, auto-populated acceptance criteria, and a discovery endpoint that tells agents exactly what to do. The ergonomic gradient points toward honesty.

## 3. The six-layer enforcement stack

Every invariant in loopctl is enforced at the lowest possible layer. Layers are numbered from most-trusted (L0) to least-trusted (L5).

### L0 — Human + hardware anchor

**What**: the only truly unforgeable authority in the system. A physical hardware authenticator (WebAuthn / FIDO2 / YubiKey) held by the tenant's human operator, enrolled at tenant signup.

**Enforces**:
- Tenant creation and root key rotation
- Destructive operations (project delete, budget raise, anomaly resolve, break-glass override)
- Tenant recovery after authenticator loss

**Adversary reach**: none. An agent cannot press a hardware button. An agent cannot forge a WebAuthn attestation without the private key stored inside the authenticator's secure element.

### L1 — Capability tokens

**What**: short-lived, scoped, signed tokens minted by loopctl at custody transitions. Each token binds a specific action to a specific story, role, and lineage, with an expiry. Tokens are returned to the caller in response bodies and carried in subsequent requests.

**Enforces**:
- `report_story`, `review_complete`, `verify_story` require a matching capability token
- `start_story` requires the dispatch token that was issued at claim time
- Sub-agent dispatch requires the parent's active token as a witness

**Adversary reach**: cannot forge the token signature without loopctl's signing key. Cannot reuse tokens across stories (scoped). Cannot replay expired tokens (expiry). Cannot construct a cap for an agent lineage the token was not issued to (lineage binding).

### L2 — Database invariants

**What**: PostgreSQL constraints, foreign keys, partial unique indexes, triggers, and hash chains that make invalid states unrepresentable.

**Enforces**:
- `api_keys.agent_id` has a FK to `agents(id)` (nullable only for root human keys)
- Partial unique index on `(tenant_id, agent_id) WHERE revoked_at IS NULL AND role != 'user'` — one active non-user key per agent, ever
- `api_keys.role` is immutable after creation (trigger raises on UPDATE of role)
- `audit_chain` entries are hash-chained and append-only (triggers reject UPDATE and DELETE)
- `verification_results` cannot reference an `implementer_lineage` that overlaps the `verifier_lineage` (check constraint)

**Adversary reach**: cannot insert invalid rows — the database rejects them. Cannot rewrite existing rows — triggers block updates. Cannot forge hash chain entries — the trigger recomputes and verifies on every insert.

### L3 — Independent re-execution

**What**: the verification of a story re-runs the story's work in a clean environment the implementer cannot reach. For projects with CI, loopctl consumes CI results via the provider API. For projects without CI, loopctl spawns an ephemeral verification worker.

**Enforces**:
- Test suite pass/fail is determined by the verification environment, not the implementer's self-report
- Acceptance criteria with machine-checkable bindings (see §7) are verified against the actual post-commit code
- The artifact commit SHA is content-addressed — fetched from the project's git remote, verified to exist, and its diff is checked against the claimed AC changes

**Adversary reach**: cannot forge test results from a process it does not control. Cannot claim completion of an AC whose machine-checkable binding does not match the committed code. The `sys.exit(0)` attack documented in contemporary research is defeated because the verifier checks which tests actually ran, not just the exit code.

### L4 — Structural role separation

**What**: sub-agent lineage tracking + rotating verifier assignment + ephemeral per-task keys. Two callers are treated as "the same actor" if their dispatch lineage shares a common prefix.

**Enforces**:
- The `LOOPCTL_AGENT_KEY` long-lived environment variable pattern is retired. Each sub-agent dispatch mints an ephemeral key scoped to `(parent_lineage, story_id, role, expiry)`.
- Loopctl records the full dispatch tree. The verifier for a story is chosen by loopctl at `reported_done` time from lineages that do NOT share a prefix with the implementer's lineage.
- The orchestrator cannot pre-select a specific verifier. Verification assignment is rotating and unpredictable to the orchestrator.

**Adversary reach**: can still spawn N sub-agents, but cannot present them as independent. The lineage tree records the real relationship. Lineage divergence is required for custody progression.

### L5 — Behavioral detection

**What**: soft signals from tool-call telemetry and chain-of-thought analysis. Non-blocking; raises warnings that route stories for re-review.

**Enforces**:
- Tool-call counts, CoT lengths, test-run counts per story per role are recorded
- Stories with anomalously low telemetry relative to their complexity are flagged
- Review records with zero tool calls are flagged (a reviewer that doesn't actually look at anything)
- Known cheating markers in chain-of-thought text (from contemporary alignment research) raise alerts

**Adversary reach**: full — these are soft signals that degrade as models become more capable. Behavioral detection is never a trust boundary; it's a warning system that routes suspicious stories to more-scrupulous review.

### L6 — Halt on byzantine conditions

**What**: a circuit breaker that stops the tenant's custody operations when the system detects an unrecoverable trust violation.

**Enforces**:
- Self-verify / self-review detection halts the session
- Capability token mismatch halts
- Audit chain witness divergence halts the tenant's operations for operator review
- Missing required evidence halts
- Rate-limited break-glass overrides

**Adversary reach**: none for the halt itself; the adversary can potentially trigger false halts (denial of service on its own operations), which is detectable and preferable to silent bypass.

## 4. Per-tenant audit chain

The audit chain is loopctl's tamper-evident log of every custody-relevant event. It is hash-chained, append-only, and witnessed by the tenant's own agents. External witnesses (third-party services, transparency logs) are not required.

### 4.1 Schema

```sql
CREATE TABLE audit_chain (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants(id),
  chain_position bigint NOT NULL,
  prev_entry_hash bytea NOT NULL,
  action text NOT NULL,
  actor_lineage jsonb NOT NULL,
  entity_type text NOT NULL,
  entity_id uuid,
  payload jsonb NOT NULL,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  entry_hash bytea NOT NULL,
  UNIQUE (tenant_id, chain_position)
);

CREATE INDEX audit_chain_tenant_time_idx
  ON audit_chain (tenant_id, inserted_at DESC);
```

`entry_hash` is computed as:

```
entry_hash = sha256(
  tenant_id ||
  chain_position ||
  prev_entry_hash ||
  canonical_json(action, actor_lineage, entity_type, entity_id, payload) ||
  inserted_at
)
```

Entry 0 for each tenant has `prev_entry_hash = 0x00...00` (32 zero bytes) and a payload identifying the tenant's genesis event (tenant creation, signed by the operator's WebAuthn authenticator).

### 4.2 Append-only enforcement

Database triggers guarantee the chain cannot be rewritten:

```sql
CREATE TRIGGER audit_chain_prevent_update
  BEFORE UPDATE ON audit_chain
  FOR EACH ROW EXECUTE FUNCTION raise_exception('audit_chain is append-only');

CREATE TRIGGER audit_chain_prevent_delete
  BEFORE DELETE ON audit_chain
  FOR EACH ROW EXECUTE FUNCTION raise_exception('audit_chain is append-only');

CREATE TRIGGER audit_chain_verify_hash
  BEFORE INSERT ON audit_chain
  FOR EACH ROW EXECUTE FUNCTION verify_chain_invariants();
```

`verify_chain_invariants()` checks:
1. `chain_position` equals the max position for this tenant + 1 (no gaps, no reordering)
2. `prev_entry_hash` equals the previous entry's `entry_hash` for this tenant
3. `entry_hash` matches the computed hash of the entry's content

The production database role has no DDL privileges. Triggers cannot be dropped or disabled by application code. A compromised application cannot silently rewrite history.

### 4.3 Signed Tree Heads

Every N entries (default 100) or T seconds (default 60), loopctl computes a Signed Tree Head for each tenant's chain:

```
STH = {
  tenant_id,
  chain_position,     # the latest entry's position
  merkle_root,        # sha256 root of the entire chain
  signed_at,          # timestamp
  signature           # ed25519 signature over (tenant_id || chain_position || merkle_root || signed_at)
}
```

STHs are stored in `audit_signed_tree_heads` and published via `GET /api/v1/audit/sth/:tenant_id`. The public portion of the tenant's signing key is published at `GET /api/v1/tenants/:id/audit_public_key`.

The private signing key is stored as a Fly.io secret, accessible only to the loopctl application process. Key rotation is a human-gated operation (requires the operator's WebAuthn authenticator).

### 4.4 Agent-held witness protocol

Every agent operating in a tenant subscribes to audit events via loopctl's PubSub system (existing infrastructure). As new chain entries are committed, they are broadcast to all subscribed agents. Each agent maintains a local view of the chain: at minimum, the latest STH and the entry hashes since that STH.

Every API call from an agent includes a witness header:

```
X-Loopctl-Last-Known-STH: <position>:<first_16_bytes_of_signature>
```

On every request, loopctl validates:

1. The agent's claimed STH position is ≤ the current STH position for this tenant
2. The STH signature prefix matches the loopctl-side record for that position
3. If yes → request proceeds normally
4. If the STH position is valid but the signature prefix does not match → the agent has cryptographic evidence of a divergence. The tenant's custody operations are halted, a high-priority alert is raised, and operator intervention is required.

A divergence detection is interpreted in two ways, and both halt:
- Either an attacker rewrote the server's chain after the agent cached its view (the attack we care about detecting)
- Or a bug caused the agent to cache incorrect data (a system defect worth investigating)

Either case is unsafe to continue.

### 4.5 The practical effect

A single loopctl operator attempting to rewrite the audit chain has to simultaneously:
- Bypass the database triggers (DDL access)
- Forge STH signatures (requires the signing key, not accessible to any agent)
- Modify every subscribed agent's cached STH to match the rewritten history (impossible without compromising every agent's process memory)

The attack is not mathematically impossible but is economically and operationally infeasible for the typical tenant. The more active agents a tenant has, the harder tampering becomes.

## 5. Capability tokens

Custody-critical endpoints require a capability token in the request body. The token is minted by loopctl at the moment it is needed, issued to a specific caller lineage, and verified by the endpoint against loopctl's public signing key.

### 5.1 Token structure

```json
{
  "typ": "verify_cap",
  "story_id": "uuid",
  "tenant_id": "uuid",
  "issued_to_lineage": "lineage_fingerprint",
  "issued_at": "2026-04-11T12:00:00Z",
  "expires_at": "2026-04-11T14:00:00Z",
  "nonce": "base64url_random",
  "signature": "ed25519_base64url"
}
```

The `signature` field is computed over the canonical serialization of the other fields, using the tenant's audit-signing keypair (the same key used for STHs, for simplicity).

### 5.2 Issuance

Capability tokens are minted at specific transition points:

- **`claim_story` → `assigned`**: mints a `start_cap` issued to the claiming agent's lineage. The response body carries the `start_cap`.
- **`start_story` → `implementing`**: consumes the `start_cap`, mints a `report_cap` issued to the same lineage. The response body carries the `report_cap`.
- **`request_review` → `reported_done`**: consumes the `report_cap`. Loopctl selects a verifier lineage (via the rotating-verifier protocol in §6), mints a `verify_cap` issued to that lineage, and adds it to the `ready_for_verification` queue for that lineage.
- **`verify_story` → `verified`**: consumes the `verify_cap`.

Each cap is minted once and consumed once. Loopctl records every mint and every consumption in the audit chain.

### 5.3 Verification

Every custody-critical endpoint extracts the cap from the request body and validates:

1. Signature matches the tenant's audit public key
2. `typ` matches the endpoint
3. `story_id` matches the path parameter
4. `tenant_id` matches the authenticated caller's tenant
5. `issued_to_lineage` matches the caller's current dispatch lineage
6. `expires_at` is in the future
7. `nonce` has not been consumed (replay protection)

Any failure returns a 403 with a machine-readable reason code and a link to the relevant system article.

### 5.4 Why this closes the sneaky-bastard gap

An adversary that controls the implementer cannot call `verify_story` because:

- It does not hold a `verify_cap` for its story. Verify caps are minted only at `request_review` time, for a lineage chosen by loopctl.
- Even if it reads a `verify_cap` from the database via SQL access, the cap's `issued_to_lineage` field does not match its own lineage.
- Even if it attempts to forge a cap, it does not hold the tenant's signing key. The signing key is in a Fly secret the application can read but cannot export in a way the adversary can exfiltrate to a third-party signer.
- Even if it compromises the signing key through some other means, the cap's mint is recorded in the audit chain — and the adversary cannot rewrite the audit chain without the agent-witness protocol detecting the divergence.

The bypass requires defeating three orthogonal layers simultaneously. Each layer can be compromised in isolation without the system failing open.

## 6. Sub-agent lineage

Loopctl records the dispatch tree for every agent action. Two callers are treated as "the same actor" when their lineage shares a common prefix.

### 6.1 Dispatch table

```sql
CREATE TABLE dispatches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants(id),
  parent_dispatch_id uuid REFERENCES dispatches(id),
  api_key_id uuid NOT NULL REFERENCES api_keys(id),
  agent_id uuid NOT NULL REFERENCES agents(id),
  story_id uuid REFERENCES stories(id),
  role text NOT NULL,
  lineage_path uuid[] NOT NULL,  -- array of ancestor dispatch IDs including self
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz
);

CREATE INDEX dispatches_tenant_lineage_idx
  ON dispatches USING gin (lineage_path);
```

When a new dispatch is requested:

```
POST /api/v1/dispatches
{
  "parent_dispatch_id": "<caller's current dispatch>",
  "role": "implementer",
  "story_id": "<story>",
  "expires_in_seconds": 3600
}
```

The response returns an **ephemeral api_key** scoped to this dispatch:

```json
{
  "dispatch": {
    "id": "...",
    "lineage_path": ["root_dispatch", "orchestrator_dispatch", "new_dispatch"],
    "expires_at": "..."
  },
  "api_key": {
    "raw_key": "lc_ephemeral_...",
    "role": "agent",
    "agent_id": "..."
  },
  "next_action": {
    "description": "Use this api_key for all subsequent calls related to this dispatch. It will expire in 1 hour.",
    "learn_more": "https://loopctl.com/wiki/dispatch-lineage"
  }
}
```

### 6.2 Lineage-based identity comparison

The chain-of-custody check in `validate_not_self_*` functions no longer compares bare agent_ids. Instead:

```elixir
defp lineage_shares_prefix?(lineage_a, lineage_b) do
  prefix_length = min(length(lineage_a), length(lineage_b))
  Enum.take(lineage_a, prefix_length) == Enum.take(lineage_b, prefix_length)
end

defp validate_not_self_verify(story, verifier_lineage) do
  case Loopctl.Dispatches.get_implementer_lineage(story.id) do
    {:ok, implementer_lineage} ->
      if lineage_shares_prefix?(implementer_lineage, verifier_lineage) do
        {:error, :self_verify_blocked}
      else
        :ok
      end

    {:error, :not_found} ->
      {:error, :self_verify_blocked}
  end
end
```

Two lineages share a prefix if they descend from the same ancestor dispatch — which means a common orchestrator dispatched both. The verifier must come from a lineage with no common ancestor with the implementer.

### 6.3 Rotating verifier selection

At `request_review` time, loopctl selects a verifier lineage. The selection algorithm:

1. Find all currently-active dispatches in the tenant that can verify stories (role permission + capacity)
2. Exclude any lineage sharing a prefix with the implementer's lineage
3. Randomly select one from the remaining candidates
4. If no candidates exist, halt the story in `reported_done` pending a new independent dispatch

The orchestrator cannot pre-select the verifier because loopctl performs the selection, uses a cryptographically-seeded RNG (from the tenant's signing key + story_id), and records the selection in the audit chain. An adversary that tries to manipulate the selection would have to influence loopctl's randomness source.

### 6.4 Why ephemeral keys matter

Long-lived environment variables like `LOOPCTL_AGENT_KEY` create a shared credential that every sub-agent inherits. The moment one sub-agent is dispatched, the caller can reason about which keys exist and plan bypasses accordingly.

Ephemeral dispatch-scoped keys eliminate this pattern:

- A key exists only for the lifetime of a specific dispatch
- A key carries its lineage as a field, so loopctl can reason about "who am I talking to?" from the key alone
- A key that leaks is bounded in scope and duration — an attacker with a stolen implementer key cannot use it to verify anything

The operator does not manage ephemeral keys manually; the orchestrator skill fetches them from loopctl at dispatch time and the sub-agent receives them in its startup environment.

## 7. Independent re-execution

Loopctl verifies stories by independently running the work, not by trusting the implementer's report.

### 7.1 AC evidence bindings

Every acceptance criterion in a story must carry a `verification_criterion` of one of the following types:

- `test:<path>::<test_name>` — a specific test must exist in the post-commit tree and pass. Format: `test:test/loopctl/example_test.exs::"handles empty input"`
- `code:<path>:<line_range>:<pattern>` — a specific code region must match a regex or AST pattern. Format: `code:lib/loopctl/example.ex:120-140:"def handle_empty"`
- `route:<METHOD> <path>` — a Phoenix route must exist. Format: `route:POST /api/v1/example`
- `migration:<table>:<column>:<type>` — a migration must add a specific column. Format: `migration:examples:new_field:string`
- `manual:<description>` — requires human review. Batched and surfaced to the operator on a dashboard.

Stories submitted without bindings on every AC are rejected at `contract_story` time. Legacy stories migrated from Epic 21/22/25 default to `manual:legacy` and require explicit operator approval to verify.

### 7.2 Verification flow

When a story reaches `reported_done` and a verifier is selected, loopctl creates a `verification_run` record and dispatches it to the verification engine:

1. **Fetch the commit**: loopctl uses the project's git remote URL (recorded at project creation) to clone and checkout the reported SHA. The SHA is content-addressed — loopctl verifies it exists in the remote, records its content hash, and stores the hash in the verification run.

2. **Prefer existing CI results**: if the project has a CI provider (GitHub Actions, GitLab CI, CircleCI) configured, loopctl queries the provider's API for the check status on the reported commit. Green CI on the implementer's own branch is acceptable for low-stakes stories because CI runs in GitHub's infrastructure, not the implementer's process.

3. **Fall back to a verification runner**: for projects without CI, or for stories flagged as high-stakes, loopctl spawns an ephemeral verification worker. The worker runs the project's test suite in a clean container.

4. **Per-AC verification**: for each AC, loopctl runs the `verification_criterion` check against the fetched tree:
   - `test:...` criteria run the named test and record pass/fail
   - `code:...` criteria grep/AST-match the named file region against the pattern
   - `route:...` criteria compile-check the router and verify the route exists
   - `migration:...` criteria parse the migration files and check the column exists
   - `manual:...` criteria are queued for human review

5. **Record results**: the verification run stores per-AC pass/fail + overall pass/fail. On full pass, loopctl issues the verifier the `verify_cap` for that story. On failure, the story is rejected and loopctl records the specific ACs that failed.

### 7.3 Why this closes the lazy-bastard gap

An implementer cannot lie about test results because a separate process re-runs them. An implementer cannot claim AC-1 is done if the `test:...` binding does not pass. An implementer cannot skip a test because the verification run detects missing test cases (via FAIL_TO_PASS and PASS_TO_PASS dual sets — contemporary benchmarking practice). An implementer cannot submit a fake commit SHA because loopctl content-addresses the commit from the public remote.

The `sys.exit(0)` attack documented in contemporary alignment research is defeated because the verification runner checks which tests actually ran, not just the runner's exit code.

## 8. Self-discovery layer

Every agent encountering loopctl for the first time can follow a chain of discoverable links from a single URL to the point where it can successfully participate in the chain of custody.

### 8.1 The .well-known endpoint

```
GET https://loopctl.com/.well-known/loopctl
```

Returns a JSON document describing the loopctl deployment:

```json
{
  "spec_version": "2",
  "mcp_server": {
    "name": "loopctl-mcp-server",
    "npm_version": "2.0.0",
    "repository": "https://github.com/mkreyman/loopctl/tree/master/mcp-server"
  },
  "audit_signing_key_url": "https://loopctl.com/api/v1/tenants/{tenant_id}/audit_public_key",
  "capability_scheme": "https://loopctl.com/wiki/capability-tokens",
  "chain_of_custody_spec": "https://loopctl.com/wiki/chain-of-custody",
  "discovery_bootstrap": "https://loopctl.com/wiki/agent-bootstrap",
  "required_agent_pattern": "https://loopctl.com/wiki/agent-pattern",
  "system_articles_endpoint": "https://loopctl.com/api/v1/articles?scope=system",
  "contact": "operator@example.com"
}
```

The JSON is served by the Phoenix application at a stable URL. Agents cache the document for the session duration.

### 8.2 HATEOAS responses

Every successful custody response includes a `next_actions` field:

```json
{
  "story": { ... },
  "capability": { ... },
  "next_actions": [
    {
      "action": "verify_story",
      "method": "POST",
      "path": "/api/v1/stories/{id}/verify",
      "required_body": {
        "capability": "<the cap from this response>",
        "findings": "<your review findings>"
      },
      "preconditions": ["run verification_criteria on each AC", "fetch the commit and check its content hash"],
      "learn_more": "https://loopctl.com/wiki/verify-story"
    }
  ]
}
```

Every error response includes a `remediation` field:

```json
{
  "error": {
    "code": "self_verify_blocked",
    "message": "Cannot verify your own implementation. The verifier lineage shares a prefix with the implementer lineage.",
    "your_lineage": ["dispatch_abc", "dispatch_def"],
    "implementer_lineage": ["dispatch_abc", "dispatch_xyz"],
    "common_prefix": ["dispatch_abc"],
    "remediation": {
      "description": "A different lineage must verify this story. Request a new dispatch from an ancestor that does not share the implementer's prefix.",
      "next_action": "Call POST /api/v1/dispatches with a parent_dispatch_id outside the implementer's lineage.",
      "learn_more": "https://loopctl.com/wiki/lineage-separation"
    }
  }
}
```

The verbose error responses mean an agent does not need to read the source code to recover from a failure. It reads the remediation, calls the suggested next action, and proceeds.

### 8.3 System-scoped articles

The knowledge wiki gains a `scope` field on articles with values `:system` or `:tenant`. System-scoped articles have `tenant_id = NULL` and are visible to every agent in every tenant.

Loopctl ships with a seed set of system articles covering:

- `chain-of-custody` — the overall protocol
- `capability-tokens` — the token scheme, issuance, verification
- `dispatch-lineage` — how to mint ephemeral dispatches and what lineage paths mean
- `self-verify-blocked` — what to do when you hit this error
- `acceptance-criteria-bindings` — how to structure ACs so they're machine-verifiable
- `verify-story` — the verifier's workflow from ready-to-verify to committed
- `lazy-bastard-detection` — what behaviors trigger re-review flags and how to avoid them
- `agent-bootstrap` — the first-contact protocol for a new agent
- `agent-pattern` — the expected agent lifecycle (discover → dispatch → claim → work → report → wait)
- `break-glass` — how to request a human operator to override a halt
- `witness-protocol` — how agents contribute to tamper-evident audit

All articles have stable slugs. URLs are of the form `https://loopctl.com/wiki/<slug>`. The articles are served as Markdown rendered to HTML for humans, and via the existing `GET /api/v1/articles/{id}` API for agents. Agents find them via `knowledge_search` without needing to know the URL — system-scoped articles are returned in every search.

System articles are writable only by the root (superadmin) key. They ship as seed data in a migration and are updated across loopctl deployments via normal migrations.

### 8.4 Bootstrap flow

A brand-new agent pointed at `https://loopctl.com` with a valid API key:

1. Fetches `.well-known/loopctl`
2. Reads the MCP server version and the discovery bootstrap URL
3. Follows the bootstrap article, which instructs it to:
   - List projects it has access to
   - For each project, read the project's system-scoped onboarding article
   - Register a dispatch via `POST /api/v1/dispatches` to receive an ephemeral key
   - Subscribe to audit events for its tenant
   - Query `list_ready_stories` and proceed with normal agent operations

At no point does the agent need prior knowledge of loopctl's internals. Every step is linked from the previous step. An agent with only a shell, a curl, and the API key can reach productive work within a few requests.

## 9. Tenant signup ceremony

Tenant creation is a human-gated ceremony that establishes the root of trust for the tenant's entire lifetime.

### 9.1 Flow

1. Operator visits `https://loopctl.com/signup` (a LiveView in the existing landing page application)
2. Operator provides tenant metadata (name, slug, contact email)
3. Operator enrolls a WebAuthn authenticator (FIDO2 hardware key, platform authenticator, etc)
4. Loopctl verifies the enrollment signature and stores the public portion in `tenants.root_authenticators` (one-to-many to support backup authenticators)
5. Loopctl generates the tenant's audit-signing keypair (ed25519). The private half is stored in a Fly.io secret scoped to the tenant (or, for operators who require stricter isolation, a future phase will move this to an HSM or separate process). The public half is stored on the tenant record and served at the public key endpoint.
6. Loopctl writes the genesis entry to the tenant's audit chain:
   ```json
   {
     "action": "tenant_created",
     "actor_lineage": ["human_webauthn_fingerprint"],
     "entity_type": "tenant",
     "entity_id": "<tenant_id>",
     "payload": {
       "authenticator_public_key": "...",
       "audit_signing_public_key": "...",
       "signup_signature": "<WebAuthn assertion signature>"
     }
   }
   ```
7. Loopctl mints the operator's root api_key — role `user`, agent_id null (humans don't need agent records), bound to the tenant. The operator uses this key for administrative tasks via the CLI and MCP server.
8. The operator is redirected to a "your tenant is ready" page with next-step instructions: how to register agents, how to create a project, how to dispatch an orchestrator session.

### 9.2 Destructive operations

Any endpoint that modifies the root trust requires a fresh WebAuthn assertion:

- `POST /tenants/:id/authenticators` — enroll an additional authenticator
- `DELETE /tenants/:id/authenticators/:id` — revoke an authenticator
- `POST /tenants/:id/rotate-audit-key` — rotate the audit signing key
- `POST /tenants/:id/override` — break-glass override of a halted custody operation
- `DELETE /projects/:id` — delete a project
- `POST /tenants/:id/budgets` — raise a token budget

The operator's CLI prompts for the hardware touch at the moment of the operation. Agents cannot perform these operations — attempting to do so returns a 401 with remediation text pointing at the break-glass workflow.

### 9.3 Recovery

Loss of all enrolled authenticators is a fatal event for the tenant. Recovery requires contacting the loopctl operator (the root of the root of trust — the human running `loopctl.com` itself) and re-enrolling via an out-of-band channel. This is intentional: recovery is rare, loud, and hard. The alternative — soft recovery via email or password — would create a back door that agents could eventually find and exploit.

## 10. Phase plan

Seven phases, numbered to reflect dependency order. Each phase is independently shippable and strictly safer than the phase before.

### Phase 0 — Tenant signup ceremony + system articles foundation

**Goal**: establish the human root of trust and the self-discovery surface.

- `POST /signup` LiveView with WebAuthn enrollment
- `tenants.root_authenticators` table
- `tenants.audit_signing_public_key` field
- Fly.io secret storage for audit signing private keys, scoped per tenant
- `articles.scope` field with `:system` and `:tenant` values
- Seed migration installing the system articles listed in §8.3
- `GET /.well-known/loopctl` endpoint
- `GET /api/v1/tenants/:id/audit_public_key` endpoint
- `GET /wiki/:slug` LiveView for rendering system articles as HTML
- `POST /api/v1/articles` updated to honor scope, with scope `:system` requiring the root operator key

**Shippable**: yes. Existing tenants remain on spec_version 1 and operate unchanged until upgraded.

### Phase 1 — Audit chain + nil-fall-through fixes

**Goal**: close the nil-permissive bypasses and establish the tamper-evident audit log.

- `audit_chain` table with hash-chained entries
- Triggers enforcing append-only semantics and hash chain validity
- `audit_signed_tree_heads` table and the STH computation job (Oban)
- Refactor every `validate_not_self_*` function in `Loopctl.Progress` to reject nil identity as `{:error, :self_*_blocked}`
- FK constraint on `api_keys.agent_id` (nullable only for `role = :user`)
- Partial unique index on `api_keys (tenant_id, agent_id) WHERE revoked_at IS NULL AND role != 'user'`
- Immutability trigger on `api_keys.role`
- Discovery migration that flags pre-existing cross-role bindings and nil-agent keys for operator review (does not auto-revoke — operator triage)
- Error responses for the new rejection paths include `remediation` and `learn_more` fields pointing at the system articles

**Shippable**: yes. Legacy API callers see new 403s for previously-permissive operations, with clear remediation.

### Phase 2 — Dispatch lineage + ephemeral keys

**Goal**: replace the shared long-lived key pattern with dispatch-scoped ephemeral keys.

- `dispatches` table with lineage_path
- `POST /api/v1/dispatches` endpoint with parent_dispatch_id, story_id, role, expires_in_seconds
- Ephemeral api_key minting at dispatch time (new api_key with expires_at set)
- Lineage-based `validate_not_self_*` replacement
- Rotating verifier selection at `request_review` time
- Deprecation of `LOOPCTL_AGENT_KEY` long-lived env var pattern with loud warnings
- Orchestrator skill updated to use dispatches instead of the env var
- Loopctl MCP server updated to present dispatch flow in tool descriptions

**Shippable**: yes. The dispatch endpoint ships in shadow mode (legacy long-lived keys still resolve to an implicit root dispatch, shadow events log every resolution), then the flag flips to strict — from that moment the long-lived key path is removed entirely and only ephemeral dispatches are accepted.

### Phase 3 — Capability tokens

**Goal**: structural enforcement that custody operations require a matching cap.

- `capability_tokens` table (for audit / replay protection)
- Signing helper using the tenant's audit signing key (same key as STHs)
- Cap minting at `claim_story`, `start_story`, `request_review`
- Cap verification at `report_story`, `review_complete`, `verify_story`
- Responses return caps with `next_actions` scaffolding
- Error responses for cap failures include the remediation path
- System articles updated with the cap scheme

**Shippable**: yes. Cap verification ships in shadow mode for a 7-day observation window, then flips to strict via the enforcement flag. After the flip, the missing-capability path is the only behavior — no permissive fallback remains.

### Phase 4 — Independent re-execution

**Goal**: SWE-bench-style verification of work.

- `story_acceptance_criteria` table (promote from story metadata to first-class)
- `verification_criterion` field on each AC with the five types described in §7.1
- `verification_runs` table
- GitHub Actions integration: query CI status for a commit SHA and use it as verification evidence
- Fallback verification runner on Fly.io (an ephemeral machine that clones, tests, reports)
- Content-addressed commit SHA fetching and storage
- `verify_story` endpoint refactored to enqueue a verification run instead of transitioning directly
- Operator dashboard for `manual:` criteria requiring human review

**Shippable**: yes. The one-time backfill converts existing stories' jsonb-blob ACs into `story_acceptance_criteria` rows with `{type: "manual", description: "legacy"}` bindings. Stories contracted after the phase ship must declare real bindings at contract time — the check ships in shadow mode first, then strict after a 7-day observation window.

### Phase 5 — Witness protocol

**Goal**: cross-agent tamper evidence via PubSub-broadcast STHs.

- PubSub topic per tenant for audit chain events
- Agent-side STH caching (implemented in the MCP server library)
- `X-Loopctl-Last-Known-STH` request header validation
- Divergence detection and halt
- System article explaining how agents contribute to tamper evidence

**Shippable**: yes. Header validation ships in shadow mode for 7 days (missing header is logged but allowed), then the enforcement flag flips to strict — from that moment the header is required on every custody request.

### Phase 6 — Behavioral telemetry

**Goal**: lazy-bastard detection via soft signals.

- Token usage infrastructure (from existing Epic 21) extended with tool_call_count, cot_length_tokens, tests_run_count
- Lazy-bastard score computed at story transitions
- Stories above the threshold flagged for re-review by a separately-dispatched reviewer
- CoT sanity monitor (non-blocking, non-trained) running on review records
- Alert dashboard for anomalies

**Shippable**: yes. Telemetry is non-blocking by design — scores route stories for stricter re-review, they never reject custody operations directly.

## 11. Migration notes — hard cutover strategy

Loopctl.com is a single-tenant production deployment. The cutover from v1 to v2 is global and one-shot per invariant: every new check ships first in shadow mode (logs would-have-rejected events without blocking), then flips to strict via a single config change after the operator reviews the shadow-mode dashboard and confirms no false positives.

No deprecation windows. No legacy compatibility shims. No `tenants.protocol_version` column. No per-story version gating. The `Loopctl.Enforcement.check/3` call site is the uniform enforcement path — the config flag controls whether it rejects or allows, but the call site is the same in both modes. At no point does the codebase contain a parallel "v1 path" and "v2 path" — there is one path, with one flag.

### Cutover sequence per phase

1. **Ship phase code with enforcement flags set to `:shadow`**. New checks log to `enforcement_shadow_events` but do not reject.
2. **Observe for 7 days** via the `/admin/shadow-events` dashboard. Review every would-reject event. If any are false positives (a check rejecting a legitimate request the operator did not intend to block), fix the check and restart the observation window.
3. **Flip the flag to `:strict`** via `PATCH /api/v1/admin/enforcement/:invariant`. The flip is immediate and global. From that moment, the check rejects matching requests. The flip is audit-logged.
4. **No rollback to shadow** is expected in normal operation, but the flag can be flipped back via the same endpoint if a production issue surfaces. Flipping back does not require a deploy.

### Pre-existing data handling

Every invariant that could be violated by pre-existing data gets a discovery pass before its strict cutover:

- **Cross-role api_key bindings**: discovered at Phase 1 ship, surfaced in `/admin/violators`. Operator must revoke conflicting keys before flipping the `cross_role_binding` flag to strict. Migration checks the violator count and refuses to set strict if any unresolved.
- **Nil-agent non-user keys**: same pattern — discovered, surfaced, operator resolves, then flag flips.
- **Stories without `verification_criterion`**: backfilled with `manual:legacy` bindings. Operator can re-annotate them with real bindings via the admin dashboard before the `missing_verification_criterion_on_contract` flag flips.
- **Audit chain gap before Phase 1**: the genesis entry is written at the moment Phase 1 ships. Historical data from the pre-v2 `audit_log` table remains readable but is NOT part of the hash-chained history. A followup migration after Phase 1 stabilizes can optionally copy historical entries into an immutable archive table if needed for compliance.

### Observation-to-strict windows

The 7-day shadow window per phase is the default; the operator can extend it for phases where the observation reveals more edge cases than expected. There is no fixed calendar deadline for each cutover — the flip happens when the shadow data looks clean, not on a clock.

### After all flags are strict

Once every enforcement flag has been in `:strict` mode stably for 30 days post-Phase-6, a final cleanup story can remove the config flag machinery entirely and inline the strict behavior directly into the call sites. That cleanup is tracked as a future story after Epic 26 wraps — it is NOT part of any Phase 0-6 story to avoid coupling the feature work to the cleanup.

## 12. Open questions

Deferred to the phase that makes them relevant. Not blocking on this design.

- How to scale the witness protocol beyond ~50 agents per tenant (Phase 5 followup)
- Whether to move the audit-signing private key to a hardware HSM or remote KMS (post-Phase 0 hardening)
- Whether to support multi-region loopctl deployments (the audit chain is currently single-region)
- How to handle key rotation for the audit-signing key without invalidating historical STHs (rotation ceremony design, Phase 5 or later)
- Whether `manual:` verification criteria can be batched across stories to reduce operator burden (Phase 4 ergonomics)
- Whether to expose a public dashboard of aggregate audit statistics for transparency (post-Phase 6)

These questions are tracked in the story metadata for the relevant phases as `future_work` items.
