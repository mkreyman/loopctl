/**
 * Issue #809: the runner_* MCP tools.
 *
 * SINGLE SOURCE OF TRUTH: every behaviour below runs the real code in ../lib/runners.js,
 * with the HTTP call injected as a recording fake and the token file written to a real
 * temp directory. The last block source-pins index.js so the wiring (declaration,
 * dispatch case, exact user key) cannot drift from the logic.
 *
 * The property this file exists for: the raw token reaches the token file and nothing
 * else. Each enrollment test searches the serialized result AND everything written to
 * stdout, stderr and the console during the call for the token string.
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
  enrollRunner,
  listRunners,
  revokeRunner,
  runnerPool,
  expandHome,
} from "../lib/runners.js";
import { parseJsonResponseBody } from "../lib/http-helpers.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");
const README = readFileSync(path.join(DIR, "..", "README.md"), "utf8");

const TOKEN = "lc_runner_token_SECRET_4f9d2c7a1b";
const USER_KEY = "lc_user_key_for_tests";
const RUNNER = {
  id: "5b0e7f7e-3f0c-4d51-9a2d-1c1f2f7b9e11",
  name: "minis",
  revoked_at: null,
  inserted_at: "2026-09-12T10:00:00Z",
  updated_at: "2026-09-12T10:00:00Z",
};

/** A recording `apiCall` fake answering from a per-method-and-path table. */
function fakeApi(responses = {}) {
  const calls = [];
  const apiCall = async (method, apiPath, body) => {
    calls.push({ method, path: apiPath, body });
    const key = `${method} ${apiPath}`;
    if (key in responses) return responses[key];
    return { error: true, status: 404, body: { error: { code: "not_found" } } };
  };
  return { calls, apiCall };
}

const enrolled = { "POST /api/v1/runners": { runner: RUNNER, token: TOKEN } };

/** Runs `fn` with stdout, stderr and console captured; returns [result, captured text]. */
async function capturingOutput(fn) {
  let captured = "";
  const record = (...args) => {
    captured += args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" ");
    return true;
  };
  const saved = {
    out: process.stdout.write,
    err: process.stderr.write,
    log: console.log,
    error: console.error,
    warn: console.warn,
    info: console.info,
    debug: console.debug,
  };
  process.stdout.write = record;
  process.stderr.write = record;
  console.log = console.error = console.warn = console.info = console.debug = record;
  try {
    return [await fn(), captured];
  } finally {
    process.stdout.write = saved.out;
    process.stderr.write = saved.err;
    Object.assign(console, {
      log: saved.log,
      error: saved.error,
      warn: saved.warn,
      info: saved.info,
      debug: saved.debug,
    });
  }
}

function assertNoToken(result, captured) {
  const serialized = JSON.stringify(result);
  assert.ok(!serialized.includes(TOKEN), `token leaked into the result: ${serialized}`);
  assert.ok(!captured.includes(TOKEN), "token leaked into stdout/stderr/console");
}

let tmp;
beforeEach(async () => {
  tmp = await fs.mkdtemp(path.join(os.tmpdir(), "runner-tools-"));
});
afterEach(async () => {
  await fs.rm(tmp, { recursive: true, force: true });
});

