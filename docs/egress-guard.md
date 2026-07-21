# Fail-closed no-egress guard (US-41.4, US-41.5)

A privacy tier that depends on the operator configuring three endpoints
correctly is not a guarantee. This is the enforcement that turns it into one an
agent can verify.

## What is actually guaranteed

> Fail-closed `local_only` enforcement applies to **every outbound HTTP call made
> by loopctl application code** on **every content-carrying path**: model-provider
> calls, the ingestion fetch, and webhook delivery.

US-41.5 closed the webhook gap; the wording is still deliberate and narrow. Two
things it does **not** claim:

1. **HTTP performed inside a dependency is invisible.** The static chokepoint
   check is an AST scan of this repository; a library that opens its own socket
   is outside it.
2. **The separate `mcp-server/` codebase is not scanned.** It is a different
   process on the agent's machine.

## Outbound-path triage (US-41.5, AC-41.5.6)

Every outbound path in `lib/` is enumerated below. The list is not prose: the
`@allowed` map in `Loopctl.Egress.ChokepointScan` is the machine-checked
inventory (`mix credo --strict`), and `Loopctl.Egress.ChokepointScanTest`
asserts that **every allowlist entry has a row in this table** — a call site the
static check exempts with no triage entry fails the build.

The rule applied: **anything carrying tenant content is brought UNDER the guard.**
Nothing content-carrying is documented away.

| Call site | Carries tenant content? | Disposition |
|---|---|---|
| `Loopctl.Provider` (`lib/loopctl/provider.ex`) | yes | **IS the model-provider chokepoint wrapper.** Consults `Egress.Policy` on every call. Allowlisted because it is the wrapper, not a bypass. |
| `Loopctl.Webhooks.ReqDelivery` (`lib/loopctl/webhooks/req_delivery.ex`) | **yes — the payload is tenant state** | **IS the webhook chokepoint wrapper (US-41.5).** Consults the same `Egress.Policy.check/4` with purpose `:webhook` and `tenant_supplied: true`, then pins (`pinned_request_opts` + `redirect: false`). Allowlisted for the same reason `Provider` is. |
| `Loopctl.Workers.ContentIngestionWorker` (`resolve_content/3`) | no — INBOUND content; sends no tenant data | **Under the guard, not exempt.** Not in the allowlist at all: it pins with `UrlGuard.pin/1` and then issues the fetch through `Provider.get/3` (purpose `:ingest`, `pinned_by_caller: true`), so it consults the one policy like everything else. |
| `Loopctl.Workers.ScaleAlertDeliveryWorker` | no — operator-plane alerting (metric name, value, threshold) | Delivers through `ReqDelivery` with **`scope: nil`**. The URL is operator configuration, not tenant data, and there is no tenant marking to apply; the SSRF denylist still applies (the same `UrlGuard` primitive the policy composes). |
| `Loopctl.Verification.GitHubActions` (`lib/loopctl/verification/github_actions.ex`) | no — reads commit/check-run metadata | Operator-plane, fixed vendor host, never reachable from a tenant-supplied URL. Allowlisted. |
| `Loopctl.Secrets.FlyAdapter` (`lib/loopctl/secrets/fly_adapter.ex`) | no — operator secret management | Operator-plane against the Fly GraphQL API. Fixed host, never tenant-supplied. Allowlisted. |
| `Loopctl.CLI.Client` (`lib/loopctl/cli/client.ex`) | no — targets the CONFIGURED loopctl server | The loopctl CLI's own client: runs on the operator's machine, outside the server request path, and is not a tenant-content egress path to a third party. **Exempted by an explicit allowlist entry** rather than being silently unmatched by the static check. |

## Webhook delivery under the guard (US-41.5)

`ReqDelivery.deliver/4` takes the `Loopctl.Egress.Scope` the delivery is made on
behalf of — `Scope.new(webhook.tenant_id, webhook.project_id)`, so a project-less
subscription follows the TENANT marking (most-restrictive-wins, AC-41.4.2). The
old unconditional `UrlGuard.pin/1` was REPLACED by the policy call, not wrapped
around it: there is exactly one URL policy.

Consequences worth stating:

- A destination the OPERATOR allowlisted (or that the tenant declared **for the
  `webhook` purpose**) is now **deliverable**. It was not before — the bare
  `UrlGuard.pin/1` refused every loopback/private destination for every tenant.
- A host declared for an Ollama **inference** box does **not** authorize POSTing
  tenant content to it. Purpose scoping is re-derived on every read
  (`Policy.resolve_verdict/2`).
