/**
 * `mcp_version` — the running package's version, and loopctl's expectation of it (#846.7).
 *
 * ## THE DEFECT
 *
 * MCP binds at session start. A tool merged, green and deployed is still not callable until
 * the package publishes AND the session reconnects, and from inside that session the two
 * states "this tool does not exist" and "this tool exists and my process is older than it" are
 * IDENTICAL: both are a name that is not in the surface. loopctl #861 is the measured case —
 * `force_unclaim_story` merged at 00:32:45Z on 2026-09-16 and the session that needed it to
 * free a parked story reported the capability as MISSING while it was merely STALE.
 *
 * The remedy is the one the runner contract already uses. A runner sends its
 * `contract_version` on join and loopctl answers with its own
 * (`lib/loopctl_web/runner_channel.ex:155`, `{:ok, %{contract_version:
 * RunnerContract.version()}}`), so a runner holding a vendored 1.11.0 against a server
 * speaking 1.12.0 KNOWS it is behind instead of discovering it through a missing field. Both
 * sides publish; neither has to infer.
 *
 * ## WHY A TOOL OF ITS OWN, RATHER THAN A FIELD ON AN EXISTING CALL
 *
 * The version is ALREADY published on this connection and it reaches nobody who needs it:
 * `new Server({ name: "loopctl", version: SERVER_VERSION }, …)` in `index.js` puts it in the
 * MCP handshake, which the model never sees. So "report it on the tool surface" has to mean
 * something a session can CALL, and three properties decide which:
 *
 *   - IT MUST ANSWER WITH NO KEY. The staleness question arises exactly when calls are
 *     failing, and every other cheap call needs a configured key of some role. This one reads
 *     `/.well-known/loopctl`, which is unauthenticated (`lib/loopctl_web/router.ex:113-118`,
 *     `pipe_through :api` with no auth pipeline), through `publicApiCall` — so it answers on a
 *     process with nothing configured at all.
 *   - A FIELD IS ONLY READ BY SOMEONE ALREADY MAKING THAT CALL. Bolting the version onto
 *     `list_routes` answers a session that had another reason to list routes, which is not the
 *     session in trouble, and it changes that tool's response shape for every existing caller.
 *   - THE TOOL'S OWN ABSENCE IS PART OF THE ANSWER. A name missing from the surface is the one
 *     signal a stale process can still emit: no `mcp_version` means the process predates
 *     2.99.0. A field cannot be absent in a way anyone notices without first making the call
 *     that carries it.
 *
 * ## WHAT `expected` ACTUALLY IS — stated precisely, because it is not "the npm latest"
 *
 * `GET /.well-known/loopctl` returns `mcp_server.npm_version`, read by the DEPLOYED SERVER at
 * ITS compile time from this repository's own `mcp-server/package.json`
 * (`lib/loopctl_web/controllers/well_known_controller.ex:20-27`, an `@external_resource` +
 * `File.read` at module compile). So `expected` is the version in the tree that deployment was
 * built from — not a registry lookup, and this client never talks to npm.
 *
 * Two consequences a caller must not be surprised by:
 *
 *   - `behind` can be true for a few minutes with nothing to install yet: a merge to master
 *     that bumps `mcp-server/package.json` triggers the deploy and
 *     `.github/workflows/mcp-autopublish.yml` INDEPENDENTLY, so the deployed server can
 *     advertise a version npm has not finished publishing. The remedy does not change —
 *     reconnect, once it is published — but "behind" is not by itself proof that a newer
 *     package is installable this second.
 *   - `ahead` is normal on a development machine running the package from a checkout, and it
 *     means the deployment is older than your client rather than anything being wrong.
 *
 * NEITHER SIDE IS A GATE. Nothing here refuses a call, and nothing should: this is a report so
 * that a session stops guessing, exactly as the join reply is for a runner.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

/** RFC 8615 discovery document. Unauthenticated; see the header. */
export const DISCOVERY_PATH = "/.well-known/loopctl";

/**
 * The version of the `package.json` this module ships beside.
 *
 * SINGLE SOURCE OF TRUTH, and the reason this is a function rather than a literal is the whole
 * of #846.7 one layer down: a hardcoded constant that drifts from the package reports a
 * version nobody is running. npm always includes `package.json` in the published tarball, so
 * this read works from an `npx` install exactly as it does from a checkout. `index.js` derives
 * its handshake version from here too, so the handshake, this tool and the package cannot
 * disagree.
 */
export function packageVersion(readFile = readFileSync) {
  const here = path.dirname(fileURLToPath(import.meta.url));
  return JSON.parse(readFile(path.join(here, "..", "package.json"), "utf8")).version;
}

/**
 * Compare two dot-separated versions numerically.
 *
 * Returns -1 / 0 / 1, or `null` when either side is not a version this can order. A
 * prerelease suffix (`2.98.0-rc.1`) is compared on its numeric prefix alone and the suffix is
 * ignored: this package has never published one, and inventing a precedence rule for a case
 * that does not occur would be a claim the tests could not check.
 */