describe("runner_enroll", () => {
  test("writes the token to a new 0600 file and returns only the runner row and the path", async () => {
    const tokenFile = path.join(tmp, "nested", "dir", "token");
    const { calls, apiCall } = fakeApi(enrolled);

    const [result, captured] = await capturingOutput(() =>
      enrollRunner({ name: "minis", token_file: tokenFile }, { userKey: USER_KEY, apiCall }),
    );

    assert.deepEqual(result, {
      runner: { id: RUNNER.id, name: "minis", inserted_at: RUNNER.inserted_at },
      token_file: tokenFile,
    });
    assertNoToken(result, captured);

    assert.equal(await fs.readFile(tokenFile, "utf8"), TOKEN);
    const stat = await fs.stat(tokenFile);
    assert.equal(stat.mode & 0o777, 0o600);
    assert.equal((await fs.stat(path.dirname(tokenFile))).mode & 0o077, 0, "created dirs are 0700");

    assert.deepEqual(calls, [{ method: "POST", path: "/api/v1/runners", body: { name: "minis" } }]);
  });

  test("sends max_sessions only when given, and returns it on the runner", async () => {
    const { calls, apiCall } = fakeApi({
      "POST /api/v1/runners": { runner: { ...RUNNER, max_sessions: 4 }, token: TOKEN },
    });

    const withLimit = await enrollRunner(
      { name: "minis", token_file: path.join(tmp, "with.token"), max_sessions: 4 },
      { userKey: USER_KEY, apiCall },
    );

    assert.deepEqual(calls[0].body, { name: "minis", max_sessions: 4 });
    assert.equal(withLimit.runner.max_sessions, 4);

    await enrollRunner(
      { name: "blockit", token_file: path.join(tmp, "without.token") },
      { userKey: USER_KEY, apiCall },
    );

    assert.deepEqual(calls[1].body, { name: "blockit" });
  });

  test("expands a leading ~/ against the home directory", async () => {
    const { apiCall } = fakeApi(enrolled);
    const result = await enrollRunner(
      { name: "minis", token_file: "~/runner/token" },
      { userKey: USER_KEY, apiCall, homedir: tmp },
    );

    assert.equal(result.token_file, path.join(tmp, "runner", "token"));
    assert.equal(await fs.readFile(path.join(tmp, "runner", "token"), "utf8"), TOKEN);
    assert.equal(expandHome("~", tmp), tmp);
    assert.equal(expandHome("/abs/path", tmp), "/abs/path");
  });

  test("refuses an existing token_file without calling the API and leaves it untouched", async () => {
    const tokenFile = path.join(tmp, "token");
    await fs.writeFile(tokenFile, "the previous token");
    const { calls, apiCall } = fakeApi(enrolled);

    const result = await enrollRunner(
      { name: "minis", token_file: tokenFile },
      { userKey: USER_KEY, apiCall },
    );

    assert.equal(result.error, true);
    assert.match(result.body, /already exists/);
    assert.match(result.body, /Nothing was enrolled/);
    assert.deepEqual(calls, []);
    assert.equal(await fs.readFile(tokenFile, "utf8"), "the previous token");
  });

  test("refuses a symlink at token_file, even a dangling one, without calling the API", async () => {
    const target = path.join(tmp, "elsewhere");
    const tokenFile = path.join(tmp, "token");
    await fs.symlink(target, tokenFile);
    const { calls, apiCall } = fakeApi(enrolled);

    const result = await enrollRunner(
      { name: "minis", token_file: tokenFile },
      { userKey: USER_KEY, apiCall },
    );

    assert.equal(result.error, true);
    assert.deepEqual(calls, []);
    await assert.rejects(fs.stat(target), { code: "ENOENT" });
  });

  test("refuses a relative token_file", async () => {
    const { calls, apiCall } = fakeApi(enrolled);
    const result = await enrollRunner(
      { name: "minis", token_file: "token" },
      { userKey: USER_KEY, apiCall },
    );
    assert.equal(result.error, true);
    assert.match(result.body, /absolute/);
    assert.deepEqual(calls, []);
  });

  test("a write failure after enrollment revokes the runner and says so, with no token", async () => {
    const tokenFile = path.join(tmp, "token");
    const { calls, apiCall } = fakeApi({
      ...enrolled,
      [`DELETE /api/v1/runners/${RUNNER.id}`]: { runner: { ...RUNNER, revoked_at: "now" } },
    });

    // Real fs, except the handle's write fails the way a full disk does.
    const failingFs = {
      ...fs,
      open: async (...args) => {
        const handle = await fs.open(...args);
        return {
          writeFile: async () => {
            throw Object.assign(new Error(`ENOSPC writing ${TOKEN}`), { code: "ENOSPC" });
          },
          sync: () => handle.sync(),
          close: () => handle.close(),
          stat: () => handle.stat(),
        };
      },
    };

    const [result, captured] = await capturingOutput(() =>
      enrollRunner(
        { name: "minis", token_file: tokenFile },
        { userKey: USER_KEY, apiCall, fs: failingFs },
      ),
    );

    assert.equal(result.error, true);
    assert.match(result.body, /ENOSPC/);
    assert.match(result.body, /the runner was revoked/);
    assertNoToken(result, captured);

    assert.deepEqual(
      calls.map((c) => `${c.method} ${c.path}`),
      ["POST /api/v1/runners", `DELETE /api/v1/runners/${RUNNER.id}`],
    );
    await assert.rejects(fs.stat(tokenFile), { code: "ENOENT" }, "the empty reservation is removed");
  });

  test("a failed revoke after a write failure names the runner id to revoke by hand", async () => {
    const { apiCall } = fakeApi({
      ...enrolled,
      [`DELETE /api/v1/runners/${RUNNER.id}`]: { error: true, status: 500, body: "boom" },
    });
    const failingFs = {
      ...fs,
      open: async (...args) => {
        const handle = await fs.open(...args);
        return {
          writeFile: async () => {
            throw Object.assign(new Error("EIO"), { code: "EIO" });
          },
          sync: () => handle.sync(),
          close: () => handle.close(),
          stat: () => handle.stat(),
        };
      },
    };

    const result = await enrollRunner(
      { name: "minis", token_file: path.join(tmp, "token") },
      { userKey: USER_KEY, apiCall, fs: failingFs },
    );

    assert.equal(result.error, true);
    assert.match(result.body, /revoking the runner FAILED \(status 500\)/);
    assert.ok(result.body.includes(RUNNER.id));
    assert.ok(!JSON.stringify(result).includes(TOKEN));
  });

  for (const [status, code] of [
    [422, "validation_error"],
    [403, "custody_tier_required"],
    [403, "api_key_mint_forbidden"],
  ]) {
    test(`passes a ${status} ${code} through with its code and removes the reservation`, async () => {
      const tokenFile = path.join(tmp, "token");
      const failure = { error: true, status, body: { error: { code, message: "no" } } };
      const { apiCall } = fakeApi({ "POST /api/v1/runners": failure });

      const result = await enrollRunner(
        { name: "minis", token_file: tokenFile },
        { userKey: USER_KEY, apiCall },
      );

      assert.deepEqual(result, failure);
      await assert.rejects(fs.stat(tokenFile), { code: "ENOENT" });
    });
  }

  test("a success without a token is refused without echoing the body, and the runner revoked", async () => {
    const odd = { runner: RUNNER, credential: TOKEN };
    const { calls, apiCall } = fakeApi({
      "POST /api/v1/runners": odd,
      [`DELETE /api/v1/runners/${RUNNER.id}`]: { runner: RUNNER },
    });

    const result = await enrollRunner(
      { name: "minis", token_file: path.join(tmp, "token") },
      { userKey: USER_KEY, apiCall },
    );

    assert.equal(result.error, true);
    assert.ok(!JSON.stringify(result).includes(TOKEN));
    assert.equal(calls.at(-1).method, "DELETE");
  });

  test("a 201 whose body did not parse leaks no token bytes, and the id it proves is revoked", async () => {
    const tokenFile = path.join(tmp, "token");
    // Exactly what apiCall returns for a truncated 2xx: the real parser's error, whose body
    // quotes the first 200 characters of the enrollment, token prefix included.
    const raw = JSON.stringify({ runner: RUNNER, token: TOKEN });
    const truncated = parseJsonResponseBody(raw.slice(0, raw.length - 6), 201);
    assert.ok(truncated.body.includes(TOKEN.slice(0, 10)), "fixture must carry token bytes");

    const { calls, apiCall } = fakeApi({
      "POST /api/v1/runners": truncated,
      [`DELETE /api/v1/runners/${RUNNER.id}`]: { runner: RUNNER },
    });

    const [result, captured] = await capturingOutput(() =>
      enrollRunner({ name: "minis", token_file: tokenFile }, { userKey: USER_KEY, apiCall }),
    );

    assert.equal(result.error, true);
    assert.equal(result.status, 201);
    const serialized = JSON.stringify(result);
    assert.ok(!serialized.includes(TOKEN.slice(0, 6)), `token bytes leaked: ${serialized}`);
    assert.ok(!serialized.includes('\\"token\\"'), "no fragment of the raw body is echoed");
    assert.ok(!captured.includes(TOKEN.slice(0, 6)));
    assert.match(result.body, /withheld/);
    assert.match(result.body, new RegExp(`runner ${RUNNER.id}; it was revoked`));
    assert.deepEqual(
      calls.map((c) => `${c.method} ${c.path}`),
      ["POST /api/v1/runners", `DELETE /api/v1/runners/${RUNNER.id}`],
    );
    await assert.rejects(fs.stat(tokenFile), { code: "ENOENT" });
  });

  test("a 2xx body cut before the runner id gives recovery guidance and revokes nothing", async () => {
    const truncated = parseJsonResponseBody('{"runner":{"na', 201);
    const { calls, apiCall } = fakeApi({ "POST /api/v1/runners": truncated });

    const result = await enrollRunner(
      { name: "minis", token_file: path.join(tmp, "token") },
      { userKey: USER_KEY, apiCall },
    );

    assert.equal(result.error, true);
    assert.match(result.body, /runner_list/);
    assert.match(result.body, /runner_revoke/);
    assert.ok(!result.body.includes('{"runner"'), "the raw body is not echoed");
    assert.equal(calls.length, 1);
  });

  test("a 502 after the request gives recovery guidance and withholds its body", async () => {
    const tokenFile = path.join(tmp, "token");
    const edge = { error: true, status: 502, body: `<html>bad gateway ${TOKEN}</html>` };
    const { calls, apiCall } = fakeApi({ "POST /api/v1/runners": edge });

    const result = await enrollRunner(
      { name: "minis", token_file: tokenFile },
      { userKey: USER_KEY, apiCall },
    );

    assert.equal(result.error, true);
    assert.equal(result.status, 502);
    assert.match(result.body, /HTTP 502/);
    assert.match(result.body, /may have been enrolled/);
    assert.match(result.body, /runner_list/);
    assert.ok(!JSON.stringify(result).includes(TOKEN));
    assert.ok(!result.body.includes("bad gateway"));
    assert.equal(calls.length, 1, "no id is proven, so nothing is revoked");
    await assert.rejects(fs.stat(tokenFile), { code: "ENOENT" });
  });

  test("a timeout keeps apiCall's own message and gives recovery guidance", async () => {
    const { apiCall } = fakeApi({
      "POST /api/v1/runners": { error: true, status: 0, body: "Request timed out after 30s" },
    });
    const result = await enrollRunner(
      { name: "minis", token_file: path.join(tmp, "token") },
      { userKey: USER_KEY, apiCall },
    );
    assert.match(result.body, /Request timed out after 30s/);
    assert.match(result.body, /runner_revoke/);
  });

  test("a close() that rejects after the token was synced removes the file and says so", async () => {
    const tokenFile = path.join(tmp, "token");
    const { calls, apiCall } = fakeApi({
      ...enrolled,
      [`DELETE /api/v1/runners/${RUNNER.id}`]: { runner: RUNNER },
    });
    const closeFailsFs = {
      ...fs,
      open: async (...args) => {
        const handle = await fs.open(...args);
        let closed = false;
        return {
          writeFile: (data) => handle.writeFile(data),
          sync: () => handle.sync(),
          stat: () => (closed ? Promise.reject(Object.assign(new Error("EBADF"), { code: "EBADF" })) : handle.stat()),
          close: async () => {
            if (!closed) {
              closed = true;
              await handle.close();
            }
            throw Object.assign(new Error("EIO"), { code: "EIO" });
          },
        };
      },
    };

    const result = await enrollRunner(
      { name: "minis", token_file: tokenFile },
      { userKey: USER_KEY, apiCall, fs: closeFailsFs },
    );

    assert.equal(result.error, true);
    assert.match(result.body, /\(EIO\)/);
    assert.match(result.body, /the runner was revoked/);
    assert.match(result.body, /was removed; the same path can be used again/);
    await assert.rejects(fs.stat(tokenFile), { code: "ENOENT" }, "the synced token is not left on disk");
    assert.equal(calls.at(-1).method, "DELETE");
  });

  test("a token file that cannot be removed is named in the message", async () => {
    const tokenFile = path.join(tmp, "token");
    const { apiCall } = fakeApi({
      ...enrolled,
      [`DELETE /api/v1/runners/${RUNNER.id}`]: { runner: RUNNER },
    });
    const stuckFs = {
      ...fs,
      unlink: async () => {
        throw Object.assign(new Error("EACCES"), { code: "EACCES" });
      },
      open: async (...args) => {
        const handle = await fs.open(...args);
        return {
          writeFile: async () => {
            throw Object.assign(new Error("ENOSPC"), { code: "ENOSPC" });
          },
          sync: () => handle.sync(),
          close: () => handle.close(),
          stat: () => handle.stat(),
        };
      },
    };

    const result = await enrollRunner(
      { name: "minis", token_file: tokenFile },
      { userKey: USER_KEY, apiCall, fs: stuckFs },
    );

    assert.match(result.body, new RegExp(`'${tokenFile}' could NOT be removed`));
  });

  test("errors clearly without LOOPCTL_USER_KEY and calls nothing", async () => {
    const tokenFile = path.join(tmp, "token");
    const { calls, apiCall } = fakeApi(enrolled);

    const result = await enrollRunner(
      { name: "minis", token_file: tokenFile },
      { userKey: undefined, apiCall },
    );

    assert.equal(result.error, true);
    assert.match(result.body, /LOOPCTL_USER_KEY/);
    assert.deepEqual(calls, []);
    await assert.rejects(fs.stat(tokenFile), { code: "ENOENT" });
  });
});

