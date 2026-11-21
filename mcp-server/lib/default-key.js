/**
 * The key a request sends when its tool pins none (`apiCall` without `exactKey`).
 *
 * Order: LOOPCTL_API_KEY, then the caller's override (a tool that names the agent or user
 * key), then LOOPCTL_ORCH_KEY, then this session's agent key (its holder credential once
 * registered, else LOOPCTL_AGENT_KEY).
 *
 * The last step is what lets a session that holds ONLY an agent key read at all. Without
 * it, list_stories and every other default-key read answered "No API key configured" in a
 * holder session, the shape the custody rule asks for (one key per process, never the
 * implementer's and the reviewer's together). Falling back to a key the process already
 * holds grants nothing: loopctl decides what that key's role may do, and a write it may not
 * make is still refused there.
 */
export function resolveDefaultKey({ env, keyOverride, agentKey }) {
  return env.LOOPCTL_API_KEY || keyOverride || env.LOOPCTL_ORCH_KEY || agentKey() || undefined;
}
