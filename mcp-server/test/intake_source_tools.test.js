/**
 * The GitHub intake-source tools: enroll, list, update, revoke.
 *
 * WHY THEY EXIST, and therefore what these tests are really about: loopctl's delivery loop
 * was complete end to end and had never received a GitHub issue, because the row a webhook
 * needs could be created by nothing outside the app. All five `/api/v1/intake/sources` routes
 * were declared `gap` in `route_coverage.test.js`, and the fleet's own guardrail refuses a
 * `curl` at loopctl from every session — so the loop's wiring step was reachable by a human
 * with `iex` on the production node and by nothing else.
 *
 * THE PROPERTY THIS FILE EXISTS FOR IS THE SECRET. `POST /api/v1/intake/sources` returns
 * `webhook_secret` ONCE and no other endpoint can ever re-read it (`redact: true`, absent from
 * the schema's Jason encoder). A tool result is stringified into the session transcript and
 * the audit log, so the secret is written to a 0600 file and never returned — the same
 * handling `runner_enroll` gives a runner credential. Several tests below assert the absence
 * of bytes rather than the presence of a value, which is unusual and deliberate: the failure
 * they guard against is a secret appearing somewhere, and only a scan of the whole serialised
 * result can see that.
 *
 * Run: node --test test/*.test.js
 */

import { test, describe, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  SOURCES_PATH,
  enrollIntakeSource,
  listIntakeSources,
  revokeIntakeSource,
  sourcePath,
  updateIntakeSource,
  webhookUrl,
} from "../lib/intake-sources.js";
import { loadTools, stripComments } from "./tool-surface.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");
const README = readFileSync(path.join(DIR, "..", "README.md"), "utf8");
const DISPATCH_SRC = stripComments(INDEX_SRC);

const SOURCE_ID = "9f2a1c44-6d3e-4f8b-9a21-77c0e5b1d0aa";
const PROJECT_ID = "3781bee6-2b97-4df0-9664-7f01a492630f";
const EPIC_ID = "d9975b31-032d-4f44-b154-c48af09640c7";
const REPO = "mkreyman/home_care_billing";
// 64 characters, like the real HMAC secret, so the length-sensitive paths see the same shape
// — but SELF-DESCRIBING and low-entropy on purpose. The previous fixture was 64 hex digits (a
// walking pattern repeated twice), which is obviously synthetic to a human and indistinguishable
// from a live webhook secret to a scanner: GitGuardian scored it as high entropy and failed the
// check. A fixture that says what it is costs nothing here, because every assertion this file
// makes about the secret turns on the string being DISTINCTIVE and never on it looking real.
const SECRET = "NOT-A-SECRET-fake-webhook-hmac-for-tests-only-000000000000000000";

let tmpdir;

beforeEach(async () => {
  tmpdir = await fs.mkdtemp(path.join(os.tmpdir(), "loopctl-intake-"));
});

afterEach(async () => {
  await fs.rm(tmpdir, { recursive: true, force: true });
});

// THE FAKE SOURCE CARRIES THE SECRET, deliberately, and every test that scans a result for
// SECRET depends on it. The server's `@derive {Jason.Encoder, only: [...]}` excludes
// `webhook_secret` today, so a fake mirroring the server exactly would put the secret ONLY at
// the top level — and the "appears NOWHERE in the result" tests would pass against a client
// that echoes the source object verbatim, which is precisely the channel they exist to close.
// The fake therefore models the server AFTER the widening the client must survive: one commit
// adding the field back to that list, or adding one derived from it.
function created(overrides = {}) {
  return {
    source: {
      id: SOURCE_ID,
      project_id: PROJECT_ID,
      repo_full_name: REPO,
      base_branch: "master",
      target_epic_id: null,
      revoked_at: null,
      inserted_at: "2026-09-16T00:00:00Z",
      webhook_secret: SECRET,
    },
    webhook_secret: SECRET,
    webhook_path: `/api/v1/intake/github/${SOURCE_ID}`,
    ...overrides,
  };
}

function fakeApi(...responses) {
  const calls = [];
  const queue = [...responses];
  const apiCall = async (method, apiPath, body) => {
    calls.push({ method, path: apiPath, body });
    return queue.length > 1 ? queue.shift() : (queue[0] ?? { ok: true });
  };
  return { calls, apiCall };
}

function deps(extra = {}) {
  return {
    userKey: "user-key",
    baseUrl: "https://loopctl.com",
    homedir: "/home/nobody",
    ...extra,
  };
}

const secretFileIn = (name = "intake.secret") => path.join(tmpdir, name);

