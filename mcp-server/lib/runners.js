/**
 * Runner tools (loopctl issue #809): enroll, list and revoke the runners of the agent
 * delivery loop, and read the tenant's connected pool.
 *
 * WHY ENROLL WRITES A FILE. `POST /api/v1/runners` returns the runner's credential once.
 * Whoever holds it can join as that machine and receive its dispatches. A tool result
 * lands in the session transcript and the audit log, so the token must never be in one.
 * This process runs on the machine being enrolled, so `enrollRunner` writes the token to
 * `token_file` itself and returns only the runner row and the path.
 *
 * The file is RESERVED before the API is called: it is opened O_CREAT|O_EXCL with mode
 * 0600, so an existing path (or a symlink at that path) is refused without enrolling
 * anything, and a missing or unwritable directory fails before a credential exists. What
 * can still fail after enrollment is the write itself (ENOSPC, EIO). That token is then
 * unrecoverable, so the runner is revoked before the error is returned.
 *
 * Only a 4xx is an unambiguous refusal. Every other failure may have enrolled the runner,
 * and a 2xx whose body failed to parse carries the token in the text apiCall kept, so on
 * those paths no response body is echoed at all (`ambiguousEnrollment`).
 *
 * Missing PARENT directories are created with mode 0700. That is safe: `mkdir` with
 * `recursive` leaves every existing directory's mode alone, only ever creates directories
 * this user owns, and 0700 is no wider than the 0600 file inside. Refusing instead would
 * make the first enrollment on a fresh machine fail on `~/.config/loopctl-runner/`.
 *
 * SINGLE SOURCE OF TRUTH. index.js calls these functions with the HTTP call injected, so
 * the unit suite exercises the shipped code with fakes and a real temp directory.
 *
 * Nothing in this module logs. The token lives in one local variable and is only ever
 * passed to the file handle's write.
 */

import nodePath from "node:path";
import os from "node:os";
import { constants as fsConstants } from "node:fs";
import defaultFs from "node:fs/promises";

export const TOKEN_FILE_MODE = 0o600;
export const TOKEN_DIR_MODE = 0o700;
export const TOKEN_FILE_FLAGS = fsConstants.O_WRONLY | fsConstants.O_CREAT | fsConstants.O_EXCL;

export const RUNNERS_PATH = "/api/v1/runners";
export const RUNNER_POOL_PATH = "/api/v1/runners/pool";

export function runnerPath(id) {
  return `${RUNNERS_PATH}/${encodeURIComponent(id)}`;
}

const MISSING_USER_KEY =
  "No user-role API key configured. Set LOOPCTL_USER_KEY to a user-role key to use the " +
  "runner tools (runner_enroll, runner_list, runner_revoke, runner_pool).";

function refuse(body) {
  return { error: true, status: 0, body };
}

/**
 * Expand a leading `~` (alone or followed by a separator) to `homedir`. `~user` forms are
 * left as they are and then refused as relative.
 */
export function expandHome(p, homedir = os.homedir()) {
  if (p === "~") return homedir;
  if (p.startsWith("~/")) return nodePath.join(homedir, p.slice(2));
  return p;
}

/**
 * `POST /api/v1/runners {name, max_sessions?}`, with the returned token written to
 * `token_file` and never returned. Resolves to
 * `{ runner: {id, name, max_sessions, inserted_at}, token_file }` or an
 * `{ error: true, status, body }` shape. It never throws.
 *
 * `max_sessions` is how many dispatches loopctl will keep in flight on this machine at
 * once (loopctl #803). It is sent ONLY when given, so the server's own default applies
 * otherwise, and the server refuses one out of range with a 422 that passes straight
 * through — this does not second-guess the bound.
 */