describe("runner_list, runner_revoke, runner_pool", () => {
  test("runner_list calls GET /api/v1/runners, with include_revoked on request", async () => {
    const { calls, apiCall } = fakeApi();
    await listRunners({}, { userKey: USER_KEY, apiCall });
    await listRunners({ include_revoked: true }, { userKey: USER_KEY, apiCall });
    assert.deepEqual(
      calls.map((c) => `${c.method} ${c.path}`),
      ["GET /api/v1/runners", "GET /api/v1/runners?include_revoked=true"],
    );
  });

  test("runner_revoke calls DELETE /api/v1/runners/:id and requires an id", async () => {
    const { calls, apiCall } = fakeApi();
    await revokeRunner({ id: RUNNER.id }, { userKey: USER_KEY, apiCall });
    assert.deepEqual(calls, [{ method: "DELETE", path: `/api/v1/runners/${RUNNER.id}`, body: null }]);

    const missing = await revokeRunner({}, { userKey: USER_KEY, apiCall });
    assert.equal(missing.error, true);
    assert.equal(calls.length, 1);
  });

  test("runner_pool calls GET /api/v1/runners/pool", async () => {
    const { calls, apiCall } = fakeApi({ "GET /api/v1/runners/pool": { runners: [] } });
    assert.deepEqual(await runnerPool({}, { userKey: USER_KEY, apiCall }), { runners: [] });
    assert.deepEqual(calls, [{ method: "GET", path: "/api/v1/runners/pool", body: null }]);
  });

  test("each errors clearly without LOOPCTL_USER_KEY and calls nothing", async () => {
    const { calls, apiCall } = fakeApi();
    for (const call of [
      () => listRunners({}, { userKey: "", apiCall }),
      () => revokeRunner({ id: RUNNER.id }, { userKey: undefined, apiCall }),
      () => runnerPool({}, { userKey: undefined, apiCall }),
    ]) {
      const result = await call();
      assert.equal(result.error, true);
      assert.match(result.body, /LOOPCTL_USER_KEY/);
    }
    assert.deepEqual(calls, []);
  });
});