describe("intake_source_enroll", () => {
  test("POSTs the binding and writes the secret to a new 0600 file, returning only the path", async () => {
    const { calls, apiCall } = fakeApi(created());
    const secret_file = secretFileIn();

    const result = await enrollIntakeSource(
      { repo_full_name: REPO, project_id: PROJECT_ID, secret_file },
      deps({ apiCall }),
    );

    assert.equal(calls.length, 1);
    assert.equal(calls[0].method, "POST");
    assert.equal(calls[0].path, "/api/v1/intake/sources");
    assert.deepEqual(calls[0].body, { repo_full_name: REPO, project_id: PROJECT_ID });

    assert.equal(result.secret_file, secret_file);
    assert.equal(result.webhook_url, `https://loopctl.com/api/v1/intake/github/${SOURCE_ID}`);
    assert.equal(result.source.id, SOURCE_ID);

    assert.equal(await fs.readFile(secret_file, "utf8"), SECRET);
    const mode = (await fs.stat(secret_file)).mode & 0o777;
    assert.equal(mode, 0o600, `secret_file mode is ${mode.toString(8)}, not 600`);
  });

  test("the secret appears NOWHERE in the serialised result", async () => {
    // The whole point of the file. `toContent` JSON-stringifies whatever this resolves to
    // straight into the tool output, so a scan of the serialised object is the only check
    // that can see a secret carried in a field nobody thought about.
    const fake = created();

    // THE PRECONDITION THAT MAKES THE SCAN BELOW MEAN ANYTHING, asserted rather than assumed:
    // with the secret only at the top level, this test passes against a client that echoes
    // the source object verbatim — which is the channel it exists to close. A later edit that
    // quietly "tidies" the fake to mirror today's server would silently defeat it.
    assert.equal(fake.source.webhook_secret, SECRET);

    const { apiCall } = fakeApi(fake);

    const result = await enrollIntakeSource(
      { repo_full_name: REPO, project_id: PROJECT_ID, secret_file: secretFileIn() },
      deps({ apiCall }),
    );

    assert.ok(!JSON.stringify(result).includes(SECRET), "the webhook secret is in the result");

    // AND THE SOURCE IS BUILT FROM NAMED FIELDS, not echoed. The assertion above is the one
    // that matters, but it can only see the leak because the fake's source carries the secret
    // — so this pins the mechanism that makes it survivable: a field the server grows is not
    // in the result at all, whatever it is called.
    assert.deepEqual(Object.keys(result.source).sort(), [
      "base_branch",
      "id",
      "inserted_at",
      "mode",
      "project_id",
      "repo_full_name",
      "revoked_at",
      "target_epic_id",
      "updated_at",
    ]);
  });

  test("a 2xx with the source and secret but NO webhook_path is recovered, not thrown away", async () => {
    // The enrolment is COMPLETE at the server and the secret is in hand — and the secret is
    // returned once, so discarding this costs the one thing that cannot be re-fetched. The
    // path is a pure function of the id, so it is derived and the result says so.
    const { calls, apiCall } = fakeApi(created({ webhook_path: undefined }));
    const secret_file = secretFileIn();

    const result = await enrollIntakeSource(
      { repo_full_name: REPO, project_id: PROJECT_ID, secret_file },
      deps({ apiCall }),
    );

    assert.equal(result.error, undefined, `the enrolment was discarded: ${result.body}`);
    assert.equal(result.webhook_url, `https://loopctl.com/api/v1/intake/github/${SOURCE_ID}`);
    assert.equal(result.webhook_url_derived, true);
    assert.equal(await fs.readFile(secret_file, "utf8"), SECRET);
    assert.equal(calls.length, 1, "nothing was revoked: the enrolment is usable");
    assert.ok(!JSON.stringify(result).includes(SECRET), "the recovered result leaked the secret");
  });

  test("a server-sent webhook_path always wins over the derived one", async () => {
    const { apiCall } = fakeApi(created({ webhook_path: "/api/v1/intake/github/elsewhere" }));

    const result = await enrollIntakeSource(
      { repo_full_name: REPO, project_id: PROJECT_ID, secret_file: secretFileIn() },
      deps({ apiCall }),
    );

    assert.equal(result.webhook_url, "https://loopctl.com/api/v1/intake/github/elsewhere");
    assert.equal(result.webhook_url_derived, undefined);
  });

  test("a 2xx that proves an id but carries no secret REVOKES the source it named", async () => {
    // Unrecoverable: the secret is returned once, so this source can never authenticate a
    // delivery, and it holds the repository's unique slot until it is revoked. Telling the
    // operator to do that by hand asked them for something this process had already proved.
    const { calls, apiCall } = fakeApi(created({ webhook_secret: undefined }), { ok: true });

    const result = await enrollIntakeSource(
      { repo_full_name: REPO, project_id: PROJECT_ID, secret_file: secretFileIn() },
      deps({ apiCall }),
    );

    assert.equal(result.error, true);
    assert.equal(calls.length, 2);
    assert.equal(calls[1].method, "DELETE");
    assert.equal(calls[1].path, `/api/v1/intake/sources/${SOURCE_ID}`);
    assert.match(result.body, /it was revoked/);
    assert.ok(!JSON.stringify(result).includes(SECRET));
  });

  test("a failed revoke of a proven id names the id and the tool, and does not claim success", async () => {
    const { apiCall } = fakeApi(created({ webhook_secret: undefined }), {
      error: true,
      status: 500,
    });

    const result = await enrollIntakeSource(
      { repo_full_name: REPO, project_id: PROJECT_ID, secret_file: secretFileIn() },
      deps({ apiCall }),
    );

    assert.match(result.body, /revoking it FAILED/);
    assert.match(result.body, new RegExp(`intake_source_revoke source_id ${SOURCE_ID}`));
  });

  test("with NO id proved, the recovery still names the list-and-revoke pair", async () => {
    // The unparseable-body case, where there is nothing to revoke BY id: active sources are
    // unique per repository, so the listing identifies it exactly.
    const { calls, apiCall } = fakeApi({ error: true, status: 201, body: "{partial" });

    const result = await enrollIntakeSource(
      { repo_full_name: REPO, project_id: PROJECT_ID, secret_file: secretFileIn() },
      deps({ apiCall }),
    );

    assert.equal(calls.length, 1, "nothing may be revoked when no id was proved");
    assert.match(result.body, /intake_source_list/);
    assert.match(result.body, /intake_source_revoke/);
  });

  test("a BLANK target_epic_id is refused as optional, never as required", async () => {
    // `uuid()` answers "`target_epic_id` is required" for a blank, which is the opposite of
    // the truth: a model that cannot emit a JSON null sends "" to mean the clear, is told the
    // optional field is required, and its next move is to invent an epic id — a WRONG epic
    // instead of a refused call.
    const { calls, apiCall } = fakeApi(created());

    const result = await enrollIntakeSource(
      {
        repo_full_name: REPO,
        project_id: PROJECT_ID,
        target_epic_id: "  ",
        secret_file: secretFileIn(),
      },
      deps({ apiCall }),
    );

    assert.match(result.body, /`target_epic_id` is OPTIONAL/);
    assert.ok(!/is required/.test(result.body), `refused as required: ${result.body}`);
    assert.match(result.body, /Leave the field out entirely/);
    assert.equal(calls.length, 0);
  });

  test("sends target_epic_id only when given", async () => {
    const { calls, apiCall } = fakeApi(created());

    await enrollIntakeSource(
      { repo_full_name: REPO, project_id: PROJECT_ID, secret_file: secretFileIn("a") },
      deps({ apiCall }),
    );
    assert.deepEqual(Object.keys(calls[0].body).sort(), ["project_id", "repo_full_name"]);

    await enrollIntakeSource(
      {
        repo_full_name: REPO,
        project_id: PROJECT_ID,
        target_epic_id: EPIC_ID,
        secret_file: secretFileIn("b"),
      },
      deps({ apiCall }),
    );
    assert.equal(calls[1].body.target_epic_id, EPIC_ID);
  });

  test("sends base_branch only when given, so an omitted one takes the server default", async () => {
    const { calls, apiCall } = fakeApi(created(), created());

    await enrollIntakeSource(
      { repo_full_name: REPO, project_id: PROJECT_ID, secret_file: secretFileIn("a") },
      deps({ apiCall }),
    );

    // PRESENCE at the server: absent keeps the `master` default, and a null or a blank is a
    // 422 rather than a fallback to it. Sending the key with an undefined-turned-null value
    // would therefore refuse every enrolment that does not name a branch.
    assert.ok(
      !("base_branch" in calls[0].body),
      "an unnamed base_branch reached the server, where it is refused rather than defaulted",
    );

    await enrollIntakeSource(
      {
        repo_full_name: REPO,
        project_id: PROJECT_ID,
        base_branch: "main",
        secret_file: secretFileIn("b"),
      },
      deps({ apiCall }),
    );
    assert.equal(calls[1].body.base_branch, "main");
  });

  test("sends mode only when given, so an omitted one takes the server's pr default (US-45.4)", async () => {
    const { calls, apiCall } = fakeApi(created(), created());

    await enrollIntakeSource(
      { repo_full_name: REPO, project_id: PROJECT_ID, secret_file: secretFileIn("m-a") },
      deps({ apiCall }),
    );
    assert.ok(!("mode" in calls[0].body), "an unnamed mode reached the server");

    await enrollIntakeSource(
      {
        repo_full_name: REPO,
        project_id: PROJECT_ID,
        mode: "thread",
        secret_file: secretFileIn("m-b"),
      },
      deps({ apiCall }),
    );
    assert.equal(calls[1].body.mode, "thread");
  });

  test("an unknown or null mode is refused locally, without enrolling anything", async () => {
    for (const [i, bad] of [null, "", "merge"].entries()) {
      const { calls, apiCall } = fakeApi(created());

      const result = await enrollIntakeSource(
        {
          repo_full_name: REPO,
          project_id: PROJECT_ID,
          mode: bad,
          secret_file: secretFileIn(`mode-${i}.secret`),
        },
        deps({ apiCall }),
      );

      assert.equal(result.error, true);
      assert.match(result.body, /`mode` must be `pr` or `thread`/);
      assert.equal(calls.length, 0, "a refused enrolment must not reach the API");
    }
  });

  test("a null or blank base_branch is refused locally, without enrolling anything", async () => {
    // It is NOT nullable — every dispatch for this repository is cut from it, so there is no
    // cleared state — and enrolment is the one call that cannot simply be repeated: a source
    // created and then refused holds the repository's unique slot until it is revoked.
    for (const [i, bad] of [null, "", "   "].entries()) {
      const { calls, apiCall } = fakeApi(created());

      const result = await enrollIntakeSource(
        {
          repo_full_name: REPO,
          project_id: PROJECT_ID,
          base_branch: bad,
          secret_file: secretFileIn(`blank-${i}.secret`),
        },
        deps({ apiCall }),
      );

      assert.equal(result.error, true);
      assert.match(result.body, /`base_branch` must be a non-empty branch name/);
      assert.equal(calls.length, 0, "a refused enrolment must not reach the API");
    }
  });

  test("refuses an existing secret_file without calling the API, and leaves it untouched", async () => {
    const secret_file = secretFileIn();
    await fs.writeFile(secret_file, "someone else's secret");
    const { calls, apiCall } = fakeApi(created());

    const result = await enrollIntakeSource(
      { repo_full_name: REPO, project_id: PROJECT_ID, secret_file },
      deps({ apiCall }),
    );

    assert.equal(calls.length, 0, "nothing may be enrolled when the path is already taken");
    assert.match(result.body, /already exists/);
    assert.equal(await fs.readFile(secret_file, "utf8"), "someone else's secret");
  });

  test("expands a leading ~/ against the home directory", async () => {
    const { apiCall } = fakeApi(created());

    const result = await enrollIntakeSource(
      { repo_full_name: REPO, project_id: PROJECT_ID, secret_file: "~/x/intake.secret" },
      deps({ apiCall, homedir: tmpdir }),
    );

    assert.equal(result.secret_file, path.join(tmpdir, "x/intake.secret"));
  });

  test("refuses a relative secret_file", async () => {
    const { calls, apiCall } = fakeApi(created());

    const result = await enrollIntakeSource(
      { repo_full_name: REPO, project_id: PROJECT_ID, secret_file: "intake.secret" },
      deps({ apiCall }),
    );

    assert.match(result.body, /must be absolute/);
    assert.equal(calls.length, 0);
  });

  test("a 422 passes through with its code, and the reservation is removed", async () => {
    // The server's refusal body carries the code the caller needs — `an active intake source
    // already binds this repository` is a different remedy from a bad project id — so it is
    // passed through as it came rather than reworded.
    const refusal = {
      error: true,
      status: 422,
      body: { errors: { repo_full_name: ["an active intake source already binds this repository"] } },
    };
    const { apiCall } = fakeApi(refusal);
    const secret_file = secretFileIn();

    const result = await enrollIntakeSource(
      { repo_full_name: REPO, project_id: PROJECT_ID, secret_file },
      deps({ apiCall }),
    );

    assert.equal(result.status, 422);
    assert.deepEqual(result.body, refusal.body);
    await assert.rejects(fs.stat(secret_file), { code: "ENOENT" });
  });

  test("a 2xx whose body did not parse leaks no secret bytes", async () => {
    // `apiCall` answers an unparseable JSON body with `{error: true, status: 201, body:
    // "<first 200 characters of the raw text>"}` — and on THIS endpoint that text is the
    // creation, secret included. So the whole body is withheld.
    const raw = `{"source":{"id":"${SOURCE_ID}"},"webhook_secret":"${SECRET}"`;
    const { apiCall } = fakeApi({ error: true, status: 201, body: raw });
    const secret_file = secretFileIn();

    const result = await enrollIntakeSource(
      { repo_full_name: REPO, project_id: PROJECT_ID, secret_file },
      deps({ apiCall }),
    );

    assert.equal(result.error, true);
    assert.ok(!JSON.stringify(result).includes(SECRET), "the withheld body leaked the secret");
    assert.match(result.body, /body withheld/);
    assert.match(result.body, /intake_source_list/);
    assert.match(result.body, /intake_source_revoke/);
    await assert.rejects(fs.stat(secret_file), { code: "ENOENT" });
  });

  test("a 2xx without a secret is refused without echoing the body", async () => {
    const { apiCall } = fakeApi({ source: { id: SOURCE_ID }, webhook_path: "/x" });

    const result = await enrollIntakeSource(
      { repo_full_name: REPO, project_id: PROJECT_ID, secret_file: secretFileIn() },
      deps({ apiCall }),
    );

    assert.equal(result.error, true);
    assert.match(result.body, /outcome unknown/);
  });

  test("a timeout keeps apiCall's own message and gives recovery guidance", async () => {
    const { apiCall } = fakeApi({ error: true, status: 0, body: "Request timed out after 30s" });

    const result = await enrollIntakeSource(
      { repo_full_name: REPO, project_id: PROJECT_ID, secret_file: secretFileIn() },
      deps({ apiCall }),
    );

    assert.match(result.body, /timed out after 30s/);
    assert.match(result.body, /intake_source_list/);
  });

  test("a write failure after creation revokes the source and says so, with no secret", async () => {
    // The secret is returned once, so a source whose secret was never written is unusable
    // AND holds the repository's uniqueness slot — a second enrolment is refused 422 until it
    // is gone. Leaving it would strand the repository.
    const { calls, apiCall } = fakeApi(created(), { ok: true });
    const secret_file = secretFileIn();
    const brokenFs = {
      ...fs,
      open: async (...args) => {
        const handle = await fs.open(...args);
        return Object.assign(Object.create(Object.getPrototypeOf(handle)), handle, {
          stat: () => handle.stat(),
          writeFile: async () => {
            const err = new Error("no space left on device");
            err.code = "ENOSPC";
            throw err;
          },
          sync: () => handle.sync(),
          close: () => handle.close(),
        });
      },
    };

    const result = await enrollIntakeSource(
      { repo_full_name: REPO, project_id: PROJECT_ID, secret_file },
      deps({ apiCall, fs: brokenFs }),
    );

    assert.equal(calls.length, 2, "the created source must be revoked");
    assert.equal(calls[1].method, "DELETE");
    assert.equal(calls[1].path, `/api/v1/intake/sources/${SOURCE_ID}`);
    assert.match(result.body, /ENOSPC/);
    assert.match(result.body, /was revoked/);
    assert.ok(!result.body.includes(SECRET));
    await assert.rejects(fs.stat(secret_file), { code: "ENOENT" });
  });

  test("a failed revoke after a write failure names the source to revoke by hand", async () => {
    const { apiCall } = fakeApi(created(), { error: true, status: 500, body: "boom" });
    const brokenFs = {
      ...fs,
      open: async (...args) => {
        const handle = await fs.open(...args);
        return Object.assign(Object.create(Object.getPrototypeOf(handle)), handle, {
          stat: () => handle.stat(),
          writeFile: async () => {
            const err = new Error("io");
            err.code = "EIO";
            throw err;
          },
          sync: () => handle.sync(),
          close: () => handle.close(),
        });
      },
    };

    const result = await enrollIntakeSource(
      { repo_full_name: REPO, project_id: PROJECT_ID, secret_file: secretFileIn() },
      deps({ apiCall, fs: brokenFs }),
    );

    assert.match(result.body, /revoking it FAILED/);
    assert.ok(result.body.includes(SOURCE_ID), "the id to revoke by hand is not named");
  });

  test("required arguments are refused locally, and nothing is called", async () => {
    const { calls, apiCall } = fakeApi(created());
    const d = deps({ apiCall });

    const noRepo = await enrollIntakeSource(
      { project_id: PROJECT_ID, secret_file: secretFileIn("a") },
      d,
    );
    assert.match(noRepo.body, /`repo_full_name` is required/);

    const noSecretFile = await enrollIntakeSource(
      { repo_full_name: REPO, project_id: PROJECT_ID },
      d,
    );
    assert.match(noSecretFile.body, /`secret_file` is required/);

    const badProject = await enrollIntakeSource(
      { repo_full_name: REPO, project_id: "not-a-uuid", secret_file: secretFileIn("b") },
      d,
    );
    assert.match(badProject.body, /`project_id` must be a UUID/);

    const badEpic = await enrollIntakeSource(
      {
        repo_full_name: REPO,
        project_id: PROJECT_ID,
        target_epic_id: "nope",
        secret_file: secretFileIn("c"),
      },
      d,
    );
    assert.match(badEpic.body, /`target_epic_id` must be a UUID/);

    assert.equal(calls.length, 0);
  });

  test("errors clearly without LOOPCTL_USER_KEY and calls nothing", async () => {
    const { calls, apiCall } = fakeApi(created());

    const result = await enrollIntakeSource(
      { repo_full_name: REPO, project_id: PROJECT_ID, secret_file: secretFileIn() },
      deps({ apiCall, userKey: undefined }),
    );

    assert.match(result.body, /LOOPCTL_USER_KEY/);
    assert.match(result.body, /api_key_mint_forbidden/);
    assert.equal(calls.length, 0);
  });
});

