// Witness-protocol (Signed Tree Head) client state — shared by index.js and the
// test suite so both exercise the SAME retry + persistence logic.
//
// Background (loopctl chain-of-custody v2, §4.4): every authenticated request
// must echo the caller's last-known STH via `X-Loopctl-Last-Known-STH`. A brand
// new caller has no STH, so its FIRST request opts in with
// `X-Loopctl-STH-Bootstrap: true` to receive the current STH in the response's
// `x-loopctl-current-sth` header. That bootstrap grace is ONE-TIME PER API KEY
// (custody-03 / GHSA-36g5-mcrh-rcrm): once consumed, a later request that still
// lacks the header gets `412 witness_bootstrap_already_consumed`.
//
// The MCP server is a short-lived process: a fresh Claude session spawns a fresh
// process that historically started with no STH, so — once the key's one-time
// grace was consumed by an earlier process — its very first tool call hit that
// 412 (#298). This module fixes that on the CLIENT side, two ways:
//
//   1. PERSISTENCE — the learned STH is cached to a small state file keyed by
//      server URL, so a fresh process loads it and sends a real header on its
//      first request, never tripping the bootstrap 412 at all.
//   2. TRANSPARENT RETRY — if a request still hits a witness-plug 412 that
//      carries the current STH (e.g. the state file was missing/corrupt), the
//      client caches that STH and retries the SAME request ONCE, so the tool
//      call succeeds instead of surfacing the 412.
//
// SAFETY: the witness plug runs early and HALTS the request before the operation
// executes, so a witness 412/409 means the original request had no side effect —
// retrying it once is safe even for non-idempotent POSTs. The retry is bounded to
// a single attempt (never a loop). None of this weakens the server-side one-time
// grace: it only teaches legit clients to carry/relearn the STH they are entitled
// to. See mcp-server/README.md → "Witness protocol (STH)".

import { createHash } from "node:crypto";

// Explicit override for the STH state-file location (absolute path). When unset,
// the file is derived under the OS temp dir, keyed by the server URL.
export const STH_STATE_PATH_ENV = "LOOPCTL_STH_STATE_PATH";

// The `x-loopctl-current-sth` header the client caches / retries with. Shape:
// `<position>:<22-char base64url signature prefix>`. Validating the shape guards
// against a corrupt state file feeding a malformed header (which the server would
// itself reject 412 witness_header_malformed).
const STH_SHAPE = /^\d+:[A-Za-z0-9_-]{22}$/;

/**
 * True when `sth` is a well-formed `<position>:<22-char base64url prefix>` value.
 * @param {unknown} sth
 * @returns {boolean}
 */
export function isValidSth(sth) {
  return typeof sth === "string" && STH_SHAPE.test(sth);
}

/**
 * Resolve the STH state-file path. Honors an explicit `LOOPCTL_STH_STATE_PATH`
 * override; otherwise derives a per-server file under the OS temp dir so distinct
 * loopctl servers don't share (and needlessly invalidate) each other's STH. The
 * server URL — not the API key — is hashed, so no secret is written to a path.
 *
 * @param {{ env: Record<string,string|undefined>, os: { tmpdir(): string }, path: { join(...p: string[]): string } }} deps
 * @returns {string}
 */
export function resolveSthStatePath({ env, os, path }) {
  const override = env[STH_STATE_PATH_ENV];
  if (typeof override === "string" && override.trim() !== "") return override;

  const baseUrl = (env.LOOPCTL_SERVER || "https://loopctl.com").replace(/\/$/, "");
  const digest = createHash("sha256").update(baseUrl).digest("hex").slice(0, 16);
  return path.join(os.tmpdir(), `loopctl-mcp-sth-${digest}.json`);
}

/**
 * Load a persisted STH string from `filePath`, or `null`. NEVER throws — a
 * missing, unreadable, non-JSON, or shape-invalid file degrades to `null` so the
 * caller falls back to the bootstrap+retry path.
 *
 * @param {string} filePath
 * @param {{ readFileSync(p: string, enc: string): string }} deps
 * @returns {string|null}
 */
export function loadPersistedSth(filePath, { readFileSync }) {
  try {
    const parsed = JSON.parse(readFileSync(filePath, "utf8"));
    const sth = parsed && typeof parsed.sth === "string" ? parsed.sth : null;
    return isValidSth(sth) ? sth : null;
  } catch {
    return null;
  }
}

