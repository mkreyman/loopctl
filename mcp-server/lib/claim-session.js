/**
 * The SESSION discriminator used by the claim and lock paths (issue #779).
 *
 * Extracted into its own module for the same reason `witness-sth.js` was: this is a
 * predictable-temp-file consumer, its guards are security guards (CWE-59), and guards
 * that live inline in `index.js` cannot be tested against an injected fs.
 *
 * ## Why the claim paths need a different id from the post path
 *
 * `channel_post` stamps a session id once and nothing compares it again, so a
 * process-lifetime uuid is fine there (US-454 pins it). A CLAIM is long-lived — a lease
 * runs up to 24h — and its stamp is compared again on `channel_done` / `channel_release`;
 * an advisory file LOCK is the same shape, since the server resolves both the in-place
 * refresh and the release by the `(tenant, project, agent, session, key)` slot. With a
 * process-lifetime id, every npx respawn or `/mcp` reconnect turns the session's OWN live
 * work into a `409 claim_session_mismatch` (or a byte-identical `404` on unlock),
 * recoverable only by discovering `force: true`.
 *
 * ## The two failure directions are NOT symmetric
 *
 * A WRONG SPLIT — this session reading its own live claim as a peer's — is a 409 the
 * caller clears with `force: true`. A WRONG MERGE — two concurrent sessions stamping one
 * value — lets a peer's `channel_release` DELETE live work with no 409, no
 * `claim_session_guard` telemetry, and an audit row byte-identical to the owner ending
 * its own work. That is KB `07f5e839`'s incident, and it is the failure #779 exists to
 * prevent. So: prefer the most SPECIFIC session marker available, and never widen the
 * key for the sake of stability.
 */

/** A minted id is always a v4 uuid; anything else in the file is foreign. */
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * The session markers Claude Code exports into every MCP proxy it spawns, most
 * SPECIFIC first.
 *
 * `CLAUDE_CODE_SESSION_ID` is preferred over `CLAUDE_SESSION_ID` deliberately. Measured
 * on minis 2026-09-08 across all 5 running loopctl MCP processes: 3 carried no
 * `CLAUDE_SESSION_ID`, but ALL 5 carried `CLAUDE_CODE_SESSION_ID` — and its value is
 * DISTINCT per concurrent session, while `CLAUDE_SESSION_ID` is INHERITED by a headless
 * subsession (a `bin/review-worktree.sh` session and the session that launched it both
 * read one value, with their own `CLAUDE_CODE_SESSION_ID`s). Preferring the inherited one
 * is exactly the WRONG MERGE above. Both live in the environment, so a respawned proxy
 * under the same session re-reads the same value — the property the claim path needs.
 *
 * @param {Record<string, string|undefined>} env
 * @returns {string|null}
 */
export function envClaimSessionId(env) {
  for (const name of ["CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID"]) {
    const value = (env[name] || "").trim();
    if (value) return value;
  }
  return null;
}

/**
 * The last-resort state file's path, keyed by (host, launch cwd) — Claude Code launches
 * the proxy in the session's project root, so a worktree gets its own id and a respawn in
 * the same root re-reads it.
 *
 * @param {{ tmpdir: string, hostname: string, cwd: string, createHash: Function, join: Function }} deps
 * @returns {string}
 */
export function durableClaimSessionPath({
  tmpdir,
  hostname,
  cwd,
  createHash,
  join,
}) {
  const key = createHash("sha256")
    .update(`${hostname}\n${cwd}`)
    .digest("hex")
    .slice(0, 32);
  return join(tmpdir, `loopctl-mcp-claim-session-${key}.id`);
}

