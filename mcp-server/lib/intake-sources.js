/**
 * GitHub intake sources — `/api/v1/intake/sources` (loopctl #803, #846).
 *
 * ## The defect these exist for
 *
 * loopctl's agent delivery loop is built end to end — webhook intake, triage, the stage
 * machine, placement, the unattended driver — and until these tools it had never received a
 * GitHub issue, because nothing outside the app could create the one row that makes a
 * webhook possible. All five intake-source routes were declared `gap` in
 * `test/route_coverage.test.js`: no tool reached any of them, and `claude-config`'s
 * `hooks/orchestrator-guardrail.sh` refuses a `curl` carrying `loopctl.com` from every
 * session on the fleet, deliberately. So the loop's own wiring step was reachable by a human
 * with `iex` on the production node and by nothing else — loopctl's "an operator-facing
 * endpoint is not done until an MCP tool calls it" failing at the step the whole loop starts
 * from.
 *
 * An intake source does two things, and the second is why `place_dispatch` cares:
 *
 *   1. It mints the webhook secret and names the URL GitHub must POST to, so issues from one
 *      repository reach one project's queue.
 *   2. It BINDS that project to a `repo_full_name` and a `base_branch`, which is where
 *      `Loopctl.Delivery.DispatchPayload` reads the repository and trunk from. A project
 *      bound to none is the `409 no_intake_source` refusal; bound to two, the `409
 *      ambiguous_intake_source` one.
 *
 * ## THE SECRET IS NEVER RETURNED BY THESE TOOLS
 *
 * `POST /api/v1/intake/sources` returns `webhook_secret` ONCE. It cannot be re-read: the
 * column is `Loopctl.Vault.Binary` with `redact: true` and is absent from the schema's
 * `@derive {Jason.Encoder, only: [...]}` list (`lib/loopctl/intake/source.ex`), so neither
 * the list nor the update response carries it. Lose it and the only remedy is to revoke the
 * source, enrol again, and reconfigure the GitHub webhook.
 *
 * A tool result is JSON-stringified into the session transcript AND the audit log, so this
 * follows what `runner_enroll` already does with the runner credential (`lib/runners.js`):
 * `secret_file` is REQUIRED, the secret is written there with mode 0600, and the tool returns
 * the source row, the webhook URL and the path. The secret reaches GitHub from the file —
 * `config[secret]=$(cat <file>)` — so it never has to pass through a transcript at all.
 *
 * The file is RESERVED (`O_CREAT|O_EXCL`, 0600) before the API is called, so an existing path
 * or an unwritable directory is refused while there is still nothing to lose. Every outcome
 * that is not a clean 2xx of the expected shape withholds the response body, because a 2xx
 * whose JSON failed to parse reaches this code as `{error: true, status: 201, body: "<first
 * 200 characters of the raw text>"}` — which is the secret.
 *
 * ## WHERE THIS DELIBERATELY DOES LESS THAN `runner_enroll`
 *
 * `enrollRunner` scrapes the runner id out of an unparseable 2xx body so it can revoke what
 * it cannot identify by name — a runner found by NAME alone might be an earlier, legitimate
 * enrollment. An intake source needs no such scraping: `intake_sources_active_repo_uidx` is
 * unique on `(tenant_id, repo_full_name)` WHERE `revoked_at IS NULL`, so at most one ACTIVE
 * source ever binds a repository and `intake_source_list` identifies it exactly. The
 * ambiguous branch therefore names that pair of tools instead of guessing at an id.
 *
 * A source whose secret nobody holds is also INERT rather than dangerous: no delivery can
 * ever be signed for it, so every POST to its URL is refused `401 invalid_signature`. What it
 * does cost is that unique slot — a second enrolment of the same repository is refused 422
 * until it is revoked — which is why a write failure after a successful create revokes it
 * here rather than leaving it.
 *
 * ## KEY
 *
 * `LOOPCTL_USER_KEY`, for all four, pinned exactly (`exactKey`) the way the `runner_*` family
 * is. The controller mounts `RequireRole, role: :user` — the HIERARCHY form, so a
 * `:superadmin` key would pass too and this package holds no such variable — plus
 * `RequireHumanAnchor` on create/update/delete and `RequireUnlineagedCaller` on create
 * (`lib/loopctl_web/controllers/intake_source_controller.ex:27-29`). That last one is why a
 * global `LOOPCTL_API_KEY` must not stand in: creating a source MINTS A CREDENTIAL that
 * belongs to no dispatch lineage, so a caller whose own key a dispatch minted is refused
 * `403 api_key_mint_forbidden`, exactly as it is on `POST /api/v1/api_keys`.
 *
 * ## `repo_full_name` IS NOT SHAPE-CHECKED HERE, AND THAT IS A DECISION
 *
 * The server's refusal is a 422 naming the field with `must be owner/name`, which is
 * unambiguous and needs no client to disambiguate it — unlike the UUID checks below, which
 * exist because a malformed path id and an unknown one produce the SAME 404
 * (the long comment over `uuid()` in `lib/delivery-loop.js` has the trace). Mirroring
 * `Source.repo_format/0` here would put a second copy of that regex in a second language,
 * free to drift, to catch a refusal the server already words better.
 */