describe("intake_source_list", () => {
  test("GETs the sources, with include_revoked only on request", async () => {
    const { calls, apiCall } = fakeApi({ sources: [] });

    await listIntakeSources({}, deps({ apiCall }));
    assert.equal(calls[0].method, "GET");
    assert.equal(calls[0].path, "/api/v1/intake/sources");

    await listIntakeSources({ include_revoked: true }, deps({ apiCall }));
    assert.equal(calls[1].path, "/api/v1/intake/sources?include_revoked=true");
  });

  test("each listed source is built from named fields, so a widened row cannot leak", async () => {
    // The WIDEST surface here: every source the tenant has, in one result. A server that grew
    // a secret-bearing field would land it in the transcript once per row.
    const { apiCall } = fakeApi({ sources: [created().source, created().source] });

    const result = await listIntakeSources({}, deps({ apiCall }));

    assert.equal(result.sources.length, 2);
    assert.ok(!JSON.stringify(result).includes(SECRET), "a listed source carried the secret");
    for (const listed of result.sources) {
      assert.ok(!("webhook_secret" in listed));
      assert.equal(listed.id, SOURCE_ID);
      assert.equal(listed.repo_full_name, REPO);
    }
  });

  test("an error from the server passes through untouched", async () => {
    const { apiCall } = fakeApi({ error: true, status: 403, body: "custody_tier_required" });

    const result = await listIntakeSources({}, deps({ apiCall }));

    assert.deepEqual(result, { error: true, status: 403, body: "custody_tier_required" });
  });

  test("errors clearly without LOOPCTL_USER_KEY and calls nothing", async () => {
    const { calls, apiCall } = fakeApi({ sources: [] });
    const result = await listIntakeSources({}, deps({ apiCall, userKey: undefined }));

    assert.match(result.body, /LOOPCTL_USER_KEY/);
    assert.equal(calls.length, 0);
  });
});