/**
 * Read a previously minted id, or `null`. NEVER throws.
 *
 * SYMLINK / OWNERSHIP GUARD (CWE-59, the same class as `witness-sth.js`'s "#298 review
 * HIGH-1"): the path is predictable from public data (hostname + cwd), so a co-located
 * user on a shared host can pre-plant a file or a symlink there. `lstat` first and refuse
 * a symlink or a foreign uid — otherwise the read follows the link and the CONTENTS OF
 * ANY FILE THIS USER CAN READ become the session id, which is then sent to the server,
 * stored in `channel_claims.claimed_by_session` and echoed to every peer session by
 * `GET /channel/claims`.
 *
 * SHAPE GUARD: only a v4 uuid is adopted. Without it, an attacker CHOOSES this proxy's
 * discriminator, and any oversized or credential-shaped content wedges every claim, done
 * and release from this directory behind a permanent 422 (the server-side cap, NUL and
 * denylist rules) with nothing pointing at `/tmp`.
 *
 * @param {string} filePath
 * @param {{ fs: { readFileSync: Function, lstatSync?: Function }, getuid?: () => number }} deps
 * @returns {string|null}
 */
export function readDurableClaimSessionId(filePath, { fs, getuid }) {
  try {
    if (typeof fs.lstatSync === "function") {
      const st = fs.lstatSync(filePath);
      if (st.isSymbolicLink()) return null;
      if (typeof getuid === "function" && st.uid !== getuid()) return null;
    }
    const existing = fs.readFileSync(filePath, "utf8").trim();
    return UUID_RE.test(existing) ? existing : null;
  } catch {
    return null;
  }
}

/**
 * The (host, cwd)-keyed fallback id, for a proxy carrying no session marker at all.
 * NEVER throws — an unreadable/unwritable temp dir degrades to an in-memory uuid, i.e.
 * the pre-#779 behaviour.
 *
 * What it does NOT separate, stated rather than assumed: two processes in one directory
 * that BOTH lack every session marker collide. That is unreachable from Claude Code
 * (which always sets `CLAUDE_CODE_SESSION_ID`), and there is nothing left to tell such
 * processes apart. Two MACHINES — the incident this feature exists for, KB `b447b16b` —
 * never collide.
 *
 * ATOMIC + SYMLINK-SAFE, mirroring `persistSth/3`: the mint writes a fresh per-process
 * temp file with `wx` (O_CREAT|O_EXCL, which refuses a pre-planted symlink at the temp
 * path) and `rename`s it over the destination. `rename` replaces the path ENTRY and never
 * writes THROUGH a symlink at `filePath`, so a planted symlink is replaced rather than
 * followed — no arbitrary-file clobber — and the torn-read race is gone. The re-read
 * afterwards makes two proxies starting together CONVERGE on the winner's value instead
 * of each keeping a divergent in-memory one, which would 409 the loser's own claims.
 *
 * @param {string} filePath
 * @param {{ fs: object, getuid?: () => number, randomUUID: () => string, randomBytes: (n: number) => {toString: Function}, pid?: number }} deps
 * @returns {string}
 */
export function durableClaimSessionId(
  filePath,
  { fs, getuid, randomUUID, randomBytes, pid = 0 },
) {
  const existing = readDurableClaimSessionId(filePath, { fs, getuid });
  if (existing) return existing;

  const minted = randomUUID();
  const tmp = `${filePath}.${pid}.${randomBytes(6).toString("hex")}.tmp`;
  try {
    fs.writeFileSync(tmp, minted, {
      encoding: "utf8",
      flag: "wx",
      mode: 0o600,
    });
    fs.renameSync(tmp, filePath);
  } catch {
    try {
      if (typeof fs.unlinkSync === "function") fs.unlinkSync(tmp);
    } catch {
      /* ignore */
    }
    return minted;
  }

  return readDurableClaimSessionId(filePath, { fs, getuid }) || minted;
}

/**
 * The full chain: the most specific env marker, else the hardened durable file.
 *
 * @param {object} deps
 * @returns {string}
 */
export function resolveClaimSessionId(deps) {
  return (
    envClaimSessionId(deps.env) ||
    durableClaimSessionId(durableClaimSessionPath(deps), deps)
  );
}