- A tenant declaration still carves **nothing** out of the SSRF denylist. Only
  the operator deployment allowlist can reach a private range
  (GHSA-jh42-wf7g-f5rg stays closed for every tenant-writable input).

### `blocked` is a distinct delivery status, not a failure (AC-41.5.2)

`webhook_events.status` gained `:blocked`. It is TERMINAL: the job returns `:ok`,
burns no attempt, schedules no retry, and does **not** increment the webhook's
`consecutive_failures` (the subscriber never failed — loopctl refused to call
it). Blocked deliveries therefore cannot build a retry backlog.

`event.error` carries `"<kind>: <Egress.refusal_reason/1>"`, where
`Loopctl.Egress.block_kind/1` distinguishes the two block causes:

| kind | cause | who can fix it |
|---|---|---|
| `ssrf_denied` | the destination resolves into a private/loopback/CGNAT/link-local/ULA range and is not in the operator deployment allowlist | the OPERATOR (allowlist) — a tenant declaration cannot |
| `locality_denied` | the scope is `local_only` and the destination is not local for the `webhook` purpose | the TENANT (declare the endpoint, or clear the marking — both role `:user`) |

`:pin_stale` / `:egress_unavailable` are neither: they are TRANSIENT
(`block_kind/1` returns `:transient`), so the job SNOOZES without consuming an
attempt and nothing is recorded as blocked.

Stated rather than hidden: because a transient refusal consumes no attempt, it
does NOT advance the worker's app-level 6-attempt ladder — a persistently
unresolvable destination re-checks every `Egress.transient_snooze_seconds/0`
instead of exhausting. That is the US-41.4 contract (`:pin_stale` /
`:egress_unavailable` are NEVER terminal, because nothing re-enqueues a cancelled
job after the re-pin), and it is one snoozed job per event, not a growing
backlog — the terminal-state proof in `WebhookObanTerminalTest` covers the
BLOCKED case, which is the one an unbounded ladder would have amplified.

### Config time beats delivery time (AC-41.5.3)

`Webhooks.create_webhook/3` and `update_webhook/4` reject a non-local destination
on an already-`local_only` scope with a changeset error on `:url` carrying the
remediation. The check runs before the `Ecto.Multi`, so nothing is persisted. It
only fires when the URL is actually being set/changed and the changeset is
otherwise valid — otherwise an unrelated edit (`active: false`) to a
pre-existing, now-incompatible subscription would be un-savable, including the
edit that fixes it.

### Enabling `local_only` with incompatible subscriptions (AC-41.5.4)

**The documented choice is REFUSE-BY-DEFAULT, then report on acknowledgement** —
the same contract US-41.4 already used for provider endpoints, extended rather
than duplicated. `Egress.enable_local_only/3` runs
`blocked_webhook_subscriptions/1` in its pre-flight and returns
`{:error, {:would_block, endpoints}}` with a `kind: :webhook` entry per offending
subscription (carrying `webhook_id`, `endpoint`, `verdict`, `project_id`,
`active`). Passing `acknowledge: true` completes the enable and REPORTS them in
`blocked_endpoints` (and in the marking's `acknowledged_blocked_endpoints`).

Subscriptions are never silently disabled or deleted. Coverage follows the
marking: a tenant-scope marking covers every subscription; a project-scope
marking covers only that project's subscriptions. INACTIVE subscriptions are
included — re-activating one under an unchanged marking would otherwise produce
a silently blocked destination.

### Posture (AC-41.5.5)

`Egress.posture/2` gained `webhook_destinations`: one entry per subscription with
`endpoint`, `host`, `active`, the locality `verdict` label (network-local /
tenant-declared (unverified attestation) / non-local / denylisted),
`verdict_from_deployment_allowlist` (a BOOLEAN at `:agent` — allowlist contents
stay `:user`+) and `blocked_by_local_only`. The destination URL is not a secret
(only the signing secret is Cloak-encrypted), so it is disclosed like the
provider endpoints.

## Tenant isolation: explicit scoping on `AdminRepo`, not RLS

The whole `Loopctl.Egress` context reads and writes through `Loopctl.AdminRepo`
(BYPASSRLS). The RLS policies the migration installs on the three tables are
DEFENCE IN DEPTH for any future `Loopctl.Repo`-routed access; they are not the
runtime enforcement mechanism here, and the isolation tests are labelled
"tenant isolation" rather than "RLS" accordingly.

That is deliberate: `effective_local_only?/1` is on the egress HOT PATH and is
called from Oban workers and background tasks that own no
`Loopctl.Repo.with_tenant/2` transaction, so routing it through RLS would mean
opening a tenant-scoped transaction per provider call. The invariant that replaces
the policy is mechanical and local — every function takes `tenant_id` (or a
`Scope`) first and filters on it, and `tenant_id` is never cast from user input.
`project_id`, which DOES arrive in a request body, is resolved against the
caller's tenant via `Projects.get_project/2` before any write (foreign,
nonexistent and malformed all return the same 404 — no cross-tenant oracle).

