# Fail-closed no-egress guard (US-41.4)

A privacy tier that depends on the operator configuring three endpoints
correctly is not a guarantee. This is the enforcement that turns it into one an
agent can verify.

## What is actually guaranteed

> Fail-closed `local_only` enforcement applies to **every outbound HTTP call made
> by loopctl application code** on the MODEL-PROVIDER path.

That wording is deliberate and narrow. Three things it does **not** claim:

1. **Webhook delivery is not covered yet.** `Loopctl.Webhooks.ReqDelivery`
   bypasses this guard entirely (it has its own SSRF pin, but no locality
   decision). Bringing it under the guard is US-41.5. Until then, neither the
   docs nor the posture report claim total egress control.
2. **HTTP performed inside a dependency is invisible.** The static chokepoint
   check is an AST scan of this repository; a library that opens its own socket
   is outside it.
3. **The separate `mcp-server/` codebase is not scanned.** It is a different
   process on the agent's machine.

## The pieces

| Module | Role |
|---|---|
| `Loopctl.Egress.Policy` | The ONE egress policy. Composes the SSRF denylist with the locality decision. A second, divergent URL policy anywhere in `lib/` is a review failure. |
| `Loopctl.Provider` | The SINGLE MANDATORY CHOKEPOINT. Every model-provider call routes through `post/3`. |
| `Loopctl.Egress.ChokepointScan` | Static AST scan; wired into `mix credo --strict` via `.credo/checks/direct_outbound_http.ex`. |
| `Loopctl.Egress.PinCache` | Named, supervised owner of the resolved+classified pins. Jittered pre-expiry refresh. |
| `Loopctl.Egress.Allowlist` | The OPERATOR deployment allowlist. Read-only at every role. |
| `Loopctl.Egress` | Context: markings, declarations, aggregated blocked decisions, posture. |

## Why the guard is separate from `Provider.Admission`

`Admission` is a burst shedder and is **fail-OPEN by design**: any limiter fault
(raise, `{:error, _}`, exit, throw) logs and ALLOWS the call, because a
monitoring fault must never block all provider traffic.

An egress guard needs the opposite semantics. Fusing the two would mean a Hammer
or `SystemConfig` hiccup silently degrades the privacy guarantee to "allow" —
turning a guarantee into a hope. They therefore stay separate `with` clauses, and
a test asserts that with the admission backend fully unavailable (fail-open
triggered) a `local_only` scope on a non-local endpoint is still BLOCKED.

## Why a chokepoint and not a convention

`Admission` itself was added site-by-site and is consequently MISSED at
`webhooks/req_delivery.ex`, `verification/github_actions.ex` and
`secrets/fly_adapter.ex`. A guarantee enforced by per-call-site convention
regresses the first time someone adds a `Req` call. So:

- every model-provider call goes through `Loopctl.Provider.post/3`;
- the static check fails CI on any direct outbound HTTP in the scanned paths
  outside an explicit, JUSTIFIED module allowlist;
- detected entry points: `Req.post/request/get/put/patch/delete/new`,
  `Req.Request.run` / `run_request`, `Finch.request` / `Finch.build`,
  `Mint.HTTP.*`, `:httpc.request`, `:gen_tcp.connect`, `:ssl.connect`;
- the scanned path list is CONFIGURABLE (`config :loopctl, :egress_scan_paths`,
  default `["lib"]`) so the negative-control fixture under
  `test/support/egress_fixtures` is genuinely scanned — a fixture outside the
  scanned paths would make the control a no-op.

## Locality: two concepts the epic must not conflate

### (a) Network locality — the operator plane

Loopback and private-range hosts are BLOCKED by `Loopctl.Net.UrlGuard`
unconditionally (GHSA-jh42-wf7g-f5rg). The **only** thing that can carve a
host/CIDR out of that denylist is the operator deployment allowlist
(`LOCAL_ENDPOINT_ALLOWLIST`). It is deployment-scoped, lives outside RLS, and is
READ-ONLY at every role including `:user` — an agent must never widen its own
allowlist, and a `:user` key belongs to a tenant, not the operator. A test
asserts no API path mutates it.

### (b) Tenant ownership — the tenant plane

On the HOSTED instance the server's loopback and private ranges are the
OPERATOR's network, so a hosted tenant's own Ollama/TEI box is reachable only via
a PUBLIC hostname. Tenant-declared trusted endpoints exist for exactly that case.

**A declaration is an unverified tenant attestation, not a verified control.**
loopctl does not prove the declaring tenant owns the host. Everywhere it
surfaces, it is labelled verbatim:

> tenant-declared (unverified attestation), not network-local

It must never be presented as network-local. Three constraints are enforced:

1. **Public addresses only** — rejected at write time and re-checked at pin time
   unless every resolved address still passes UrlGuard's full denylist. Loopback,
   `0/8`, `10/8`, `127/8`, `169.254/16`, `172.16-31`, `192.168/16`, `100.64/10`
   and `fdaa::/16` can never be declared, literally or via a public hostname that
   resolves there.
2. **Purpose-scoped** — `inference` and/or `webhook`. A host declared for an
   Ollama box does NOT authorize webhook POSTs of tenant content to it.
3. **Vendor hosts excluded** — `api.openai.com`, `api.anthropic.com`. This is a
   guardrail against the obvious mistake, NOT an integrity control (trivially
   defeated by a proxy or a CNAME); constraints 1 and 2 carry the security
   weight.

A declaration carves NOTHING out of the denylist. It only changes the locality
VERDICT for hosts that already pass it.

## Roles are asymmetric, deliberately