describe("index.js wiring", () => {
  const DISPATCH = {
    runner_enroll: "runnerEnroll",
    runner_list: "runnerList",
    runner_revoke: "runnerRevoke",
    runner_pool: "runnerPoolRead",
  };

  function functionSource(name) {
    const declaration = `function ${name}(`;
    const start = INDEX_SRC.indexOf(declaration);
    assert.notEqual(start, -1, `index.js must define ${declaration}`);
    const rest = INDEX_SRC.slice(start + declaration.length);
    const end = rest.indexOf("\n}\n");
    assert.notEqual(end, -1);
    return rest.slice(0, end);
  }

  for (const [tool, handler] of Object.entries(DISPATCH)) {
    test(`${tool} is declared, dispatched to ${handler}, and documented in the README`, () => {
      assert.ok(INDEX_SRC.includes(`name: "${tool}",`), `${tool} declared`);
      assert.match(
        INDEX_SRC,
        new RegExp(`case "${tool}":\\s*\\n\\s*return await ${handler}\\(args\\);`),
      );
      assert.ok(README.includes(`\`${tool}\``), `${tool} has a README row`);
    });
  }

  test("the runner handlers call the lib with the exact LOOPCTL_USER_KEY", () => {
    const deps = functionSource("runnerDeps");
    assert.match(deps, /process\.env\.LOOPCTL_USER_KEY/);
    assert.match(deps, /exactKey: true/);
    assert.match(functionSource("runnerEnroll"), /enrollRunner\(args, runnerDeps\(\)\)/);
    assert.match(functionSource("runnerList"), /listRunners\(args, runnerDeps\(\)\)/);
    assert.match(functionSource("runnerRevoke"), /revokeRunner\(args, runnerDeps\(\)\)/);
    assert.match(functionSource("runnerPoolRead"), /runnerPool\(args, runnerDeps\(\)\)/);
  });

  test("runner_enroll declares max_sessions and runner_pool names the Postgres capacity", () => {
    const enroll = INDEX_SRC.slice(
      INDEX_SRC.indexOf('name: "runner_enroll",'),
      INDEX_SRC.indexOf('name: "runner_list",'),
    );
    assert.match(enroll, /max_sessions: \{/);

    const pool = INDEX_SRC.slice(
      INDEX_SRC.indexOf('name: "runner_pool",'),
      INDEX_SRC.indexOf('name: "runner_pool",') + 2000,
    );
    assert.match(pool, /reported_in_flight/);
    assert.match(pool, /reported_max_sessions/);
    assert.ok(README.includes("reported_in_flight"), "the README names reported_in_flight");
  });

  test("runner_enroll's description states the token-handling property and the undo", () => {
    const start = INDEX_SRC.indexOf('name: "runner_enroll",');
    const decl = INDEX_SRC.slice(start, INDEX_SRC.indexOf('name: "runner_list",'));
    assert.match(decl, /0600/);
    assert.match(decl, /NEVER returned/);
    assert.match(decl, /runner_revoke is the undo/);
  });
});
