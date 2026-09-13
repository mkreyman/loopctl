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
 * `POST /api/v1/runners {name}`, with the returned token written to `token_file` and
 * never returned. Resolves to `{ runner: {id, name, inserted_at}, token_file }` or an
 * `{ error: true, status, body }` shape. It never throws.
 */
export async function enrollRunner(
  { name, token_file } = {},
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

  let result;
  try {
    result = await apiCall("POST", RUNNERS_PATH, { name });
  } catch {
    result = { error: true, status: 0, body: "Enrollment request failed." };
  }

  const runner = result && !result.error ? result.runner : undefined;
  const token = result && !result.error ? result.token : undefined;

  if (!runner || typeof runner.id !== "string" || typeof token !== "string" || token === "") {
    await discardReservation(fs, handle, tokenPath);

    if (result && result.error) {
      // A 4xx body carries the server's error code and never a token. A status-0 failure
      // (timeout, network) may have enrolled the runner without our seeing its id.
      if (result.status === 0) {
        return {
          ...result,
          body:
            `${typeof result.body === "string" ? result.body : "Request failed"}. If the ` +
            "enrollment reached the server its token is lost: find it with runner_list and " +
            "revoke it with runner_revoke.",
        };
      }
      return result;
    }

    // A success with the wrong shape. Never echo the body: it may hold the token.
    const revoked = runner && typeof runner.id === "string" ? await revoke(apiCall, runner.id) : null;
    return refuse(
      "Enrollment returned an unexpected response (body withheld: it may contain the token). " +
        (revoked === null
          ? "Check runner_list for a runner you did not intend and revoke it."
          : revoked.ok
            ? `Runner ${runner.id} was revoked.`
            : `Revoking runner ${runner.id} FAILED (${revoked.detail}); revoke it with runner_revoke.`),
    );
  }

  try {
    await handle.writeFile(token);
    await handle.sync();
    await handle.close();
  } catch (err) {
    await discardReservation(fs, handle, tokenPath);
    const revoked = await revoke(apiCall, runner.id);
    return refuse(
      `Runner '${runner.name}' (${runner.id}) was enrolled, but its token could not be written ` +
        `to '${tokenPath}' (${err?.code || "error"}). The token cannot be recovered, so ` +
        (revoked.ok
          ? "the runner was revoked. Fix the path and enroll again."
          : `revoking the runner FAILED (${revoked.detail}); revoke it with runner_revoke id ` +
            `${runner.id} before enrolling again.`),
    );
  }

  return {
    runner: { id: runner.id, name: runner.name, inserted_at: runner.inserted_at },
    token_file: tokenPath,
  };
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

// Close and remove the file this call created. Removal is by path, so it first checks
// that the path still names the file this handle opened.
async function discardReservation(fs, handle, tokenPath) {
  let opened;
  try {
    opened = await handle.stat();
  } catch {
    opened = null;
  }
  try {
    await handle.close();
  } catch {
    // already closed, or the close is what failed
  }
  try {
    const current = await fs.lstat(tokenPath);
    if (opened && current.ino === opened.ino && current.dev === opened.dev) {
      await fs.unlink(tokenPath);
    }
  } catch {
    // gone already, or unreadable; nothing further is safe to do
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
