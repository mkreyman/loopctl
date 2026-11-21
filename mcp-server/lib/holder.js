/**
 * The session holder (US-52.13): this MCP process registers its Claude Code session with
 * loopctl, sends every agent-key request with the holder's own credential, heartbeats the
 * holder's lease, and ends it on shutdown.
 *
 * Before this, every fleet session sent the same LOOPCTL_AGENT_KEY, so loopctl could not
 * tell two sessions of one agent apart (loopctl#707).
 *
 * ## What happens when loopctl is slow, down, or refuses
 *
 * The holder is an IMPROVEMENT on the shared key, never a precondition for working: when the
 * register fails for any reason (an older server answering 404, an agent-rooted tenant
 * answering 403, a network error, the startup timeout), `agentKey()` keeps answering
 * LOOPCTL_AGENT_KEY and the session works exactly as it did before. A heartbeat refused
 * 401/404/409 means the credential or holder is gone (a laptop slept past the lease, the
 * holder was ended): the next tick registers again, which loopctl answers with the SAME
 * holder while it is live. A heartbeat refused 409 holder_lease_expired (US-52.19) ended the
 * holder and released its claims, so the register makes a NEW holder, and the lapse is
 * logged to stderr. A network error leaves the credential in place for the next tick. A
 * register that fails TRANSIENTLY (no answer, a timeout, 429 or 5xx, at startup or after a
 * refused heartbeat) arms the timer anyway, so the session registers once loopctl answers
 * (US-52.13's partition answer). A refusal (any other 4xx: an older server's 404, 403
 * custody_tier_required, 403 holder_mint_forbidden, 409 session_id_held) is final for the
 * process: it stays on LOOPCTL_AGENT_KEY and never asks again.
 *
 * An end is final for every call already in flight: each register and heartbeat remembers
 * the generation it started in, and one that lands after an end adopts nothing, so a
 * heartbeat refused because the end revoked its credential never registers the session
 * back to life. An explicit register after the end starts a new generation and is honoured.
 *
 * ## The session id
 *
 * The claim path's discriminator (`envClaimSessionId`, `lib/claim-session.js`), which prefers
 * CLAUDE_CODE_SESSION_ID because CLAUDE_SESSION_ID is inherited by a headless subsession: two
 * concurrent sessions reading one value would share a holder, the wrong merge #779 exists to
 * prevent. A uuid minted once per process stands in when neither is set.
 *
 * The raw credential lives only in this process's memory and is never returned by a tool.
 */

import { envClaimSessionId } from "./claim-session.js";

export const HOLDERS_PATH = "/api/v1/holders";

/** @param {string} id */
export function heartbeatPath(id) {
  return `${HOLDERS_PATH}/${encodeURIComponent(id)}/heartbeat`;
}

/** @param {string} id */
export function endPath(id) {
  return `${HOLDERS_PATH}/${encodeURIComponent(id)}/end`;
}

const GONE = new Set([401, 404, 409]);

// The retry interval before loopctl has named one: the server's own heartbeat interval
// (HOLDER_HEARTBEAT_SECONDS' default), so an unregistered session retries no faster than a
// registered one beats.
const DEFAULT_HEARTBEAT_SECONDS = 60;

/** A failed call worth retrying: no answer at all, rate limited, or a server error. */
function transient(result) {
  const status = result && result.status;
  return !result || !status || status === 429 || status >= 500;
}

/** The `error.code` of a refusal body, parsed or raw. */
function errorCode(body) {
  let parsed = body;
  if (typeof body === "string") {
    try {
      parsed = JSON.parse(body);
    } catch {
      return null;
    }
  }
  return (parsed && parsed.error && parsed.error.code) || null;
}

/**
 * @param {{
 *   apiCall: Function,
 *   env: Record<string, string|undefined>,
 *   hostname: () => string,
 *   worktree: () => string,
 *   randomUUID: () => string,
 *   setInterval?: Function,
 *   clearInterval?: Function,
 * }} deps
 */
