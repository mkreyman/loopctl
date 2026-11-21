/**
 * `work_item_open` and the heartbeat's branch open (loopctl US-52.18): an interactive
 * session's branch becomes a work item it holds — `POST /api/v1/work_items`.
 *
 * KEY: the session's holder credential. The route refuses any other key 403
 * holder_credential_required, so the automatic open runs only while this process holds one.
 *
 * ## The automatic open
 *
 * On each holder heartbeat this reads the worktree's branch through an injected git runner.
 * When the branch is neither the remote's default branch nor a detached HEAD, and this holder
 * has not opened it yet, it calls the route once. What it remembers is per HOLDER: a session
 * that re-registers as a new holder opens its branch again, which loopctl answers by taking
 * the unheld item back. A 409 branch_held (another session's item) and any other refusal the
 * server will repeat (4xx) are logged to stderr and not retried for that branch; a network
 * error, a 429 or a 5xx is retried on the next heartbeat. Nothing is created locally, and the
 * open is idempotent on the server, so a lost response costs one repeated call.
 */

export const WORK_ITEMS_PATH = "/api/v1/work_items";

function refuse(body) {
  return { error: true, status: 0, body };
}

function present(value) {
  return typeof value === "string" && value.trim() !== "";
}

/** `POST /api/v1/work_items`: open (or reopen) the item for a branch. */
export async function openWorkItem({ repo_url, branch, title, epic_id } = {}, { apiCall } = {}) {
  if (!present(repo_url)) return refuse("`repo_url` is required: the repo's remote URL.");
  if (!present(branch)) return refuse("`branch` is required: the branch the work is on.");
  if (title !== undefined && title !== null && typeof title !== "string") {
    return refuse("`title` must be a string.");
  }
  if (epic_id !== undefined && epic_id !== null && typeof epic_id !== "string") {
    return refuse("`epic_id` must be a UUID string.");
  }

  const payload = { repo_url, branch };
  if (present(title)) payload.title = title;
  if (present(epic_id)) payload.epic_id = epic_id;
  return apiCall("POST", WORK_ITEMS_PATH, payload);
}

// A refusal the server will give again for the same branch: not retried.
function final(result) {
  if (!result || !result.error) return true;
  const status = Number(result.status) || 0;
  return status >= 400 && status < 500 && status !== 408 && status !== 429;
}

/**
 * @param {{
 *   apiCall: Function,          // (method, path, body, key, opts) => result
 *   git: (args: string[]) => Promise<string|null>,  // stdout trimmed, null on failure
 *   worktree: () => string,
 *   log?: (line: string) => void,
 * }} deps
 */
export function createBranchItemOpener(deps) {
  const { apiCall, git, worktree, log = (line) => process.stderr.write(line + "\n") } = deps;
  let holderId = null;
  let done = new Set();

  async function defaultBranch(wt) {
    const ref = await git(["-C", wt, "symbolic-ref", "refs/remotes/origin/HEAD"]);
    return present(ref) ? ref.trim().replace(/^refs\/remotes\/origin\//, "") : null;
  }

  /**
   * One heartbeat's look at the worktree. `holder` is the live holder, `credential` its raw
   * key. Returns what it did: "skipped", "opened", "refused" or "retry".
   */
  async function tick(holder, credential) {
    if (!holder || !credential) return "skipped";
    if (holder.id !== holderId) {
      holderId = holder.id;
      done = new Set();
    }

    const wt = worktree();
    const branch = ((await git(["-C", wt, "rev-parse", "--abbrev-ref", "HEAD"])) || "").trim();
    if (branch === "" || branch === "HEAD" || done.has(branch)) return "skipped";

    const fallbackDefaults = ["main", "master"];
    const known = await defaultBranch(wt);
    if (known ? branch === known : fallbackDefaults.includes(branch)) return "skipped";

    const repoUrl = ((await git(["-C", wt, "remote", "get-url", "origin"])) || "").trim();
    if (repoUrl === "") return "skipped";

    const result = await openWorkItem(
      { repo_url: repoUrl, branch },
      { apiCall: (method, path, body) => apiCall(method, path, body, credential, { exactKey: true }) },
    );

    if (!final(result)) return "retry";
    done.add(branch);
    if (result && result.error) {
      const code = result.body && result.body.error ? result.body.error.code : result.status;
      log(`loopctl: work item for branch ${branch} not opened (${code}); not retrying it`);
      return "refused";
    }
    return "opened";
  }

  return { tick };
}