export async function enrollRunner(
  { name, token_file, max_sessions } = {},
  { userKey, apiCall, fs = defaultFs, homedir = os.homedir() } = {},
) {
  if (!userKey) return refuse(MISSING_USER_KEY);
  if (typeof name !== "string" || name.trim() === "") return refuse("`name` is required.");
  if (typeof token_file !== "string" || token_file.trim() === "") {
    return refuse("`token_file` is required: the path the runner's token is written to (mode 0600).");
  }

  const tokenPath = expandHome(token_file, homedir);
  if (!nodePath.isAbsolute(tokenPath)) {
    return refuse(`token_file must be absolute or start with ~/ (got '${token_file}').`);
  }

  let handle;
  try {
    await fs.mkdir(nodePath.dirname(tokenPath), { recursive: true, mode: TOKEN_DIR_MODE });
    handle = await fs.open(tokenPath, TOKEN_FILE_FLAGS, TOKEN_FILE_MODE);
  } catch (err) {
    if (err?.code === "EEXIST") {
      return refuse(
        `token_file '${tokenPath}' already exists; refusing to overwrite it. Nothing was enrolled. ` +
          "Choose a new path, or remove the file yourself if its runner is revoked.",
      );
    }
    return refuse(
      `Could not create token_file '${tokenPath}' (${err?.code || "error"}). Nothing was enrolled.`,
    );
  }

  // The identity of the file this call created, taken BEFORE anything is written, so the
  // file can still be told apart from a replacement if the handle later becomes unusable.
  let opened;
  try {
    opened = await handle.stat();
  } catch (err) {
    await closeQuietly(handle);
    return refuse(
      `Could not stat the new token_file '${tokenPath}' (${err?.code || "error"}). Nothing was ` +
        "enrolled; an empty file may remain at that path.",
    );
  }

  let result;
  try {
    const body = max_sessions === undefined ? { name } : { name, max_sessions };
    result = await apiCall("POST", RUNNERS_PATH, body);
  } catch {
    result = { error: true, status: 0, body: "Enrollment request failed." };
  }

  // A 4xx is a refusal: nothing was committed, and its body is the server's error, which
  // carries a code the caller needs. Pass it through as it came.
  if (result && result.error === true && result.status >= 400 && result.status < 500) {
    const removed = await discardReservation(fs, handle, tokenPath, opened);
    return removed ? result : { ...result, token_file_not_removed: tokenPath };
  }

  const runner = result && result.error !== true ? result.runner : undefined;
  const token = result && result.error !== true ? result.token : undefined;

  if (!runner || typeof runner.id !== "string" || typeof token !== "string" || token === "") {
    const removed = await discardReservation(fs, handle, tokenPath, opened);
    return ambiguousEnrollment(result, runner, apiCall, tokenPath, removed);
  }

  try {
    await handle.writeFile(token);
    await handle.sync();
    await handle.close();
  } catch (err) {
    const removed = await discardReservation(fs, handle, tokenPath, opened);
    const revoked = await revoke(apiCall, runner.id);
    return refuse(
      `Runner '${runner.name}' (${runner.id}) was enrolled, but its token could not be written ` +
        `to '${tokenPath}' (${err?.code || "error"}). The token cannot be relied on, so ` +
        (revoked.ok
          ? "the runner was revoked. "
          : `revoking the runner FAILED (${revoked.detail}); revoke it with runner_revoke id ` +
            `${runner.id}. `) +
        reservationOutcome(tokenPath, removed),
    );
  }

  // `max_sessions` only when the server sent one, so a server without loopctl #803 returns
  // exactly the shape it always did rather than a key that is always undefined.
  return {
    runner: {
      id: runner.id,
      name: runner.name,
      ...(runner.max_sessions === undefined ? {} : { max_sessions: runner.max_sessions }),
      inserted_at: runner.inserted_at,
    },
    token_file: tokenPath,
  };
}