import nodePath from "node:path";
import os from "node:os";
import defaultFs from "node:fs/promises";

import { uuid as uuidRefusal } from "./delivery-loop.js";
import { expandHome, TOKEN_DIR_MODE, TOKEN_FILE_FLAGS, TOKEN_FILE_MODE } from "./runners.js";

export const SOURCES_PATH = "/api/v1/intake/sources";

const MISSING_USER_KEY =
  "No user-role API key configured. Set LOOPCTL_USER_KEY to a user-role key to use the " +
  "intake-source tools (intake_source_enroll, intake_source_list, intake_source_update, " +
  "intake_source_revoke). The create path additionally requires a key NO DISPATCH MINTED — " +
  "it mints the webhook secret, which belongs to no lineage — so an ephemeral dispatch key " +
  "is refused 403 api_key_mint_forbidden however privileged it is.";

function refuse(body) {
  return { error: true, status: 0, body };
}

export function sourcePath(sourceId) {
  return `${SOURCES_PATH}/${encodeURIComponent(sourceId)}`;
}

/**
 * The absolute URL to configure on the GitHub webhook, from the `webhook_path` the server
 * returned. The path is joined to the server this process is talking to, because a webhook
 * pointed at a different host than the one holding the source is a delivery that can never
 * authenticate.
 */
export function webhookUrl(baseUrl, webhookPath) {
  const base = typeof baseUrl === "string" ? baseUrl.replace(/\/+$/, "") : "";
  return `${base}${webhookPath}`;
}

/**
 * `POST /api/v1/intake/sources` — bind a GitHub repository to a work project and write the
 * webhook secret to `secret_file`, never returning it.
 *
 * Resolves to `{ source, webhook_url, secret_file }` or an `{ error: true, status, body }`
 * shape. It never throws.
 */