export function compareVersions(a, b) {
  const parse = (v) => {
    if (typeof v !== "string") return null;
    const core = v.trim().split(/[-+]/)[0];
    const parts = core.split(".");
    if (parts.length === 0 || !parts.every((p) => /^\d+$/.test(p))) return null;
    return parts.map(Number);
  };

  const left = parse(a);
  const right = parse(b);
  if (!left || !right) return null;

  for (let i = 0; i < Math.max(left.length, right.length); i++) {
    const l = left[i] ?? 0;
    const r = right[i] ?? 0;
    if (l !== r) return l < r ? -1 : 1;
  }
  return 0;
}

const REMEDY = {
  current:
    "Nothing to do. Because these agree, a tool you cannot see genuinely does not exist in " +
    "this version — look for it under another name, or file it. Do not wait for it to appear.",
  behind:
    "Your MCP process is older than the tool surface loopctl ships. A tool you cannot see may " +
    "well exist: run /mcp to reconnect, or restart the session. DO NOT RETRY THE CALL — MCP " +
    "binds its tool list at session start, so the same process will answer the same way for " +
    "ever. If the reconnect does not pick it up, npm may not have finished publishing that " +
    "version yet (the deploy and the publish run independently); wait and reconnect again.",
  ahead:
    "Your MCP process is NEWER than the deployment's own tree, which is normal when running " +
    "this package from a checkout. Nothing to do about the client; a tool it declares may " +
    "call an endpoint this deployment does not serve yet.",
  unknown:
    "loopctl's expected version could not be read, so staleness is undecided — this says " +
    "nothing about whether a missing tool exists. Check LOOPCTL_SERVER and the network. The " +
    "running version above is still exact.",
};

/**
 * What `result.body` adds to a failed discovery request, as a sentence to append.
 *
 * `status 0` ALONE IS NOT A DIAGNOSIS, and this tool exists for exactly the session where the
 * diagnosis is the whole answer. `publicApiCall` uses status 0 for every local failure and puts
 * the cause in `body`: `Network error: <message> (<cause>)` — which is where an `ENOTFOUND` or a
 * `ECONNREFUSED` lives — or `Request timed out after 30s` (`index.js`, its `catch` around
 * `fetch`). A caller reading only the 0 learns that no server answered and nothing about why,
 * so a typo'd LOOPCTL_SERVER, a dead network and a slow one are one message. An HTTP failure
 * puts the server's own error body there instead, which is equally the thing to read.
 *
 * Bounded and never trusted to be a string: `apiCall`-shaped bodies are parsed JSON as often as
 * text, and this string goes into a tool result a session reads.
 */
function cause(body) {
  if (body === undefined || body === null || body === "") return "";

  const text = typeof body === "string" ? body : safeJson(body);
  if (!text) return "";

  const trimmed = text.replace(/\s+/g, " ").trim();
  if (trimmed === "") return "";

  return ` ${trimmed.length > 300 ? `${trimmed.slice(0, 300)}… (truncated)` : trimmed}`;
}

function safeJson(value) {
  try {
    return JSON.stringify(value);
  } catch {
    // A circular or otherwise unserialisable body must not turn a version report into a
    // throw — the whole contract of this tool is that it always answers.
    return "";
  }
}

/**
 * `mcp_version`: what this process is running, what loopctl expects, and what the difference
 * means.
 *
 * Never an error result. A discovery document that cannot be read yields `status: "unknown"`
 * WITH the running version, because half the answer is the half the caller most needs and a
 * version report that fails when the network does would be useless in the situation it is for.
 */
export async function mcpVersion(_args = {}, { publicApiCall, version, baseUrl } = {}) {
  const running = version ?? packageVersion();

  let expected = null;
  let detail = null;

  const result = await publicApiCall("GET", DISCOVERY_PATH, null);

  if (result && result.error) {
    detail = `loopctl discovery request failed (status ${result.status}).${cause(result.body)}`;
  } else {
    expected = result?.mcp_server?.npm_version ?? null;
    if (!expected) {
      detail =
        "loopctl's discovery document carried no mcp_server.npm_version. That field is part " +
        "of the published schema, so its absence means an older deployment.";
    }
  }

  const order = expected === null ? null : compareVersions(running, expected);
  const status =
    order === null ? "unknown" : order < 0 ? "behind" : order > 0 ? "ahead" : "current";

  if (status === "unknown" && expected !== null && detail === null) {
    detail = `Neither "${running}" nor "${expected}" could be ordered as a version.`;
  }

  return {
    running,
    expected,
    status,
    remedy: REMEDY[status],
    // WHICH deployment answered. `expected` is that deployment's own tree, so a session
    // pointed at a staging LOOPCTL_SERVER is comparing against staging and not production,
    // and a verdict with no server named cannot be acted on.
    server: baseUrl ?? null,
    ...(detail ? { detail } : {}),
  };
}