export function createHolderSession(deps) {
  const {
    apiCall,
    env,
    hostname,
    worktree,
    randomUUID,
    setInterval: setTimer = globalThis.setInterval,
    clearInterval: clearTimer = globalThis.clearInterval,
    // US-52.18: run after every register or heartbeat that leaves a live credential (the
    // branch open, lib/branch-item.js). Its failure never fails the heartbeat.
    afterBeat = null,
    // US-52.19: where a lapse is reported. stderr, never stdout: stdout is the MCP stream.
    log = (line) => process.stderr.write(`${line}\n`),
  } = deps;

  async function beat(result) {
    if (afterBeat && holder && credential && result && !result.error) {
      try {
        await afterBeat(holder, credential);
      } catch {
        // The next heartbeat tries again.
      }
    }
    return result;
  }

  const sessionId = envClaimSessionId(env) || randomUUID();
  let holder = null;
  let credential = null;
  let timer = null;
  let ended = false;
  // Bumped by end(): a call started before it adopts nothing that lands after it.
  let generation = 0;

  function plainKey() {
    return env.LOOPCTL_AGENT_KEY;
  }

  /** The key every agent-key request is sent with. */
  function agentKey() {
    return credential || plainKey();
  }

  function stopTimer() {
    if (timer !== null) {
      clearTimer(timer);
      timer = null;
    }
  }

  function arm(seconds) {
    stopTimer();
    const ms = Math.max(1, Number(seconds) || 60) * 1000;
    timer = setTimer(() => {
      heartbeat().catch(() => {});
    }, ms);
    if (timer && typeof timer.unref === "function") timer.unref();
  }

  async function register() {
    const key = plainKey();
    if (!key) return { error: true, status: 0, body: "LOOPCTL_AGENT_KEY is not set" };

    const gen = generation;
    const result = await apiCall(
      "POST",
      HOLDERS_PATH,
      { kind: "interactive", session_id: sessionId, host: hostname(), worktree: worktree() },
      key,
      { exactKey: true },
    );

    if (gen !== generation) return result;

    if (result && !result.error && result.holder) {
      holder = result.holder;
      // `credential: null` means the key we sent is already this holder's; keep what we hold.
      if (result.credential && result.credential.raw_key) credential = result.credential.raw_key;
      ended = false;
      arm(result.heartbeat_seconds);
    } else if (transient(result)) {
      // Not registered for a reason that passes: keep ticking, the next tick registers again.
      if (timer === null) arm(DEFAULT_HEARTBEAT_SECONDS);
    } else {
      // Refused: a timer left from an earlier holder would ask again every tick.
      stopTimer();
    }

    return beat(result);
  }

  async function heartbeat() {
    if (!holder || !credential) return register();

    const gen = generation;
    const result = await apiCall("POST", heartbeatPath(holder.id), null, credential, {
      exactKey: true,
    });

    if (gen !== generation) return result;

    if (result && result.error && GONE.has(result.status)) {
      // US-52.19: a heartbeat after the lease ran out ended the holder and released its
      // claims, so this session comes back as a NEW holder and must re-claim what it held.
      if (errorCode(result.body) === "holder_lease_expired") {
        log(
          `loopctl: holder ${holder.id} lapsed (its lease ran out before this heartbeat); ` +
            "its claims were released. Registering a new holder.",
        );
      }
      credential = null;
      holder = null;
      return register();
    }

    if (result && !result.error && result.lease_until) {
      holder = { ...holder, lease_until: result.lease_until };
    }

    return beat(result);
  }

  async function end() {
    stopTimer();
    generation += 1;
    if (!holder || !credential || ended) return { ended: true, holder };

    const id = holder.id;
    const key = credential;
    ended = true;
    credential = null;

    const result = await apiCall("POST", endPath(id), null, key, { exactKey: true });
    if (result && !result.error && result.holder) holder = result.holder;
    return result;
  }

  /** Registers at startup, waiting at most `timeoutMs` so a slow loopctl never blocks startup. */
  async function start({ timeoutMs = 5000 } = {}) {
    let timeout;
    const cap = new Promise((resolve) => {
      timeout = setTimeout(() => resolve({ error: true, status: 0, body: "register timed out" }), timeoutMs);
      if (typeof timeout.unref === "function") timeout.unref();
    });

    try {
      return await Promise.race([register().catch((err) => ({ error: true, body: err.message })), cap]);
    } finally {
      clearTimeout(timeout);
    }
  }

  /** What a tool may show: never the raw credential. */
  function status() {
    return {
      session_id: sessionId,
      holder,
      using_holder_credential: Boolean(credential),
    };
  }

  return { agentKey, register, heartbeat, end, start, status, sessionId };
}