describe("intake_source_update", () => {
  test("PATCHes only the fields the caller named", async () => {
    const { calls, apiCall } = fakeApi({ source: {} });

    await updateIntakeSource(
      { source_id: SOURCE_ID, base_branch: "main" },
      deps({ apiCall }),
    );

    assert.equal(calls[0].method, "PATCH");
    assert.equal(calls[0].path, `/api/v1/intake/sources/${SOURCE_ID}`);
    assert.deepEqual(calls[0].body, { base_branch: "main" });
  });

  test("an UNNAMED target_epic_id is omitted, so setting the branch cannot un-point the source", async () => {
    // The controller reads PRESENCE with Map.fetch/2, so a key sent as null CLEARS the epic
    // and an absent key leaves it. If this client filled absent fields with null, setting the
    // base branch would silently strand every record from the source at `pending_triage`.
    const { calls, apiCall } = fakeApi({ source: {} });

    await updateIntakeSource({ source_id: SOURCE_ID, base_branch: "main" }, deps({ apiCall }));

    assert.ok(
      !("target_epic_id" in calls[0].body),
      "an unnamed target_epic_id reached the server and would have cleared the epic",
    );
  });

  test("the updated source comes back built from named fields", async () => {
    const { apiCall } = fakeApi({ source: created().source });

    const result = await updateIntakeSource(
      { source_id: SOURCE_ID, base_branch: "main" },
      deps({ apiCall }),
    );

    assert.ok(!JSON.stringify(result).includes(SECRET));
    assert.ok(!("webhook_secret" in result.source));
    assert.equal(result.source.base_branch, "master");
  });

  test("a BLANK target_epic_id names null as the clear, and is never called required", async () => {
    // The field is optional here too, and a blank is refused rather than TAKEN as the clear:
    // clearing returns the source to escalating every report to a human, and "" is equally
    // consistent with a caller whose variable was empty by accident.
    const { calls, apiCall } = fakeApi({ source: {} });

    const result = await updateIntakeSource(
      { source_id: SOURCE_ID, target_epic_id: "" },
      deps({ apiCall }),
    );

    assert.match(result.body, /`target_epic_id` is OPTIONAL/);
    assert.match(result.body, /Send null to CLEAR/);
    assert.ok(!/is required/.test(result.body), `refused as required: ${result.body}`);
    assert.equal(calls.length, 0);
  });

  test("an EXPLICIT null target_epic_id is forwarded, because that is how it is cleared", async () => {
    const { calls, apiCall } = fakeApi({ source: {} });

    await updateIntakeSource(
      { source_id: SOURCE_ID, target_epic_id: null },
      deps({ apiCall }),
    );

    assert.ok("target_epic_id" in calls[0].body, "the clear was dropped");
    assert.equal(calls[0].body.target_epic_id, null);
  });

  test("a null base_branch is refused locally, naming the reason", async () => {
    const { calls, apiCall } = fakeApi({ source: {} });

    const result = await updateIntakeSource(
      { source_id: SOURCE_ID, base_branch: null },
      deps({ apiCall }),
    );

    assert.match(result.body, /cannot be null/);
    assert.equal(calls.length, 0);
  });

  test("mode alone is a complete update, and is forwarded as named (US-45.4)", async () => {
    const { calls, apiCall } = fakeApi({ source: { ...created().source, mode: "thread" } });

    const result = await updateIntakeSource(
      { source_id: SOURCE_ID, mode: "thread" },
      deps({ apiCall }),
    );

    assert.deepEqual(calls[0].body, { mode: "thread" });
    assert.equal(result.source.mode, "thread");
  });

  test("a null mode is refused locally on update, naming the reason", async () => {
    const { calls, apiCall } = fakeApi({ source: {} });

    const result = await updateIntakeSource(
      { source_id: SOURCE_ID, mode: null },
      deps({ apiCall }),
    );

    assert.match(result.body, /`mode` must be `pr` or `thread`/);
    assert.equal(calls.length, 0);
  });

  test("naming neither field is refused locally, naming the server's code", async () => {
    const { calls, apiCall } = fakeApi({ source: {} });

    const result = await updateIntakeSource({ source_id: SOURCE_ID }, deps({ apiCall }));

    assert.match(result.body, /nothing_to_update/);
    assert.equal(calls.length, 0);
  });

  test("a malformed source_id is refused before any call, with status 0", async () => {
    // The server answers the SAME 404 for a malformed id as for an unknown one, and the two
    // have opposite remedies. `status: 0` is this client's marker for "no request was sent".
    const { calls, apiCall } = fakeApi({ source: {} });

    const result = await updateIntakeSource(
      { source_id: "not-a-uuid", base_branch: "main" },
      deps({ apiCall }),
    );

    assert.equal(result.status, 0);
    assert.match(result.body, /must be a UUID/);
    assert.equal(calls.length, 0);
  });
});

