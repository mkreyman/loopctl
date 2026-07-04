/**
 * Regression tests for the witness-protocol STH client (#298 + enhanced review):
 *
 *   - A bootstrap-grace 412 with `x-loopctl-current-sth` triggers a SINGLE
 *     transparent retry, anchored to error.code, that returns the success
 *     response (LOW-8).
 *   - A persisted STH is loaded on construction and sent on the FIRST request.
 *   - A corrupt / missing state file degrades gracefully to bootstrap + retry.
 *   - Persistence is per-(server + key): distinct keys never collide (HIGH-2).
 *   - The state write is atomic + symlink-safe (temp + `wx` + rename) (HIGH-1),
 *     and load refuses a symlink / foreign-owned file (HIGH-1).
 *   - Concurrent cold-start sends coalesce into ONE bootstrap (MEDIUM-6).
 *   - 409 is NOT auto-retried (MEDIUM-4).
 *
 * SINGLE SOURCE OF TRUTH: the logic lives in ../lib/witness-sth.js, imported by
 * BOTH the real server (index.js) and these tests. Wiring assertions at the end
 * pin that index.js delegates apiCall to a PER-KEY witness client.
 *
 * Run: node --test test/*.test.js
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import {
  isValidSth,
  bootstrapRetrySth,
  resolveSthStatePath,
  loadPersistedSth,
  persistSth,
  createWitnessClient,
  STH_STATE_PATH_ENV,
} from "../lib/witness-sth.js";

const INDEX_SRC = readFileSync(
  path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "index.js"),
  "utf8",
);

// Well-formed `<position>:<22-char base64url prefix>` STH values.
const STH_A = "5:AAAAAAAAAAAAAAAAAAAAAA";
const STH_B = "9:ZZZZZZZZZZZZZZZZZZZZZZ";

// Build a fake Response with a header bag, a status, and an optional JSON body.
function fakeResponse(status, headers = {}, body) {
  const lower = {};
  for (const [k, v] of Object.entries(headers)) lower[k.toLowerCase()] = v;
  return {
    status,
    headers: { get: (name) => lower[name.toLowerCase()] ?? null },
    clone: () => ({
      async json() {
        if (body === undefined) throw new Error("no body");
        return body;
      },
    }),
  };
}

// A fetch spy returning queued responses in order (last repeats), recording calls.
function spyFetch(responses) {
  const calls = [];
  const queue = [...responses];
  const fetchImpl = async (url, options) => {
    calls.push({ url, options });
    return queue.length > 1 ? queue.shift() : queue[0];
  };
  return { fetchImpl, calls };
}

// Minimal in-memory fs honoring `wx` (O_EXCL) and rename semantics.
function memFs(initial = {}, { uid = 1000, symlinks = new Set() } = {}) {
  const files = new Map(Object.entries(initial));
  const enoent = () => {
    const e = new Error("ENOENT");
    e.code = "ENOENT";
    return e;
  };
  return {
    files,
    readFileSync(p) {
      if (!files.has(p)) throw enoent();
      return files.get(p);
    },
    lstatSync(p) {
      if (!files.has(p) && !symlinks.has(p)) throw enoent();
      return { isSymbolicLink: () => symlinks.has(p), uid };
    },
    writeFileSync(p, data, opts) {
      if (opts && opts.flag === "wx" && files.has(p)) {
        const e = new Error("EEXIST");
        e.code = "EEXIST";
        throw e;
      }
      files.set(p, data);
    },
    renameSync(from, to) {
      if (!files.has(from)) throw enoent();
      files.set(to, files.get(from));
      files.delete(from);
    },
    unlinkSync(p) {
      files.delete(p);
    },
  };
}

const getuid1000 = () => 1000;

// ---------------------------------------------------------------------------
// isValidSth / bootstrapRetrySth
// ---------------------------------------------------------------------------

describe("isValidSth", () => {
  test("accepts a position + 22-char base64url prefix", () => {
    assert.equal(isValidSth(STH_A), true);
    assert.equal(isValidSth("0:AAAAAAAAAAAAAAAAAAAAAA"), true);
  });
  test("rejects malformed / non-base64url / non-string values", () => {
    assert.equal(isValidSth("5:"), false);
    assert.equal(isValidSth("5:AAAAAAAAAA++//AAAAAAAA"), false);
    assert.equal(isValidSth("x:AAAAAAAAAAAAAAAAAAAAAA"), false);
    assert.equal(isValidSth(null), false);
  });
});

describe("bootstrapRetrySth", () => {
  test("returns the STH only on a 412 with a valid current-sth header", () => {
    assert.equal(bootstrapRetrySth(412, STH_A), STH_A);
    assert.equal(bootstrapRetrySth(200, STH_A), null);
    assert.equal(bootstrapRetrySth(409, STH_A), null);
    assert.equal(bootstrapRetrySth(412, "not-an-sth"), null);
    assert.equal(bootstrapRetrySth(412, null), null);
  });
});

// ---------------------------------------------------------------------------
// resolveSthStatePath — per-(server + key) scoping (HIGH-2)
// ---------------------------------------------------------------------------

describe("resolveSthStatePath — per-key scoping (HIGH-2)", () => {
  const os = { tmpdir: () => "/tmp" };
  const p = { join: (...parts) => parts.join("/") };

  test("honors an explicit override", () => {
    const env = { [STH_STATE_PATH_ENV]: "/custom/sth.json" };
    assert.equal(resolveSthStatePath({ env, os, path: p, apiKey: "k" }), "/custom/sth.json");
  });

  test("derives a per-server temp path", () => {
    const env = { LOOPCTL_SERVER: "https://loopctl.com" };
    const result = resolveSthStatePath({ env, os, path: p, apiKey: "k1" });
    assert.match(result, /^\/tmp\/loopctl-mcp-sth-[0-9a-f]{16}\.json$/);
  });

  test("DIFFERENT keys against the SAME server never share a cache file", () => {
    const env = { LOOPCTL_SERVER: "https://loopctl.com" };
    const a = resolveSthStatePath({ env, os, path: p, apiKey: "key-A" });
    const b = resolveSthStatePath({ env, os, path: p, apiKey: "key-B" });
    assert.notEqual(a, b);
  });

  test("same (server, key) is stable; different servers differ", () => {
    const a = resolveSthStatePath({ env: { LOOPCTL_SERVER: "https://a" }, os, path: p, apiKey: "k" });
    const a2 = resolveSthStatePath({ env: { LOOPCTL_SERVER: "https://a/" }, os, path: p, apiKey: "k" });
    const b = resolveSthStatePath({ env: { LOOPCTL_SERVER: "https://b" }, os, path: p, apiKey: "k" });
    assert.equal(a, a2);
    assert.notEqual(a, b);
  });

  test("the api key never appears in plaintext in the derived path", () => {
    const env = { LOOPCTL_SERVER: "https://loopctl.com" };
    const secret = "lc_supersecretkey";
    const result = resolveSthStatePath({ env, os, path: p, apiKey: secret });
    assert.ok(!result.includes(secret));
  });
});

// ---------------------------------------------------------------------------
// loadPersistedSth — symlink / ownership guard (HIGH-1)
// ---------------------------------------------------------------------------

describe("loadPersistedSth", () => {
  test("returns the STH from a well-formed, regular, owned file", () => {
    const fs = memFs({ "/x": JSON.stringify({ sth: STH_A }) });
    assert.equal(loadPersistedSth("/x", { fs, getuid: getuid1000 }), STH_A);
  });

  test("returns null when the file is missing", () => {
    const fs = memFs({});
    assert.equal(loadPersistedSth("/x", { fs, getuid: getuid1000 }), null);
  });

  test("REFUSES a symlink at the path (CWE-59) → null", () => {
    const fs = memFs({ "/x": JSON.stringify({ sth: STH_A }) }, { symlinks: new Set(["/x"]) });
    assert.equal(loadPersistedSth("/x", { fs, getuid: getuid1000 }), null);
  });

  test("REFUSES a foreign-owned file → null", () => {
    const fs = memFs({ "/x": JSON.stringify({ sth: STH_A }) }, { uid: 4242 });
    assert.equal(loadPersistedSth("/x", { fs, getuid: getuid1000 }), null);
  });

  test("returns null for corrupt / shape-invalid content", () => {
    assert.equal(loadPersistedSth("/x", { fs: memFs({ "/x": "}{" }), getuid: getuid1000 }), null);
    assert.equal(
      loadPersistedSth("/x", { fs: memFs({ "/x": JSON.stringify({ sth: "garbage" }) }), getuid: getuid1000 }),
      null,
    );
  });
});

// ---------------------------------------------------------------------------
// persistSth — atomic + symlink-safe write (HIGH-1)
// ---------------------------------------------------------------------------

describe("persistSth — atomic + symlink-safe (HIGH-1)", () => {
  test("writes to a temp file with wx+0600 then renames over the target", () => {
    const events = [];
    const fs = {
      writeFileSync: (p, data, opts) => events.push({ op: "write", p, opts }),
      renameSync: (from, to) => events.push({ op: "rename", from, to }),
      unlinkSync: (p) => events.push({ op: "unlink", p }),
    };
    assert.equal(persistSth("/state.json", STH_A, { fs, pid: 4321 }), true);

    const write = events.find((e) => e.op === "write");
    const rename = events.find((e) => e.op === "rename");
    // Never writes directly to the target — a temp path derived from the pid.
    assert.notEqual(write.p, "/state.json");
    assert.match(write.p, /^\/state\.json\.4321\.[0-9a-f]+\.tmp$/);
    // Exclusive create (refuses a pre-planted symlink) + private mode.
    assert.equal(write.opts.flag, "wx");
    assert.equal(write.opts.mode, 0o600);
    // Atomic replace of the target ENTRY (never writes THROUGH a symlink there).
    assert.equal(rename.from, write.p);
    assert.equal(rename.to, "/state.json");
  });

  test("refuses to persist a shape-invalid STH (no write attempted)", () => {
    let wrote = false;
    const fs = { writeFileSync: () => (wrote = true), renameSync: () => {}, unlinkSync: () => {} };
    assert.equal(persistSth("/x", "garbage", { fs, pid: 1 }), false);
    assert.equal(wrote, false);
  });

  test("cleans up the temp file and returns false when rename fails", () => {
    let unlinked = null;
    const fs = {
      writeFileSync: () => {},
      renameSync: () => {
        throw new Error("EXDEV");
      },
      unlinkSync: (p) => (unlinked = p),
    };
    assert.equal(persistSth("/state.json", STH_A, { fs, pid: 7 }), false);
    assert.match(unlinked, /^\/state\.json\.7\.[0-9a-f]+\.tmp$/);
  });

  test("degrades to false when the exclusive create is refused (pre-planted temp)", () => {
    const fs = {
      writeFileSync: () => {
        const e = new Error("EEXIST");
        e.code = "EEXIST";
        throw e;
      },
      renameSync: () => {},
      unlinkSync: () => {},
    };
    assert.equal(persistSth("/state.json", STH_A, { fs, pid: 9 }), false);
  });
});

// ---------------------------------------------------------------------------
// createWitnessClient.send — transparent bootstrap-412 retry
// ---------------------------------------------------------------------------

describe("createWitnessClient.send — bootstrap-grace 412 retry", () => {
  const req = { url: "https://x/api/v1/tenants/me", method: "GET", headers: {} };

  test("a 412 (correct error.code) triggers exactly ONE retry that succeeds", async () => {
    const { fetchImpl, calls } = spyFetch([
      fakeResponse(412, { "x-loopctl-current-sth": STH_A }, {
        error: { code: "witness_bootstrap_already_consumed" },
      }),
      fakeResponse(200, { "x-loopctl-current-sth": STH_A }),
    ]);
    const client = createWitnessClient({ fetchImpl });

    const response = await client.send(req);

    assert.equal(response.status, 200);
    assert.equal(calls.length, 2);
    assert.equal(calls[0].options.headers["X-Loopctl-STH-Bootstrap"], "true");
    assert.equal(calls[1].options.headers["X-Loopctl-Last-Known-STH"], STH_A);
    assert.equal(client.getSTH(), STH_A);
  });

  test("anchors to error.code: a 412 with a DIFFERENT code is NOT retried (LOW-8)", async () => {
    const { fetchImpl, calls } = spyFetch([
      fakeResponse(412, { "x-loopctl-current-sth": STH_A }, {
        error: { code: "witness_header_malformed" },
      }),
      fakeResponse(200),
    ]);
    const client = createWitnessClient({ fetchImpl });

    const response = await client.send(req);

    assert.equal(response.status, 412);
    assert.equal(calls.length, 1);
  });

  test("falls back to status+header when the 412 body is unreadable", async () => {
    const { fetchImpl, calls } = spyFetch([
      fakeResponse(412, { "x-loopctl-current-sth": STH_A }), // no body → json() throws
      fakeResponse(200),
    ]);
    const client = createWitnessClient({ fetchImpl });

    const response = await client.send(req);
    assert.equal(response.status, 200);
    assert.equal(calls.length, 2);
  });

  test("does NOT retry a 412 lacking a valid current-sth header", async () => {
    const { fetchImpl, calls } = spyFetch([fakeResponse(412, {})]);
    const client = createWitnessClient({ fetchImpl });
    const response = await client.send(req);
    assert.equal(response.status, 412);
    assert.equal(calls.length, 1);
  });

  test("does NOT auto-retry a 409 witness_divergence (MEDIUM-4)", async () => {
    const { fetchImpl, calls } = spyFetch([
      fakeResponse(409, { "x-loopctl-current-sth": STH_B }, {
        error: { code: "witness_divergence" },
      }),
    ]);
    const client = createWitnessClient({ fetchImpl });

    const response = await client.send(req);
    // Surfaced, not retried — but the STH is cached so the NEXT request self-heals.
    assert.equal(response.status, 409);
    assert.equal(calls.length, 1);
    assert.equal(client.getSTH(), STH_B);
  });

  test("is bounded to a single retry even if the retry also 412s", async () => {
    const { fetchImpl, calls } = spyFetch([
      fakeResponse(412, { "x-loopctl-current-sth": STH_A }, {
        error: { code: "witness_bootstrap_already_consumed" },
      }),
      fakeResponse(412, { "x-loopctl-current-sth": STH_A }, {
        error: { code: "witness_bootstrap_already_consumed" },
      }),
      fakeResponse(200),
    ]);
    const client = createWitnessClient({ fetchImpl });

    const response = await client.send(req);
    assert.equal(response.status, 412);
    assert.equal(calls.length, 2);
  });
});

// ---------------------------------------------------------------------------
// Cold-start coalescing (MEDIUM-6)
// ---------------------------------------------------------------------------

describe("createWitnessClient — cold-start singleflight (MEDIUM-6)", () => {
  const req = { url: "https://x/api/v1/tenants/me", method: "GET", headers: {} };

  test("concurrent cold-start sends coalesce into ONE bootstrap", async () => {
    let served = 0;
    const bootstrapCalls = [];
    const fetchImpl = async (url, options) => {
      if (options.headers["X-Loopctl-STH-Bootstrap"] === "true") bootstrapCalls.push(1);
      served += 1;
      // First bootstrap attempt returns the consumed-412; everything else 200.
      if (served === 1) {
        return fakeResponse(412, { "x-loopctl-current-sth": STH_A }, {
          error: { code: "witness_bootstrap_already_consumed" },
        });
      }
      return fakeResponse(200, { "x-loopctl-current-sth": STH_A });
    };

    const client = createWitnessClient({ fetchImpl });

    // Fire three concurrent sends before any resolves.
    const results = await Promise.all([client.send(req), client.send(req), client.send(req)]);

    assert.deepEqual(results.map((r) => r.status), [200, 200, 200]);
    // Only the leader bootstrapped; followers waited and sent the learned header.
    assert.equal(bootstrapCalls.length, 1);
    assert.equal(client.getSTH(), STH_A);
  });
});

// ---------------------------------------------------------------------------
// Persistence lifecycle (with the in-memory fs)
// ---------------------------------------------------------------------------

describe("createWitnessClient — persistence", () => {
  const req = { url: "https://x/api/v1/tenants/me", method: "GET", headers: {} };

  test("a persisted STH is loaded and sent on the FIRST request (no bootstrap)", async () => {
    const { fetchImpl, calls } = spyFetch([fakeResponse(200)]);
    const fs = memFs({ "/state.json": JSON.stringify({ sth: STH_A }) });

    const client = createWitnessClient({ fetchImpl, statePath: "/state.json", fs, getuid: getuid1000 });
    assert.equal(client.getSTH(), STH_A);

    await client.send(req);
    assert.equal(calls[0].options.headers["X-Loopctl-Last-Known-STH"], STH_A);
    assert.equal(calls[0].options.headers["X-Loopctl-STH-Bootstrap"], undefined);
  });

  test("a corrupt state file degrades to bootstrap + retry, then re-persists", async () => {
    const { fetchImpl, calls } = spyFetch([
      fakeResponse(412, { "x-loopctl-current-sth": STH_A }, {
        error: { code: "witness_bootstrap_already_consumed" },
      }),
      fakeResponse(200),
    ]);
    const fs = memFs({ "/state.json": "corrupt-not-json" });

    const client = createWitnessClient({ fetchImpl, statePath: "/state.json", fs, getuid: getuid1000 });
    assert.equal(client.getSTH(), null);

    const response = await client.send(req);
    assert.equal(response.status, 200);
    assert.equal(calls.length, 2);
    // The relearned STH was persisted (atomically) for the next fresh process.
    assert.equal(JSON.parse(fs.files.get("/state.json")).sth, STH_A);
  });

  test("persists a newly-learned STH from a successful response", async () => {
    const { fetchImpl } = spyFetch([fakeResponse(200, { "x-loopctl-current-sth": STH_B })]);
    const fs = memFs({});
    const client = createWitnessClient({ fetchImpl, statePath: "/state.json", fs, getuid: getuid1000 });

    await client.send(req);
    assert.equal(client.getSTH(), STH_B);
    assert.equal(JSON.parse(fs.files.get("/state.json")).sth, STH_B);
  });

  test("an unwritable state file does not break request handling", async () => {
    const { fetchImpl } = spyFetch([fakeResponse(200, { "x-loopctl-current-sth": STH_B })]);
    const fs = {
      readFileSync: () => {
        throw new Error("ENOENT");
      },
      lstatSync: () => {
        throw new Error("ENOENT");
      },
      writeFileSync: () => {
        throw new Error("EROFS");
      },
      renameSync: () => {},
      unlinkSync: () => {},
    };
    const client = createWitnessClient({ fetchImpl, statePath: "/state.json", fs, getuid: getuid1000 });

    const response = await client.send(req);
    assert.equal(response.status, 200);
    assert.equal(client.getSTH(), STH_B); // cached in-memory despite failed write
  });
});

// ---------------------------------------------------------------------------
// Wiring: index.js delegates apiCall to a PER-KEY witness client
// ---------------------------------------------------------------------------

describe("#298 wiring: per-key witness client", () => {
  test("resolves a per-(server + key) state path", () => {
    assert.match(
      INDEX_SRC,
      /resolveSthStatePath\(\{ env: process\.env, os, path, apiKey \}\)/,
      "state path must be scoped by apiKey",
    );
  });

  test("keeps ONE witness client per api key (Map keyed by key)", () => {
    assert.match(INDEX_SRC, /const witnessClients = new Map\(\);/);
    assert.match(
      INDEX_SRC,
      /function witnessClientFor\(apiKey\) \{[\s\S]*?witnessClients\.get\(apiKey\)/,
      "witnessClientFor must look the client up by api key",
    );
  });

  test("apiCall sends through the per-key client and passes the symlink-safe fs", () => {
    assert.match(
      INDEX_SRC,
      /await witnessClientFor\(key\)\.send\(\{ url, method, headers, serializedBody \}\)/,
    );
    assert.match(
      INDEX_SRC,
      /WITNESS_FS = \{ readFileSync, writeFileSync, renameSync, lstatSync, unlinkSync \}/,
      "the witness fs must include renameSync + lstatSync for atomic + guarded I/O",
    );
    assert.ok(!/let lastKnownSTH = null;/.test(INDEX_SRC));
  });
});