## The pieces

| Module | Role |
|---|---|
| `Loopctl.Egress.Policy` | The ONE egress policy. Composes the SSRF denylist with the locality decision. A second, divergent URL policy anywhere in `lib/` is a review failure. |
| `Loopctl.Provider` | The SINGLE MANDATORY CHOKEPOINT. Every model-provider call routes through `post/3`; the content-ingestion FETCH through `get/3` (purpose `:ingest`). |
| `Loopctl.Egress.BlockedBuffer` | ETS debounce for the blocked-decision WRITE — bounds write volume, not just row count. |
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

- every model-provider call goes through `Loopctl.Provider.post/3`, and the
  content-ingestion FETCH through `Loopctl.Provider.get/3` (purpose `:ingest`);
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
`generate_embedding/2` / `generate_embeddings/2`, `Llm.Anthropic.message/5` /
`call/7`, and (US-41.3) `Llm.OpenAiChat.message/5` / `call/8` — is therefore the
`Loopctl.Egress.Scope`, with a bare `tenant_id`
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

### The chat endpoint is now tenant-resolved (US-41.3)

`Egress.resolved_endpoints/1` reads the chat URL from `Llm.chat_base_url/1`, which
returns the tenant's configured `chat_base_url` when `chat_provider` is
`openai_compatible` and `Llm.Anthropic.base_url/0` otherwise. That is the SAME
function the client posts to, so the posture report, the `local_only` enable
pre-flight and the guard can never vet different URLs — re-deriving the URL here
would be the "second, divergent URL policy" AC-41.4.9 calls a review failure.

The US-41.3 config-time probe (`Llm.ChatProbe`) has no URL policy of its own either:
it issues its trivial completion through `Loopctl.Provider.post/3`, so an endpoint
that the guard would refuse is refused at CONFIG time, before it can be saved.

#### `tenant_supplied_url: true` — the SSRF denylist on the DEFAULT path

The default (non-`local_only`) path deliberately never REFUSES: an unpinnable or
denylisted host proceeds unpinned, because the SSRF denylist "is enforced by the
callers that own it" (ingestion pins with `UrlGuard.pin/1` first). That was sound
while every URL on this path was a hardcoded vendor host. `chat_base_url` made one
of them TENANT-WRITABLE, so the chat client and the probe pass
`tenant_supplied_url: true` on `Loopctl.Provider.post/3`, and
`Egress.Policy.check/4` then refuses a `:denylisted` verdict with
`{:error, :egress_blocked, details}` for EVERY tenant, marked or not. Without it a
role `:user` key could point loopctl at `169.254.169.254`, a `.internal` host or any
RFC1918 address and read the outcome back through the probe's distinguishable
refusals — an internal host+port oracle. An OPERATOR-allowlisted private host (the
local-tier deployment shape) still passes as `:network_local`.

The flag ALSO removes the fail-OPEN fallback for that URL. `{:ok, :unpinned}` keeps
Req's default redirect-FOLLOWING and no IP pin, and the default path fell through
to it for ANY non-denylist failure — a classification miss, a DNS answer slower
than the 3s resolve timeout, a classifier raise/exit/throw. For a
TENANT-CONTROLLED host those are attacker-INFLUENCED conditions: make the first
resolution fail and the connect-time resolution can land on `127.0.0.1`,
`169.254.169.254` or a Fly 6PN peer, with redirects followed on top. So a
`tenant_supplied_url` call whose host cannot be classified/pinned is REFUSED with
the TRANSIENT `{:error, :egress_unavailable, details}` (workers snooze; a resolve
blip is not a permanent configuration state). A VENDOR URL is unchanged — it still
degrades to unpinned, so no non-`local_only` tenant on a vendor endpoint acquires a
new failure mode.

Plaintext `http` for a `chat_base_url` is additionally gated at CONFIG time by
`Llm.ChatProbe`: the request carries the `chat_api_key` AND the tenant's full
document text, so `http` is accepted only for a host THIS module classifies
`:network_local`. Everything else must be `https`. The decision is delegated here,
not re-derived at the client (AC-41.4.9).