// Every outcome that is neither a 4xx refusal nor a well-formed enrollment: a timeout, a
// network error, a 5xx from the edge after the commit, a 3xx, or a 2xx whose body did not
// parse or lacks the token. The runner MAY exist, so no response body is ever echoed — a
// 2xx body that failed to parse is the enrollment itself, token included, and apiCall puts
// its first 200 characters in `body`. The runner is revoked only when this response proves
// its id; a runner found by name alone could be an earlier, legitimate enrollment.
async function ambiguousEnrollment(result, runner, apiCall, tokenPath, removed) {
  const status = result && Number.isInteger(result.status) ? result.status : undefined;
  const id = (runner && typeof runner.id === "string" && runner.id) || provenRunnerId(result);

  const what =
    status === 0 && typeof result.body === "string"
      ? `Enrollment outcome unknown (${result.body}).`
      : `Enrollment outcome unknown (HTTP ${status ?? "?"}; response body withheld: it may contain the token).`;

  let next;
  if (id) {
    const revoked = await revoke(apiCall, id);
    next = revoked.ok
      ? `The response identified runner ${id}; it was revoked, since its token cannot be recovered.`
      : `The response identified runner ${id}, but revoking it FAILED (${revoked.detail}); revoke it with runner_revoke.`;
  } else {
    next =
      "The runner may have been enrolled with a token nobody holds. Check runner_list for it " +
      "(an active runner with this name and a new inserted_at) and revoke it with runner_revoke " +
      "before enrolling again.";
  }

  return { error: true, status: status ?? 0, body: `${what} ${next} ${reservationOutcome(tokenPath, removed)}` };
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// The runner id from a 2xx response that did not parse. The id is read from the raw text
// apiCall kept, is required to be a UUID inside the "runner" object, and never leaves this
// function as anything but that UUID.
function provenRunnerId(result) {
  if (!result || result.error !== true || !(result.status >= 200 && result.status < 300)) return null;
  if (typeof result.body !== "string") return null;
  const match = result.body.match(/"runner"\s*:\s*\{[^{}]*?"id"\s*:\s*"([^"]{36})"/);
  return match && UUID.test(match[1]) ? match[1] : null;
}

function reservationOutcome(tokenPath, removed) {
  return removed
    ? `The token_file '${tokenPath}' was removed; the same path can be used again.`
    : `The token_file '${tokenPath}' could NOT be removed: delete it before enrolling again at that path.`;
}

async function revoke(apiCall, id) {
  try {
    const result = await apiCall("DELETE", runnerPath(id), null);
    if (result && result.error) return { ok: false, detail: `status ${result.status}` };
    return { ok: true };
  } catch {
    return { ok: false, detail: "request error" };
  }
}

async function closeQuietly(handle) {
  try {
    await handle.close();
  } catch {
    // already closed, or the close is what failed
  }
}

// Close the handle and remove the file this call created. Removal is by path, so it first
// checks that the path still names the file identified by `opened`, the stat taken right
// after the open. Resolves to whether the path no longer holds that file.
async function discardReservation(fs, handle, tokenPath, opened) {
  await closeQuietly(handle);

  let current;
  try {
    current = await fs.lstat(tokenPath);
  } catch (err) {
    return err?.code === "ENOENT";
  }
  if (current.ino !== opened.ino || current.dev !== opened.dev) return false;

  try {
    await fs.unlink(tokenPath);
    return true;
  } catch (err) {
    return err?.code === "ENOENT";
  }
}

/** `GET /api/v1/runners`, optionally with revoked runners. */
export async function listRunners({ include_revoked } = {}, { userKey, apiCall } = {}) {
  if (!userKey) return refuse(MISSING_USER_KEY);
  const query = include_revoked ? "?include_revoked=true" : "";
  return apiCall("GET", `${RUNNERS_PATH}${query}`, null);
}

/** `DELETE /api/v1/runners/:id`: revokes the runner and disconnects its live socket. */
export async function revokeRunner({ id } = {}, { userKey, apiCall } = {}) {
  if (!userKey) return refuse(MISSING_USER_KEY);
  if (typeof id !== "string" || id.trim() === "") return refuse("`id` is required.");
  return apiCall("DELETE", runnerPath(id), null);
}

/** `GET /api/v1/runners/pool`: the tenant's connected runners, from Presence. */
export async function runnerPool(_args = {}, { userKey, apiCall } = {}) {
  if (!userKey) return refuse(MISSING_USER_KEY);
  return apiCall("GET", RUNNER_POOL_PATH, null);
}