describe("intake_source_revoke", () => {
  test("DELETEs the source by id", async () => {
    const { calls, apiCall } = fakeApi({ source: {} });

    await revokeIntakeSource({ source_id: SOURCE_ID }, deps({ apiCall }));

    assert.equal(calls[0].method, "DELETE");
    assert.equal(calls[0].path, `/api/v1/intake/sources/${SOURCE_ID}`);
    assert.equal(calls[0].body, null);
  });

  test("the revoked source comes back built from named fields", async () => {
    const { apiCall } = fakeApi({ source: created().source });

    const result = await revokeIntakeSource({ source_id: SOURCE_ID }, deps({ apiCall }));

    assert.ok(!JSON.stringify(result).includes(SECRET));
    assert.ok(!("webhook_secret" in result.source));
    assert.equal(result.source.id, SOURCE_ID);
  });

  test("a malformed or missing source_id is refused before any call", async () => {
    const { calls, apiCall } = fakeApi({ source: {} });

    assert.match((await revokeIntakeSource({}, deps({ apiCall }))).body, /is required/);
    assert.match(
      (await revokeIntakeSource({ source_id: "nope" }, deps({ apiCall }))).body,
      /must be a UUID/,
    );
    assert.equal(calls.length, 0);
  });

  test("errors clearly without LOOPCTL_USER_KEY and calls nothing", async () => {
    const { calls, apiCall } = fakeApi({ source: {} });
    const result = await revokeIntakeSource(
      { source_id: SOURCE_ID },
      deps({ apiCall, userKey: undefined }),
    );

    assert.match(result.body, /LOOPCTL_USER_KEY/);
    assert.equal(calls.length, 0);
  });
});