/**
 * Persist an STH string to `filePath`. NEVER throws — a write failure (read-only
 * temp dir, full disk) degrades to in-memory-only caching. Returns whether the
 * write succeeded.
 *
 * @param {string} filePath
 * @param {string} sth
 * @param {{ writeFileSync(p: string, data: string, enc: string): void }} deps
 * @returns {boolean}
 */
export function persistSth(filePath, sth, { writeFileSync }) {
  if (!isValidSth(sth)) return false;
  try {
    writeFileSync(
      filePath,
      JSON.stringify({ sth, updated_at: new Date().toISOString() }),
      "utf8",
    );
    return true;
  } catch {
    return false;
  }
}

/**
 * Decide whether a response should trigger a one-shot transparent retry, and with
 * which STH. Returns the STH to retry with, or `null`.
 *
 * Gated on `412` AND a shape-valid `x-loopctl-current-sth` header — which the
 * witness plug sets ONLY on the `witness_bootstrap_already_consumed` branch (not
 * on the malformed/missing 412s, where a retry couldn't help). This precisely
 * targets the fresh-process bootstrap-grace 412 (#298).
 *
 * @param {number} status
 * @param {string|null|undefined} currentSthHeader
 * @returns {string|null}
 */
export function bootstrapRetrySth(status, currentSthHeader) {
  return status === 412 && isValidSth(currentSthHeader) ? currentSthHeader : null;
}

/**
 * Create a witness-aware request client that owns the shared STH state (loaded
 * from `statePath` at construction), injects the witness header on every attempt,
 * caches + persists any STH the server returns, and transparently retries a
 * bootstrap-grace 412 ONCE.
 *
 * `send` returns the raw `Response` of the FINAL attempt so the caller keeps full
 * control of body parsing / error shaping. Network errors from `fetchImpl`
 * propagate (the caller's try/catch handles them); a network failure is not
 * retried.
 *
 * @param {{
 *   fetchImpl?: typeof fetch,
 *   statePath?: string|null,
 *   readFileSync?: (p: string, enc: string) => string,
 *   writeFileSync?: (p: string, data: string, enc: string) => void,
 *   timeoutMs?: number,
 * }} [deps]
 */
export function createWitnessClient({
  fetchImpl = fetch,
  statePath = null,
  readFileSync,
  writeFileSync,
  timeoutMs = 30_000,
} = {}) {
  // Load any persisted STH so a FRESH process sends a real header on request #1
  // and skips the bootstrap-grace 412 entirely.
  let lastKnownSTH =
    statePath && readFileSync ? loadPersistedSth(statePath, { readFileSync }) : null;

  function remember(sth) {
    if (!isValidSth(sth) || sth === lastKnownSTH) return;
    lastKnownSTH = sth;
    if (statePath && writeFileSync) persistSth(statePath, sth, { writeFileSync });
  }

  async function attempt({ url, method, headers, serializedBody }) {
    // Witness protocol: echo the cached STH, or (never seen one) request a
    // one-time bootstrap. A fresh AbortSignal per attempt so the retry gets its
    // own timeout budget.
    const withWitness = { ...headers };
    if (lastKnownSTH) withWitness["X-Loopctl-Last-Known-STH"] = lastKnownSTH;
    else withWitness["X-Loopctl-STH-Bootstrap"] = "true";

    const options = {
      method,
      headers: withWitness,
      signal: AbortSignal.timeout(timeoutMs),
    };
    if (serializedBody !== undefined) options.body = serializedBody;

    return fetchImpl(url, options);
  }

  async function send(req) {
    let response = await attempt(req);
    let sth = response.headers.get("x-loopctl-current-sth");
    if (sth) remember(sth);

    // Bounded, single transparent retry for the bootstrap-grace 412. `remember`
    // above already cached the STH, so this second attempt sends a real header.
    if (bootstrapRetrySth(response.status, sth)) {
      response = await attempt(req);
      const retrySth = response.headers.get("x-loopctl-current-sth");
      if (retrySth) remember(retrySth);
    }

    return response;
  }

  return {
    send,
    getSTH: () => lastKnownSTH,
  };
}