export async function enrollIntakeSource(
  { repo_full_name, project_id, target_epic_id, secret_file } = {},
  { userKey, apiCall, baseUrl, fs = defaultFs, homedir = os.homedir() } = {},
) {
  if (!userKey) return refuse(MISSING_USER_KEY);

  if (typeof repo_full_name !== "string" || repo_full_name.trim() === "") {
    return refuse(
      "`repo_full_name` is required: the repository as `owner/name`, e.g. " +
        "`mkreyman/home_care_billing`. Not a URL.",
    );
  }

  const badProject = uuidRefusal(project_id, "project_id");
  if (badProject) return badProject;

  // OPTIONAL. Absent means the question has not been answered, and a report from a source
  // that names no epic is ESCALATED to a human rather than landing in an epic chosen for it
  // (`lib/loopctl/intake/source.ex`). An explicit null means the same thing on create.
  if (target_epic_id !== undefined && target_epic_id !== null) {
    const badEpic = uuidRefusal(target_epic_id, "target_epic_id");
    if (badEpic) return badEpic;
  }

  if (typeof secret_file !== "string" || secret_file.trim() === "") {
    return refuse(
      "`secret_file` is required: the path the webhook secret is written to (mode 0600). " +
        "The server returns that secret ONCE and it can never be read again, and a tool " +
        "result lands in the session transcript and the audit log — so it is written to a " +
        "file instead, and GitHub is configured from that file.",
    );
  }

  const secretPath = expandHome(secret_file, homedir);
  if (!nodePath.isAbsolute(secretPath)) {
    return refuse(`secret_file must be absolute or start with ~/ (got '${secret_file}').`);
  }

  let handle;
  try {
    await fs.mkdir(nodePath.dirname(secretPath), { recursive: true, mode: TOKEN_DIR_MODE });
    handle = await fs.open(secretPath, TOKEN_FILE_FLAGS, TOKEN_FILE_MODE);
  } catch (err) {
    if (err?.code === "EEXIST") {
      return refuse(
        `secret_file '${secretPath}' already exists; refusing to overwrite it. Nothing was ` +
          "enrolled. Choose a new path, or remove the file yourself if its source is revoked.",
      );
    }
    return refuse(
      `Could not create secret_file '${secretPath}' (${err?.code || "error"}). Nothing was ` +
        "enrolled.",
    );
  }

  // The identity of the file this call created, taken BEFORE anything is written, so the file
  // can still be told apart from a replacement if the handle later becomes unusable.
  let opened;
  try {
    opened = await handle.stat();
  } catch (err) {
    await closeQuietly(handle);
    return refuse(
      `Could not stat the new secret_file '${secretPath}' (${err?.code || "error"}). Nothing ` +
        "was enrolled; an empty file may remain at that path.",
    );
  }

  const body = { repo_full_name, project_id };
  if (target_epic_id !== undefined && target_epic_id !== null) {
    body.target_epic_id = target_epic_id;
  }

  let result;
  try {
    result = await apiCall("POST", SOURCES_PATH, body);
  } catch {
    result = { error: true, status: 0, body: "Intake-source request failed." };
  }

  // A 4xx is a refusal: nothing was committed, and its body is the server's error, which
  // carries the code the caller needs. Pass it through as it came.
  if (result && result.error === true && result.status >= 400 && result.status < 500) {
    const removed = await discardReservation(fs, handle, secretPath, opened);
    return removed ? result : { ...result, secret_file_not_removed: secretPath };
  }

  const source = result && result.error !== true ? result.source : undefined;
  const secret = result && result.error !== true ? result.webhook_secret : undefined;
  const webhookPath = result && result.error !== true ? result.webhook_path : undefined;

  if (
    !source ||
    typeof source.id !== "string" ||
    typeof secret !== "string" ||
    secret === "" ||
    typeof webhookPath !== "string"
  ) {
    const removed = await discardReservation(fs, handle, secretPath, opened);
    return ambiguousEnrollment(result, repo_full_name, secretPath, removed);
  }

  try {
    await handle.writeFile(secret);
    await handle.sync();
    await handle.close();
  } catch (err) {
    const removed = await discardReservation(fs, handle, secretPath, opened);
    const revoked = await revoke(apiCall, source.id);
    return refuse(
      `The intake source for '${repo_full_name}' (${source.id}) was created, but its webhook ` +
        `secret could not be written to '${secretPath}' (${err?.code || "error"}). The secret ` +
        "is returned once and cannot be re-read, so the source is unusable and " +
        (revoked.ok
          ? "was revoked. "
          : `revoking it FAILED (${revoked.detail}); revoke it with intake_source_revoke ` +
            `source_id ${source.id} — until you do, a second source for this repository is ` +
            "refused 422. ") +
        reservationOutcome(secretPath, removed),
    );
  }

  return {
    source,
    webhook_url: webhookUrl(baseUrl, webhookPath),
    secret_file: secretPath,
  };
}

/**
 * Every outcome that is neither a 4xx refusal nor a well-formed creation: a timeout, a
 * network error, a 5xx from the edge after the commit, or a 2xx whose body did not parse or
 * lacks the secret. NO RESPONSE BODY IS EVER ECHOED — a 2xx body that failed to parse is the
 * creation itself, secret included, and `apiCall` puts its first 200 characters in `body`.
 *
 * The recovery names the tools rather than an id, because it can: an ACTIVE source is unique
 * per repository (`intake_sources_active_repo_uidx`), so the list identifies it exactly.
 */
function ambiguousEnrollment(result, repoFullName, secretPath, removed) {
  const status = result && Number.isInteger(result.status) ? result.status : undefined;

  const what =
    status === 0 && typeof result.body === "string"
      ? `Intake-source outcome unknown (${result.body}).`
      : `Intake-source outcome unknown (HTTP ${status ?? "?"}; response body withheld: it may ` +
        "contain the webhook secret).";

  return {
    error: true,
    status: status ?? 0,
    body:
      `${what} A source for '${repoFullName}' may exist with a secret nobody holds — it can ` +
      "never authenticate a delivery, and it holds that repository's unique slot, so a second " +
      "enrolment is refused 422 until it is gone. Run intake_source_list, and revoke any " +
      `active source for '${repoFullName}' with intake_source_revoke before enrolling again. ` +
      reservationOutcome(secretPath, removed),
  };
}

/** `GET /api/v1/intake/sources`, optionally including revoked ones. */
export async function listIntakeSources({ include_revoked } = {}, { userKey, apiCall } = {}) {
  if (!userKey) return refuse(MISSING_USER_KEY);
  const query = include_revoked ? "?include_revoked=true" : "";
  return apiCall("GET", `${SOURCES_PATH}${query}`, null);
}