describe("the paths and the webhook URL", () => {
  test("are the routes loopctl serves", () => {
    assert.equal(SOURCES_PATH, "/api/v1/intake/sources");
    assert.equal(sourcePath(SOURCE_ID), `/api/v1/intake/sources/${SOURCE_ID}`);
  });

  test("the webhook URL joins the server this process talks to, with no double slash", () => {
    // A webhook pointed at a different host than the one holding the source is a delivery
    // that can never authenticate, and a `//` in the path is a 404 at the router.
    assert.equal(
      webhookUrl("https://loopctl.com/", `/api/v1/intake/github/${SOURCE_ID}`),
      `https://loopctl.com/api/v1/intake/github/${SOURCE_ID}`,
    );
    assert.equal(
      webhookUrl("http://localhost:4030", `/api/v1/intake/github/${SOURCE_ID}`),
      `http://localhost:4030/api/v1/intake/github/${SOURCE_ID}`,
    );
  });
});

describe("the wiring in index.js", () => {
  const WIRING = {
    intake_source_enroll: "intakeSourceEnroll",
    intake_source_list: "intakeSourceList",
    intake_source_update: "intakeSourceUpdate",
    intake_source_revoke: "intakeSourceRevoke",
  };

  for (const [name, handler] of Object.entries(WIRING)) {
    test(`${name} is declared, dispatched TO ITS OWN HANDLER, and documented`, () => {
      // THE CASE LABEL ALONE IS NOT THE WIRING. Pointing `case "intake_source_revoke":` at
      // `intakeSourceList(args)` keeps every label present, so a label-only assertion stays
      // green while the tool calls a different endpoint. The handler identifier is what
      // decides what the call does, so it is asserted too — and the README row is what an
      // operator reads, so a bare `includes(name)` is not enough either: every one of these
      // is named in the surrounding prose.
      assert.ok(INDEX_SRC.includes(`name: "${name}"`), `${name} is not declared`);
      // COMMENTS STRIPPED. A `case` inside a `/* … */` is still present in the raw source, so
      // a raw match calls a tool DISABLED that way correctly wired — which is exactly how a
      // disabling edit looks. Verified by mutation: block-commenting this tool's case left
      // this assertion green until the strip was added.
      assert.match(
        DISPATCH_SRC,
        new RegExp(`case "${name}":\\s*return await ${handler}\\(`),
        `${name} is not dispatched to ${handler}()`,
      );
      assert.ok(
        README.split("\n").some((line) => line.startsWith("| `" + name + "` |")),
        `${name} has no row in a README tool table`,
      );
    });
  }

  test("all four handlers go through intakeDeps, which pins the EXACT user key", () => {
    // COMMENTS STRIPPED FIRST: the factory carries a comment naming the same identifiers, so
    // a raw slice is satisfied by a site where the wiring has been commented out — the shape
    // a disabling edit takes.
    const start = INDEX_SRC.indexOf("function intakeDeps(");
    assert.ok(start > -1, "the intakeDeps factory was not found");
    const end = INDEX_SRC.indexOf("\nasync function ", start);
    assert.ok(end > start, "the factory has no following function to bound it");

    const factory = stripComments(INDEX_SRC.slice(start, end));

    assert.match(factory, /process\.env\.LOOPCTL_USER_KEY/, "it does not read LOOPCTL_USER_KEY");
    assert.match(
      factory,
      /exactKey:\s*true/,
      "it does not pin the key, so a global LOOPCTL_API_KEY of any role would displace it",
    );
    assert.match(factory, /getBaseUrl\(\)/, "it does not inject the base URL for the webhook URL");

    for (const handler of Object.values(WIRING)) {
      const hStart = INDEX_SRC.indexOf(`async function ${handler}(`);
      assert.ok(hStart > -1, `${handler} is not defined`);
      const hEnd = INDEX_SRC.indexOf("\nasync function ", hStart + 1);
      const body = stripComments(INDEX_SRC.slice(hStart, hEnd === -1 ? undefined : hEnd));
      // The CALL EXPRESSION, not the bare identifier. `intakeDeps` is declared after the four
      // handlers (see the comment on it in index.js), so the last handler's slice contains
      // `function intakeDeps()` itself — which a bare /intakeDeps\(\)/ would match, making
      // that one assertion vacuous.
      assert.match(
        body,
        new RegExp(`await [A-Za-z]+\\(args, intakeDeps\\(\\)\\)`),
        `${handler} does not pass intakeDeps() to its lib function`,
      );
    }
  });

  test("the enrol tool declares secret_file as required, so the secret has somewhere to go", () => {
    // Making it optional is the one edit that would quietly put the secret back in the
    // transcript, because the lib would then have to return it to be useful at all.
    const declaration = INDEX_SRC.slice(
      INDEX_SRC.indexOf('name: "intake_source_enroll"'),
      INDEX_SRC.indexOf('name: "intake_source_list"'),
    );

    assert.match(declaration, /secret_file/, "secret_file is not declared");
    assert.match(
      declaration,
      /required: \["repo_full_name", "project_id", "secret_file"\]/,
      "secret_file is not required",
    );
  });
});

