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
//      (server URL + API key), so a fresh process loads it and sends a real
//      header on its first request, never tripping the bootstrap 412 at all.
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
//
// 409 IS NOT AUTO-RETRIED (deliberate): a `409 witness_divergence` means the
// client's cached STH prefix does not match the server's at that position — the
// genuine-fork / resync signal (custody-01). The client caches the server's STH
// from the 409's `x-loopctl-current-sth` header so the NEXT request self-heals,
// but the current request's 409 is surfaced (not silently retried) so a real
// divergence is never papered over. Only the bootstrap-grace 412 is retried.

import { createHash, randomBytes } from "node:crypto";

// Explicit override for the STH state-file location (absolute path). When unset,
// the file is derived under the OS temp dir, keyed by (server URL + API key).
export const STH_STATE_PATH_ENV = "LOOPCTL_STH_STATE_PATH";

// The `x-loopctl-current-sth` header the client caches / retries with. Shape:
// `<position>:<22-char base64url signature prefix>`. Validating the shape guards
// against a corrupt state file feeding a malformed header (which the server would
// itself reject 412 witness_header_malformed).
const STH_SHAPE = /^\d+:[A-Za-z0-9_-]{22}$/;

// The error code of the ONE 412 that is safe to transparently retry.
const BOOTSTRAP_CONSUMED_CODE = "witness_bootstrap_already_consumed";

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
 * override; otherwise derives a file under the OS temp dir keyed by BOTH the
 * server URL AND the API key, so two keys/tenants on the same host never share
 * (and clobber / spuriously invalidate) each other's cached STH. Only a NON-SECRET
 * sha256 hash of the key goes in the filename — the key itself never hits disk.
 *
 * @param {{ env: Record<string,string|undefined>, os: { tmpdir(): string }, path: { join(...p: string[]): string }, apiKey?: string }} deps
 * @returns {string}
 */
export function resolveSthStatePath({ env, os, path, apiKey = "" }) {
  const override = env[STH_STATE_PATH_ENV];
  if (typeof override === "string" && override.trim() !== "") return override;

  const baseUrl = (env.LOOPCTL_SERVER || "https://loopctl.com").replace(/\/$/, "");
  // Scope by server URL AND api key (#298 review HIGH-2): distinct keys must not
  // collide on one cache file. The key is hashed (never stored in plaintext).
  const digest = createHash("sha256").update(`${baseUrl}:${apiKey}`).digest("hex").slice(0, 16);
  return path.join(os.tmpdir(), `loopctl-mcp-sth-${digest}.json`);
}

/**
 * Load a persisted STH string from `filePath`, or `null`. NEVER throws — a
 * missing, unreadable, non-JSON, or shape-invalid file degrades to `null` so the
 * caller falls back to the bootstrap+retry path.
 *
 * SYMLINK / OWNERSHIP GUARD (CWE-59, #298 review HIGH-1): on a shared `/tmp` the
 * cache path is predictable, so a co-located user could pre-plant a file/symlink
 * there. Before reading we `lstat` the path and refuse (→ null, in-memory only) if
 * it is a symlink or is not owned by the current uid.
 *
 * @param {string} filePath
 * @param {{ fs: { readFileSync: Function, lstatSync?: Function }, getuid?: () => number }} deps
 * @returns {string|null}
 */
export function loadPersistedSth(filePath, { fs, getuid }) {
  try {
    if (typeof fs.lstatSync === "function") {
      const st = fs.lstatSync(filePath);
      if (st.isSymbolicLink()) return null;
      if (typeof getuid === "function" && st.uid !== getuid()) return null;
    }
    const parsed = JSON.parse(fs.readFileSync(filePath, "utf8"));
    const sth = parsed && typeof parsed.sth === "string" ? parsed.sth : null;
    return isValidSth(sth) ? sth : null;
  } catch {
    return null;
  }
}

/**
 * Persist an STH string to `filePath`. NEVER throws — a write failure (read-only
 * temp dir, full disk, symlink refusal) degrades to in-memory-only caching.
 * Returns whether the write succeeded.
 *
 * ATOMIC + SYMLINK-SAFE (CWE-59, #298 review HIGH-1): writes to a fresh
 * per-process temp file opened with `wx` (O_CREAT|O_EXCL — refuses a pre-planted
 * symlink at the temp path) and mode 0o600, then `rename`s it over `filePath`.
 * `rename` replaces the destination path ENTRY atomically and never writes THROUGH
 * a symlink at `filePath`, so an attacker's symlink there is replaced, not
 * followed — no arbitrary-file clobber. The rename-over also fixes the torn-file
 * race from a killed mid-write.
 *
 * @param {string} filePath
 * @param {string} sth
 * @param {{ fs: { writeFileSync: Function, renameSync: Function, unlinkSync?: Function }, pid?: number }} deps
 * @returns {boolean}
 */