| operation | role |
|---|---|
| `egress_posture` (read) | `:agent` |
| `egress_repin` | `:agent` |
| ENABLE `local_only` | `:orchestrator` |
| CLEAR `local_only` | `:user` |
| declare / revoke trusted endpoint | `:user` |
| mutate the deployment allowlist | **no role — there is no such path** |

Clearing `local_only` at anything below `:user` would let an agent re-open egress
one tool call before a harvest while US-41.7's witnessed claim faithfully
attested the weakened posture.

Because the enabling role cannot undo the transition, ENABLE carries a
**mandatory pre-flight**: the scope's currently-resolved endpoints are classified
first, and the operation is REFUSED (`409 would_block_endpoints`, naming each
offending endpoint) unless the caller passes an explicit `acknowledge` flag, in
which case it completes and REPORTS the resulting blocked posture. Every enable
also emits a high-priority audit event and the alertable
`[:loopctl, :egress, :local_only_enabled]` telemetry event.

## Scope resolution

Effective marking = MOST RESTRICTIVE of tenant and project (`project OR tenant`).
A project can NEVER relax a tenant marking. A project-less row — `articles`
with a nil `project_id`, any memory — inherits the TENANT marking.

**Endpoint resolution is TENANT-SCOPED ONLY.** There is no `project_llm_settings`
table and no project endpoint override. Consequence, stated rather than hidden: a
`local_only` PROJECT inside a tenant whose endpoints are vendor defaults is
`egress_blocked`; the remediation is to configure a satisfying endpoint AT TENANT
level (role `:user`) or clear the project marking.

### Threading the scope

The scope has to REACH the guard, or the resolution above is decorative. The
first argument of the provider-facing client APIs — `EmbeddingBehaviour`'s
`generate_embedding/2` / `generate_embeddings/2`, and `Llm.Anthropic.message/5` /
`call/7` — is therefore the `Loopctl.Egress.Scope`, with a bare `tenant_id`
accepted as shorthand for the tenant-wide scope (`Scope.coerce/1`). Callers that
know a project supply it:

- `Knowledge.generate_embedding/3` / `generate_embeddings/3` take `:scope` (or
  the shorthand `:project_id`) in `opts` and thread it to the client.
- Combined search carries its existing `:project_id` filter into the scope.
- `Memory` threads `Memory.Scope.project_id` (memories often have none — the
  tenant-wide scope is then correct, not a fallback).
- `ArticleEmbeddingWorker` uses the ARTICLE's `project_id`; the batch worker
  GROUPS a chunk by `project_id` first, so every provider array call carries
  exactly ONE scope rather than forcing one marking onto mixed articles.

Key and endpoint resolution stay tenant-scoped throughout — the project half
narrows only the MARKING.

## Failure semantics

| return | meaning |
|---|---|
| `{:ok, :unpinned}` | scope is not `local_only` — proceed exactly as before |
| `{:ok, pinned}` | allowed; connect via `UrlGuard.pinned_request_opts/2` |
| `{:error, :egress_blocked}` | PERMANENT configuration refusal, before any request |
| `{:error, :pin_stale}` | the pinned address set changed — re-pin, no `:user` write |

- **Oban**: `:egress_blocked` (and `:pin_stale`) map to `{:cancel, reason}` in
  every worker that can receive them — never `{:error, _}` (Oban retries it,
  burning `max_attempts` per item and repopulating the queue on every subsequent
  write) and never `{:snooze, _}`.
- **Circuit breaker**: `Knowledge.breaker_countable?/1` returns `false` for both.
  A permanent local configuration refusal must never open the per-tenant breaker
  nor feed the fleet-wide `[:loopctl, :llm, :provider_error]` storm signal. The
  replacement operator signal is `[:loopctl, :egress, :blocked]`, registered as
  the `loopctl.egress.blocked.count` Prometheus counter in
  `Loopctl.Telemetry.ScaleMetrics` (tagged by the bounded verdict `reason` plus a
  cap-gated `tenant_id`; the tenant-supplied endpoint host is deliberately NOT a
  label — it lives on the aggregated decision row and in `egress_posture`).
- **Interactive search**: degrades like circuit-open — keyword fallback, HTTP
  200, never a 500 — with `meta.fallback_reason`, `meta.offending_endpoint`,
  `meta.degraded` and the reserved `meta.excluded_tiers` (present, empty here;
  populated by US-41.6).
- **Audit write amplification is bounded**: blocked decisions are deduplicated
  per `(scope, endpoint, reason, 60s window)` with an `occurrence_count`. The
  exact per-call rate lives in telemetry, not in rows.

## Hot path

One cheap classification per provider call, no network or DB round-trip. The host
is resolved and classified into a PINNED IP set cached under
`(tenant_id, scope, host)` — never host alone, or tenant A's declaration would
make a host read as local for tenant B.

Invalidation is explicit and immediate on any mutation of the tenant's
declarations, markings or endpoint settings — a revoked declaration does not keep
working for the rest of the TTL.

`Loopctl.Egress.PinCache` is a NAMED SUPERVISED process with jittered pre-expiry
refresh and a distinct `:revalidating` state. Without it, TTL expiry would be a
scheduled fleet-wide self-inflicted outage: every `local_only` tenant hard-refusing
at once. A privacy control whose steady state is an outage gets disabled in
production, which is how the guarantee actually dies.

Fail-closed is SCOPED: a stale or missing entry refuses only for `local_only`
scopes. A scope that is not `local_only` re-resolves normally and pins per
request, preserving the default-off promise for every existing tenant on vendor
endpoints.