describe("the descriptions carry what a caller needs instead of the controller", () => {
  const description = (tool) => {
    const at = INDEX_SRC.indexOf(`name: "${tool}"`);
    assert.ok(at > -1, `${tool} is not declared`);
    return INDEX_SRC.slice(at, INDEX_SRC.indexOf("inputSchema", at));
  };

  const row = (tool) =>
    README.split("\n").find((line) => line.startsWith(`| \`${tool}\` |`)) ?? "";

  test("intake_source_enroll says the secret is returned once and is NOT in the result", () => {
    // The four facts a session must not have to read the controller for. This is the first:
    // a caller who learns afterwards that the secret cannot be re-read has already lost it.
    for (const text of [description("intake_source_enroll"), row("intake_source_enroll")]) {
      assert.match(text, /ONCE|once/, "it never says the secret is returned once");
      assert.match(text, /never (be )?read again|can never be read/i);
      assert.match(text, /secret_file/, "it never names where the secret goes");
      assert.match(text, /0600/, "it never states the mode the secret file is written with");
    }
  });

  test("intake_source_enroll names the key it needs and the refusal a wrong one earns", () => {
    for (const text of [description("intake_source_enroll"), row("intake_source_enroll")]) {
      assert.match(text, /LOOPCTL_USER_KEY/);
      assert.match(text, /api_key_mint_forbidden/);
      assert.match(text, /custody_tier_required/);
    }
  });

  test("intake_source_enroll names the exact next step: the URL, the event and the secret field", () => {
    // This tool is used once, by someone who then has to configure GitHub. A description that
    // stops at the API call leaves them to guess the event list, and `issues` is the only one
    // loopctl acts on.
    for (const text of [description("intake_source_enroll"), row("intake_source_enroll")]) {
      assert.match(text, /webhook_url/, "it never names the URL to configure");
      assert.match(text, /events\[\]=issues|Issues|ISSUES/, "it never names the Issues event");
      assert.match(text, /application\/json/, "it never names the content type");
      assert.match(text, /invalid_signature/, "it never names what a misconfiguration answers");
    }
  });

  test("intake_source_enroll says base_branch is named HERE and defaults to master", () => {
    // THIS TEST ASSERTED THE OPPOSITE UNTIL #874 ROUND 2. It was named "a new source starts at
    // master and cannot be given a branch" and its comment cited the create path building its
    // attrs from three params — true until that same PR added `base_branch` to it. The
    // assertions were loose enough to keep passing against the rewritten description, so
    // nothing went red and a later reader would have taken the name as the behaviour.
    //
    // What is asserted now is what a caller must know at the moment it enrols: the parameter
    // exists, omitting it yields `master`, and a `main` repository has to say so.
    for (const text of [description("intake_source_enroll"), row("intake_source_enroll")]) {
      assert.match(text, /base_branch/, "it never names the parameter");
      assert.match(text, /master/, "it never says what omitting it yields");
      assert.match(text, /main/, "it never names the case that needs it");
      assert.ok(
        !/(always starts|cannot be given|no parameter for it|has no way to name)/i.test(text),
        "it still claims enrolment cannot name a branch",
      );
    }
  });

  test("intake_source_update is described as the CORRECTION, not as the only way to set a branch", () => {
    // The other half of the same residue: while enrolment could not name a branch, this tool
    // was "the second half of enrolling any repository whose trunk is main". It is now the
    // remedy for a source already pointed at the wrong trunk, and saying otherwise sends a
    // caller to make two calls where one does.
    for (const text of [description("intake_source_update"), row("intake_source_update")]) {
      assert.match(text, /base_branch/);
      assert.ok(
        !/(always starts|enrolment always|second half of enrolling)/i.test(text),
        "it still says enrolment cannot name the branch",
      );
    }
  });

  test("both write tools declare mode with exactly the two values the server accepts", () => {
    for (const name of ["intake_source_enroll", "intake_source_update"]) {
      const tool = loadTools().find((t) => t.name === name);
      // Copied out of the vm realm the declarations were evaluated in, so deepEqual compares
      // values and not array prototypes.
      assert.deepEqual([...(tool.inputSchema.properties.mode?.enum ?? [])], ["pr", "thread"], name);
    }
    for (const text of [description("intake_source_enroll"), row("intake_source_enroll")]) {
      assert.match(text, /thread/, "it never says what thread mode does");
    }
  });

  test("intake_source_update names the 409 a mode change meets with stories in flight", () => {
    for (const text of [description("intake_source_update"), row("intake_source_update")]) {
      assert.match(text, /stories_in_flight/, "it never names the refusal");
    }
  });

  test("intake_source_revoke is named for what it does, and says the row is kept", () => {
    const text = description("intake_source_revoke");

    assert.match(text, /REVOKE|revoke/, "the tool does not say it revokes");
    // NOT `row is kept|revoked_at`, which the first draft used: `revoked_at` appears three
    // sentences later in the idempotency clause, so the alternation survived a mutation that
    // deleted the claim outright (exit 1). An alternation whose weaker arm is satisfied by
    // unrelated prose asserts nothing about the arm that matters.
    assert.match(text, /row is kept/, "it never says the row survives the revoke");
    assert.match(text, /idempotent/i);
    assert.match(text, /invalid_signature/, "it never says what later deliveries get");
  });

  test("intake_source_update warns against a null sent to mean 'unchanged'", () => {
    // The endpoint reads PRESENCE, so `null` is the CLEAR — the one shape an LLM is most
    // likely to send for a field it is not changing.
    for (const text of [description("intake_source_update"), row("intake_source_update")]) {
      assert.match(text, /target_epic_id: null/, "it never shows the hazardous shape");
      assert.match(text, /nothing_to_update/);
    }
  });

  test("intake_source_list says the secret is not recoverable there", () => {
    for (const text of [description("intake_source_list"), row("intake_source_list")]) {
      assert.match(text, /not here and is not anywhere|not how to recover|not the way/i);
    }
  });

  test("the scan reads real descriptions — it is not matching an empty string", () => {
    // Every assertion above is a `match` against a slice, and a slice that silently became ""
    // would fail loudly — but one that became the WHOLE FILE would pass everything while
    // proving nothing about the tool it names.
    const enroll = description("intake_source_enroll");

    assert.ok(enroll.length > 500, `the enrol description sliced to ${enroll.length} characters`);
    assert.ok(
      !enroll.includes('name: "intake_source_list"'),
      "the slice ran past its own tool and into the next one",
    );
  });
});