export function persistSth(filePath, sth, { fs, pid = process.pid }) {
  if (!isValidSth(sth)) return false;
  const tmp = `${filePath}.${pid}.${randomBytes(6).toString("hex")}.tmp`;
  try {
    fs.writeFileSync(
      tmp,
      JSON.stringify({ sth, updated_at: new Date().toISOString() }),
      { encoding: "utf8", flag: "wx", mode: 0o600 },
    );
    fs.renameSync(tmp, filePath);
    return true;
  } catch {
    // Best-effort cleanup of the temp file; ignore any failure.
    try {
      if (typeof fs.unlinkSync === "function") fs.unlinkSync(tmp);
    } catch {
      /* ignore */
    }
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
 * targets the fresh-process bootstrap-grace 412 (#298). The caller additionally
 * confirms the body's `error.code` (see `createWitnessClient`).
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
 * caches + persists any STH the server returns, coalesces concurrent cold-start
 * bootstraps, and transparently retries a bootstrap-grace 412 ONCE.
 *
 * `send` returns the raw `Response` of the FINAL attempt so the caller keeps full
 * control of body parsing / error shaping. Network errors from `fetchImpl`
 * propagate (the caller's try/catch handles them); a network failure is not
 * retried.
 *
 * @param {{
 *   fetchImpl?: typeof fetch,
 *   statePath?: string|null,
 *   fs?: object,
 *   getuid?: () => number,
 *   pid?: number,
 *   timeoutMs?: number,
 * }} [deps]
 */
export function createWitnessClient({
  fetchImpl = fetch,
  statePath = null,
  fs,
  getuid,
  pid,
  timeoutMs = 30_000,
} = {}) {
  // Load any persisted STH so a FRESH process sends a real header on request #1
  // and skips the bootstrap-grace 412 entirely.
  let lastKnownSTH =
    statePath && fs ? loadPersistedSth(statePath, { fs, getuid }) : null;

  // Cold-start singleflight (#298 review MEDIUM-6): when several tool calls fire
  // at process start they all observe lastKnownSTH === null; without coalescing
  // each would send its own bootstrap. The FIRST becomes the leader; the rest
  // await its result and then send with the learned header.
  let bootstrapInFlight = null;

  function remember(sth) {
    if (!isValidSth(sth) || sth === lastKnownSTH) return;
    lastKnownSTH = sth;
    if (statePath && fs) persistSth(statePath, sth, { fs, pid });
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

  // Confirm a bootstrap-grace 412 against the DOCUMENTED contract before retrying
  // (#298 review LOW-8): status 412 + a valid STH header, AND — when the body is
  // readable — error.code === "witness_bootstrap_already_consumed". A body-read
  // failure falls back to the status+header decision so a transient parse issue
  // never defeats the retry. Reads a CLONE so the caller can still consume the
  // body of a response we end up NOT retrying.
  async function retrySthFor(response) {
    const sth = response.headers.get("x-loopctl-current-sth");
    if (!bootstrapRetrySth(response.status, sth)) return null;
    try {
      const body = await response.clone().json();
      const code = body && body.error && body.error.code;
      if (code && code !== BOOTSTRAP_CONSUMED_CODE) return null;
    } catch {
      /* unreadable body → fall back to status+header */
    }
    return sth;
  }

  async function performSend(req) {
    let response = await attempt(req);
    remember(response.headers.get("x-loopctl-current-sth"));

    // Bounded, single transparent retry for the bootstrap-grace 412. `remember`
    // above already cached the STH, so this second attempt sends a real header.
    if (await retrySthFor(response)) {
      response = await attempt(req);
      remember(response.headers.get("x-loopctl-current-sth"));
    }

    return response;
  }

  async function send(req) {
    // Cold-start coalescing: only the leader bootstraps; followers await it and
    // then send with the learned STH. On the (rare) leader failure, followers
    // fall through and each bootstrap — acceptable degradation.
    if (lastKnownSTH === null && bootstrapInFlight) {
      await bootstrapInFlight;
      return performSend(req);
    }

    if (lastKnownSTH === null) {
      let done;
      bootstrapInFlight = new Promise((resolve) => {
        done = resolve;
      });
      try {
        return await performSend(req);
      } finally {
        done();
        bootstrapInFlight = null;
      }
    }

    return performSend(req);
  }

  return {
    send,
    getSTH: () => lastKnownSTH,
  };
}
