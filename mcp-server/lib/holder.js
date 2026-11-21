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
 * holder while it is live. A network error leaves the credential in place for the next tick.
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
  } = deps;

  const sessionId = envClaimSessionId(env) || randomUUID();
  let holder = null;
  let credential = null;
  let timer = null;
  let ended = false;

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

    const result = await apiCall(
      "POST",
      HOLDERS_PATH,
      { kind: "interactive", session_id: sessionId, host: hostname(), worktree: worktree() },
      key,
      { exactKey: true },
    );

    if (result && !result.error && result.holder) {
      holder = result.holder;
      // `credential: null` means the key we sent is already this holder's; keep what we hold.
      if (result.credential && result.credential.raw_key) credential = result.credential.raw_key;
      ended = false;
      arm(result.heartbeat_seconds);
    }

    return result;
  }

  async function heartbeat() {
    if (!holder || !credential) return register();

    const result = await apiCall("POST", heartbeatPath(holder.id), null, credential, {
      exactKey: true,
    });

    if (result && result.error && GONE.has(result.status)) {
      credential = null;
      holder = null;
      return register();
    }

    if (result && !result.error && result.lease_until) {
      holder = { ...holder, lease_until: result.lease_until };
    }

    return result;
  }

  async function end() {
    stopTimer();
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