## Failure semantics

| return | meaning |
|---|---|
| `{:ok, pinned}` | allowed; connect via `UrlGuard.pinned_request_opts/2`. Non-`local_only` scopes are pinned PER REQUEST too — default-off is about the REFUSAL, not the pin |
| `{:ok, :unpinned}` | not `local_only` AND the per-request pin could not be taken. Proceeds exactly as before: a default scope never acquires a NEW failure mode |
| `{:error, {:egress_blocked, details}}` | PERMANENT configuration refusal, before any request |
| `{:error, {:pin_stale, details}}` | the pinned address set changed — re-pin, no `:user` write. TRANSIENT |
| `{:error, {:egress_unavailable, details}}` | the `local_only` MARKING itself could not be read (DB/pool hiccup). Fail-closed for this call, TRANSIENT |

Every refusal carries its `details` (`host`, `scope`, `verdict`, `remediation`),
so the reason recorded on a cancelled Oban job NAMES the scope and the offending
endpoint (AC-41.4.6) instead of a bare atom an operator cannot act on.

- **Oban**: `Loopctl.Egress.oban_result/1` is the ONE mapping.
  `:egress_blocked` → `{:cancel, reason}` — never `{:error, _}` (Oban retries it,
  burning `max_attempts` per item and repopulating the queue on every subsequent
  write) and never `{:snooze, _}` (an indefinite re-check loop against a config
  that will not change on its own). `:pin_stale` and `:egress_unavailable` →
  `{:snooze, _}`: an IP change or a pool blip is RECOVERABLE, the supervised
  refresher re-pins on its own, and nothing re-enqueues a cancelled job — so
  cancelling would silently strand the article/memory un-embedded.
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
- **Audit write amplification is bounded — ROWS *and* WRITES**: blocked decisions
  are deduplicated per `(scope, endpoint, reason, 60s window)` with an
  `occurrence_count`, AND the write itself is debounced in ETS by
  `Loopctl.Egress.BlockedBuffer` (one upsert per tuple per flush interval carrying
  the accumulated delta). Bounding rows alone would still serialize thousands of
  row-lock round-trips a minute on the 3-connection BYPASSRLS pool — the same pool
  the guard's own marking lookup needs. The exact per-call rate lives in telemetry,
  not in rows.

## Hot path

One cheap classification per provider call, no network or DB round-trip. The host
is resolved and classified into a PINNED IP set cached under
`(tenant_id, scope, host)` — never host alone, or tenant A's declaration would
make a host read as local for tenant B.

Invalidation is explicit, immediate and CLUSTER-WIDE on any mutation of the
tenant's declarations, markings or endpoint settings — a revoked declaration does
not keep working for the rest of the TTL, on ANY node. The ETS table is
`:named_table` (node-local) and Erlang does not share ETS, so `invalidate_tenant/1`
also broadcasts over `Phoenix.PubSub` (the pattern `Llm.SettingsCache` and
`Auth.ApiKeyCache` already use): peers bust within a hop, and the bounded TTL is
only the netsplit backstop. Without the broadcast, ENABLING `local_only` on one
node would leave peers answering `local_only: false` for up to ten minutes — a
privacy control with a ten-minute activation hole.

`Loopctl.Egress.PinCache` is a NAMED SUPERVISED process with jittered pre-expiry
refresh and a distinct `:revalidating` state. Without it, TTL expiry would be a
scheduled fleet-wide self-inflicted outage: every `local_only` tenant hard-refusing
at once. A privacy control whose steady state is an outage gets disabled in
production, which is how the guarantee actually dies.

Only PURPOSE-INDEPENDENT facts are cached (`base_verdict`, `ips`,
`from_allowlist`, the host's declared `purposes`); the verdict is derived per read
by `Policy.resolve_verdict/2`. Caching a purpose-derived verdict would let the
FIRST purpose to touch a host fix its verdict for the whole TTL.

Fail-closed is SCOPED: a stale or missing entry refuses only for `local_only`
scopes. A scope that is not `local_only` re-resolves normally and pins per
request, preserving the default-off promise for every existing tenant on vendor
endpoints. The `local_only` MARKING is resolved OUTSIDE the fail-closed classifier
rescue, with its own failure handling — otherwise a pool hiccup would raise inside
the rescue and PERMANENTLY cancel jobs for tenants that never opted in.
