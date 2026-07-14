# Epic 37 — Outbound Provider Admission Control & Backpressure

Remediation of GitHub issue **#352** (roadmap Epic 5, tracked **#355**) — the
direct mechanism of the provider-side 429 / `:transport_error` storm. Nothing
today sits between agent demand and the provider socket: provider calls fire
immediately, 429s are ignored by the circuit breaker, retries ignore
`Retry-After`, and the interactive search path embeds synchronously in the web
request process with no concurrency cap.

## Scope reconciliation (verified against `master` before authoring)

| #352 finding | Status | Evidence |
|--------------|--------|----------|
| Per-tenant LLM settings re-read + Cloak-decrypt on every provider call | ✅ done | **US-32.3** — `Loopctl.Llm.SettingsCache` ETS cache, generation-bump + PubSub bust + TTL |
| HeavyRead pool isolation / per-read `statement_timeout` / 503 crash-loop | ✅ done (topology only) | **Epic 33** — dedicated BYPASSRLS pool (size 8), `SET LOCAL` timeout, DbCapacity budget. **Per-tenant fairness within the pool NOT done → US-37.5** |
| Genuine-outage `provider_error` telemetry signal | ✅ done | **US-34.3** — `Llm.record_provider_error/2` choke points (`anthropic.ex:169`, `knowledge.ex:7393`) |
| Per-tenant Oban queue monopolization (background jobs) | ✅ done | **US-36.2** — `Loopctl.Oban.FairShare` |
| Inbound ingest backpressure (429 + Retry-After to the caller) | ✅ done | **US-36.3** — admission gate on `/knowledge/ingest*` |
| Distributed (cluster-wide) limiter/breaker store | ⏸ deferred to Epic 38 | breaker + settings cache + fair-share are all node-local by design; a shared store is the multi-node concern |

The **genuinely-remaining** work (the core of #352 — all about the outbound 429-storm):

| Finding | Status | Story |
|---------|--------|-------|
| No client-side admission control / token bucket before provider `Req.post` | ❌ open | **US-37.1** |
| Query-path embedding runs unbounded in the request process (bare `Task.async`, no cap) | ❌ open | **US-37.2** |
| Breaker deliberately ignores 429 (all 4xx exempt as one bucket) | ❌ open | **US-37.3** |
| Retry backoff ignores provider `Retry-After` (blind `attempt^4`) | ❌ open | **US-37.3** |
| Embeddings issued one text per request; no array batching | ❌ open | **US-37.4** |
| No per-tenant in-flight cap on the shared HeavyRead pool (one tenant can hold all 8 slots) | ❌ open | **US-37.5** |

## Stories

| Story | Title | Depends |
|-------|-------|---------|
| US-37.1 | Per-`(tenant, provider)` token-bucket admission gate (Hammer) before every provider `Req.post`; empty → fast-fail `:rate_limited_local` (breaker-exempt) → keyword fallback | — |
| US-37.2 | Bound the interactive embedding path: supervised, per-node concurrency-capped `generate_embedding` (web *and* Oban), replacing the bare `Task.async` | — |
| US-37.3 | Throttle-aware circuit breaker + honor provider `Retry-After` (count 429/408, exempt 401/403; Retry-After drives breaker cooldown *and* Oban snooze/backoff; latency trip) | US-37.1 |
| US-37.4 | Batch background embeddings into arrays (~100), map results back by index | — |
| US-37.5 | Per-tenant in-flight concurrency cap (semaphore) + cost-weighted limiter on the HeavyRead pool | — |

## Non-negotiable constraints (system is LIVE)

- **Fail SAFE, never fail the user.** A full/empty token bucket, an open breaker,
  or a saturated concurrency cap must degrade gracefully: the interactive search
  path falls back to **keyword search** (the existing `:circuit_open` fallback),
  never a 500. `:rate_limited_local` is **breaker-exempt** — a local admission
  decision is not a provider failure.
- **Node-local is the target** (Hammer buckets, breaker ETS, semaphores are
  per-node) — consistent with the epic_36 stock-fallback decision. A cluster-wide
  shared store is **out of scope, deferred to Epic 38 (#353)**. Size the buckets
  per node against the tenant's known RPM/TPM.
- **All limits env-driven** (extend `SystemConfig` / config-based DI: RPM/TPM,
  concurrency caps, breaker thresholds, batch size, HeavyRead per-tenant slice)
  so ops can tune during an incident with no deploy. **Never set a secret to a
  doc placeholder** (epic_35 `STH_SWEEP_CRON` lesson).
- **Provider-request semantics unchanged** on the happy path — a call that would
  succeed today still succeeds, same request body (except US-37.4's array
  batching, which must map results back to inputs by index with a correctness
  test). US-37.3 keeps `401/403` breaker-exempt (a bad key is not a provider
  outage) while making `429/408` count.
- **Assert outcome classes, not timing** — breaker/backoff/concurrency tests run
  in the async suite; assert the behavior class (fell back to keyword, snoozed
  with the Retry-After delay, capped at N concurrent) not exact instants (the
  Mox/async-supervisor flake lesson).
- Every merge is smoke-gated (`knowledge_count` / search-path health either
  side) and the master **Deploy + Post-deploy Smoke** watched to green
  (runtime.exs/env changes only fail at release boot — epic_35 lesson).