/**
 * `PATCH /api/v1/intake/sources/:id` — set the epic triaged stories land in, and/or the
 * branch dispatches for this repository are cut from.
 *
 * PRESENCE DECIDES, on both fields, and the controller reads it with `Map.fetch/2`
 * (`intake_source_controller.ex:243-247`): a field you do not send is left exactly as it was.
 * So `undefined` here means "not named" and is omitted from the body.
 *
 * `target_epic_id: null` IS FORWARDED, because null is the endpoint's only way to clear the
 * target and clearing it is a real operation — a source that names no epic escalates every
 * report to a human instead of filing a story. That is the opposite of `update_story`, which
 * refuses a null because the server would drop it and answer 200 having changed nothing
 * (`lib/story-update.js`). The hazard is on the caller and the description says so in the
 * imperative: do not send `target_epic_id: null` to mean "I am not changing this".
 *
 * `base_branch: null` is refused here. It is NOT nullable — every `implement` dispatch must
 * name a branch to cut from, so there is no unanswered state for it — and the server's cast
 * uses `empty_values: []` precisely so that a caller who SENT a value gets an answer about
 * the value it sent, which is a 422.
 */
export async function updateIntakeSource(args = {}, { userKey, apiCall } = {}) {
  if (!userKey) return refuse(MISSING_USER_KEY);

  const bad = uuidRefusal(args.source_id, "source_id");
  if (bad) return bad;

  const body = {};

  if (args.target_epic_id !== undefined) {
    if (args.target_epic_id !== null) {
      const badEpic = uuidRefusal(args.target_epic_id, "target_epic_id");
      if (badEpic) return badEpic;
    }
    body.target_epic_id = args.target_epic_id;
  }

  if (args.base_branch !== undefined) {
    if (args.base_branch === null) {
      return refuse(
        "`base_branch` cannot be null: every dispatch must name a branch to cut from, so " +
          "there is no cleared state for it and the server answers 422. Send the branch you " +
          "want (`master`, `main`, …), or leave the field out to keep the current one.",
      );
    }
    body.base_branch = args.base_branch;
  }

  if (Object.keys(body).length === 0) {
    return refuse(
      "Nothing to update. Name at least one of `target_epic_id` (null clears it) or " +
        "`base_branch`. A body carrying neither is refused 422 `nothing_to_update`, because a " +
        "field you do not send is left exactly as it was.",
    );
  }

  return apiCall("PATCH", sourcePath(args.source_id), body);
}

/**
 * `DELETE /api/v1/intake/sources/:id` — REVOKE the source. The row is kept.
 *
 * Named for what it does rather than for its HTTP verb: `Loopctl.Intake.revoke_source/3` sets
 * `revoked_at`, clears `target_epic_id` and appends an `intake_source_revoked` audit entry.
 * Nothing is destroyed, deliveries already received are kept, and the row still comes back
 * from `intake_source_list` with `include_revoked`.
 */
export async function revokeIntakeSource({ source_id } = {}, { userKey, apiCall } = {}) {
  if (!userKey) return refuse(MISSING_USER_KEY);

  const bad = uuidRefusal(source_id, "source_id");
  if (bad) return bad;

  return apiCall("DELETE", sourcePath(source_id), null);
}

async function revoke(apiCall, sourceId) {
  try {
    const result = await apiCall("DELETE", sourcePath(sourceId), null);
    if (result && result.error) return { ok: false, detail: `status ${result.status}` };
    return { ok: true };
  } catch {
    return { ok: false, detail: "request error" };
  }
}

function reservationOutcome(secretPath, removed) {
  return removed
    ? `The secret_file '${secretPath}' was removed; the same path can be used again.`
    : `The secret_file '${secretPath}' could NOT be removed: delete it before enrolling again ` +
        "at that path.";
}

async function closeQuietly(handle) {
  try {
    await handle.close();
  } catch {
    // already closed, or the close is what failed
  }
}

/**
 * Close the handle and remove the file this call created. Removal is by path, so it first
 * checks that the path still names the file identified by `opened`, the stat taken right
 * after the open. Resolves to whether the path no longer holds that file.
 */
async function discardReservation(fs, handle, secretPath, opened) {
  await closeQuietly(handle);

  let current;
  try {
    current = await fs.lstat(secretPath);
  } catch (err) {
    return err?.code === "ENOENT";
  }
  if (current.ino !== opened.ino || current.dev !== opened.dev) return false;

  try {
    await fs.unlink(secretPath);
    return true;
  } catch (err) {
    return err?.code === "ENOENT";
  }
}
