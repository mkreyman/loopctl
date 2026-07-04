/**
 * Regression tests for the witness-protocol STH client (#298):
 *
 *   - A bootstrap-grace 412 that carries `x-loopctl-current-sth` triggers a
 *     SINGLE transparent retry with that STH and returns the success response.
 *   - A persisted STH is loaded on construction and sent as
 *     `X-Loopctl-Last-Known-STH` on the FIRST request (no bootstrap 412).
 *   - A corrupt / missing state file degrades gracefully to bootstrap + retry.
 *   - The retry is bounded to a single attempt (never a loop).
 *   - Pure helpers: isValidSth / bootstrapRetrySth / resolveSthStatePath /
 *     loadPersistedSth / persistSth.
 *
 * SINGLE SOURCE OF TRUTH: the retry + persistence logic lives in
 * ../lib/witness-sth.js, imported by BOTH the real server (index.js) and these
 * tests, so a regression in that logic fails CI. A wiring assertion at the end
 * pins that index.js actually delegates apiCall to the shared witness client.
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

// A well-formed `<position>:<22-char base64url prefix>` STH value.
const STH_A = "5:AAAAAAAAAAAAAAAAAAAAAA";
const STH_B = "9:ZZZZZZZZZZZZZZZZZZZZZZ";

// Build a fake Response with a header bag and a status.
function fakeResponse(status, headers = {}) {
  const lower = {};
  for (const [k, v] of Object.entries(headers)) lower[k.toLowerCase()] = v;
  return {
    status,
    headers: { get: (name) => lower[name.toLowerCase()] ?? null },
  };
}

// A fetch spy that returns queued responses in order and records each call.
function spyFetch(responses) {
  const calls = [];
  const queue = [...responses];
  const fetchImpl = async (url, options) => {
    calls.push({ url, options });
    return queue.length > 1 ? queue.shift() : queue[0];
  };
  return { fetchImpl, calls };
}

// ---------------------------------------------------------------------------
// isValidSth
// ---------------------------------------------------------------------------

describe("isValidSth", () => {
  test("accepts a position + 22-char base64url prefix", () => {
    assert.equal(isValidSth(STH_A), true);
    assert.equal(isValidSth("0:AAAAAAAAAAAAAAAAAAAAAA"), true);
    assert.equal(isValidSth("123456:_-AAAAAAAAAAAAAAAAAAAA"), true);
  });

  test("rejects malformed / short / non-base64url / non-string values", () => {
    assert.equal(isValidSth("5:"), false);
    assert.equal(isValidSth("5:abc"), false);
    assert.equal(isValidSth("5:" + "A".repeat(23)), false);
    assert.equal(isValidSth("5:AAAAAAAAAA++//AAAAAAAA"), false); // standard, not url
    assert.equal(isValidSth("x:AAAAAAAAAAAAAAAAAAAAAA"), false);
    assert.equal(isValidSth(null), false);
    assert.equal(isValidSth(undefined), false);
    assert.equal(isValidSth(5), false);
  });
});

// ---------------------------------------------------------------------------
// bootstrapRetrySth
// ---------------------------------------------------------------------------

describe("bootstrapRetrySth", () => {
  test("returns the STH on a 412 carrying a valid current-sth header", () => {
    assert.equal(bootstrapRetrySth(412, STH_A), STH_A);
  });

  test("returns null for non-412 statuses even with a valid STH", () => {
    assert.equal(bootstrapRetrySth(200, STH_A), null);
    assert.equal(bootstrapRetrySth(409, STH_A), null);
    assert.equal(bootstrapRetrySth(500, STH_A), null);
  });

  test("returns null for a 412 without / with a malformed STH header", () => {
    assert.equal(bootstrapRetrySth(412, null), null);
    assert.equal(bootstrapRetrySth(412, undefined), null);
    assert.equal(bootstrapRetrySth(412, "not-an-sth"), null);
  });
});

// ---------------------------------------------------------------------------
// resolveSthStatePath
// ---------------------------------------------------------------------------

describe("resolveSthStatePath", () => {
  const os = { tmpdir: () => "/tmp" };
  const path = { join: (...p) => p.join("/") };

  test("honors an explicit LOOPCTL_STH_STATE_PATH override", () => {
    const env = { [STH_STATE_PATH_ENV]: "/custom/sth.json" };
    assert.equal(resolveSthStatePath({ env, os, path }), "/custom/sth.json");
  });

  test("ignores a blank override and derives a per-server temp path", () => {
    const env = { [STH_STATE_PATH_ENV]: "   ", LOOPCTL_SERVER: "https://loopctl.com" };
    const result = resolveSthStatePath({ env, os, path });
    assert.match(result, /^\/tmp\/loopctl-mcp-sth-[0-9a-f]{16}\.json$/);
  });

  test("derives distinct files for distinct servers", () => {
    const a = resolveSthStatePath({ env: { LOOPCTL_SERVER: "https://a.example" }, os, path });
    const b = resolveSthStatePath({ env: { LOOPCTL_SERVER: "https://b.example" }, os, path });
    assert.notEqual(a, b);
  });

  test("is stable for the same server (ignoring a trailing slash)", () => {
    const a = resolveSthStatePath({ env: { LOOPCTL_SERVER: "https://a.example" }, os, path });
    const b = resolveSthStatePath({ env: { LOOPCTL_SERVER: "https://a.example/" }, os, path });
    assert.equal(a, b);
  });
});

// ---------------------------------------------------------------------------
// loadPersistedSth / persistSth (injected fs, never touches real disk)
// ---------------------------------------------------------------------------

describe("loadPersistedSth", () => {
  test("returns the STH from a well-formed state file", () => {
    const readFileSync = () => JSON.stringify({ sth: STH_A, updated_at: "x" });
    assert.equal(loadPersistedSth("/x", { readFileSync }), STH_A);
  });

  test("returns null when the file is missing (readFileSync throws)", () => {
    const readFileSync = () => {
      throw new Error("ENOENT");
    };
    assert.equal(loadPersistedSth("/x", { readFileSync }), null);
  });

  test("returns null for non-JSON / corrupt content", () => {
    const readFileSync = () => "}{ not json";
    assert.equal(loadPersistedSth("/x", { readFileSync }), null);
  });

  test("returns null when the stored STH is shape-invalid", () => {
    const readFileSync = () => JSON.stringify({ sth: "garbage" });
    assert.equal(loadPersistedSth("/x", { readFileSync }), null);
  });
});

describe("persistSth", () => {
  test("writes a valid STH and reports success", () => {
    let written;
    const writeFileSync = (p, data) => {
      written = { p, data };
    };
    assert.equal(persistSth("/x", STH_A, { writeFileSync }), true);
    assert.equal(written.p, "/x");
    assert.deepEqual(JSON.parse(written.data).sth, STH_A);
  });

  test("refuses to persist a shape-invalid STH", () => {
    let called = false;
    const writeFileSync = () => {
      called = true;
    };
    assert.equal(persistSth("/x", "garbage", { writeFileSync }), false);
    assert.equal(called, false);
  });

  test("degrades to false when the write throws (read-only dir, full disk)", () => {
    const writeFileSync = () => {
      throw new Error("EROFS");
    };
    assert.equal(persistSth("/x", STH_A, { writeFileSync }), false);
  });
});

// ---------------------------------------------------------------------------
// createWitnessClient.send — the transparent bootstrap-412 retry
// ---------------------------------------------------------------------------

describe("createWitnessClient.send — bootstrap-grace 412 retry", () => {
  const req = { url: "https://x/api/v1/tenants/me", method: "GET", headers: {} };

  test("a 412 carrying current-sth triggers exactly ONE retry that succeeds", async () => {
    const { fetchImpl, calls } = spyFetch([
      fakeResponse(412, { "x-loopctl-current-sth": STH_A }),
      fakeResponse(200, { "x-loopctl-current-sth": STH_A }),
    ]);
    const client = createWitnessClient({ fetchImpl });

    const response = await client.send(req);

    // Returns the SUCCESS response, not the 412.
    assert.equal(response.status, 200);
    // Exactly two attempts — a single bounded retry, never a loop.
    assert.equal(calls.length, 2);
    // First attempt bootstrapped (no cached STH); retry sent the learned STH.
    assert.equal(calls[0].options.headers["X-Loopctl-STH-Bootstrap"], "true");
    assert.equal(calls[0].options.headers["X-Loopctl-Last-Known-STH"], undefined);
    assert.equal(calls[1].options.headers["X-Loopctl-Last-Known-STH"], STH_A);
    assert.equal(calls[1].options.headers["X-Loopctl-STH-Bootstrap"], undefined);
    // The learned STH is cached for subsequent requests.
    assert.equal(client.getSTH(), STH_A);
  });

  test("does NOT retry a 412 that lacks a valid current-sth header", async () => {
    const { fetchImpl, calls } = spyFetch([fakeResponse(412, {})]);
    const client = createWitnessClient({ fetchImpl });

    const response = await client.send(req);

    assert.equal(response.status, 412);
    assert.equal(calls.length, 1);
  });

  test("is bounded to a single retry even if the retry also 412s", async () => {
    // Server keeps 412-ing (pathological): the client must retry exactly once
    // and then surface the 412 rather than looping forever.
    const { fetchImpl, calls } = spyFetch([
      fakeResponse(412, { "x-loopctl-current-sth": STH_A }),
      fakeResponse(412, { "x-loopctl-current-sth": STH_A }),
      fakeResponse(200),
    ]);
    const client = createWitnessClient({ fetchImpl });

    const response = await client.send(req);

    assert.equal(response.status, 412);
    assert.equal(calls.length, 2);
  });

  test("does not retry a plain 200 and caches its STH", async () => {
    const { fetchImpl, calls } = spyFetch([
      fakeResponse(200, { "x-loopctl-current-sth": STH_B }),
    ]);
    const client = createWitnessClient({ fetchImpl });

    const response = await client.send(req);

    assert.equal(response.status, 200);
    assert.equal(calls.length, 1);
    assert.equal(client.getSTH(), STH_B);
  });
});

// ---------------------------------------------------------------------------
// createWitnessClient — startup persistence load
// ---------------------------------------------------------------------------

describe("createWitnessClient — persisted STH loaded on construction", () => {
  const req = { url: "https://x/api/v1/tenants/me", method: "GET", headers: {} };

  test("a persisted STH is loaded and sent on the FIRST request (no bootstrap)", async () => {
    const { fetchImpl, calls } = spyFetch([fakeResponse(200)]);
    const readFileSync = () => JSON.stringify({ sth: STH_A });

    const client = createWitnessClient({
      fetchImpl,
      statePath: "/state.json",
      readFileSync,
    });

    assert.equal(client.getSTH(), STH_A);

    await client.send(req);

    // First request carried the real header — never tripped the bootstrap path.
    assert.equal(calls[0].options.headers["X-Loopctl-Last-Known-STH"], STH_A);
    assert.equal(calls[0].options.headers["X-Loopctl-STH-Bootstrap"], undefined);
  });

  test("a corrupt state file degrades to bootstrap + transparent retry", async () => {
    const { fetchImpl, calls } = spyFetch([
      fakeResponse(412, { "x-loopctl-current-sth": STH_A }),
      fakeResponse(200),
    ]);
    const readFileSync = () => "corrupt-not-json";
    let persisted = null;
    const writeFileSync = (p, data) => {
      persisted = JSON.parse(data).sth;
    };

    const client = createWitnessClient({
      fetchImpl,
      statePath: "/state.json",
      readFileSync,
      writeFileSync,
    });

    // Corrupt file → no STH loaded → first request bootstraps.
    assert.equal(client.getSTH(), null);

    const response = await client.send(req);

    assert.equal(response.status, 200);
    assert.equal(calls.length, 2);
    assert.equal(calls[0].options.headers["X-Loopctl-STH-Bootstrap"], "true");
    assert.equal(calls[1].options.headers["X-Loopctl-Last-Known-STH"], STH_A);
    // The relearned STH was persisted for the next fresh process.
    assert.equal(persisted, STH_A);
  });

  test("persists a newly-learned STH from a successful response", async () => {
    const { fetchImpl } = spyFetch([
      fakeResponse(200, { "x-loopctl-current-sth": STH_B }),
    ]);
    let persisted = null;
    const writeFileSync = (p, data) => {
      persisted = JSON.parse(data).sth;
    };
    const readFileSync = () => {
      throw new Error("ENOENT");
    };

    const client = createWitnessClient({
      fetchImpl,
      statePath: "/state.json",
      readFileSync,
      writeFileSync,
    });

    await client.send(req);

    assert.equal(persisted, STH_B);
    assert.equal(client.getSTH(), STH_B);
  });

  test("an unwritable state file does not break request handling", async () => {
    const { fetchImpl } = spyFetch([
      fakeResponse(200, { "x-loopctl-current-sth": STH_B }),
    ]);
    const readFileSync = () => {
      throw new Error("ENOENT");
    };
    const writeFileSync = () => {
      throw new Error("EROFS");
    };

    const client = createWitnessClient({
      fetchImpl,
      statePath: "/state.json",
      readFileSync,
      writeFileSync,
    });

    const response = await client.send(req);

    // Request still succeeds; STH cached in-memory despite the failed write.
    assert.equal(response.status, 200);
    assert.equal(client.getSTH(), STH_B);
  });
});

// ---------------------------------------------------------------------------
// Wiring: index.js delegates apiCall to the shared witness client
// ---------------------------------------------------------------------------

describe("#298 wiring: index.js apiCall uses the shared witness client", () => {
  test("constructs a witness client from resolveSthStatePath + fs", () => {
    assert.match(
      INDEX_SRC,
      /const STH_STATE_PATH = resolveSthStatePath\(\{ env: process\.env, os, path \}\);/,
      "index.js must resolve the STH state path via the shared helper",
    );
    assert.match(
      INDEX_SRC,
      /createWitnessClient\(\{[\s\S]*?statePath: STH_STATE_PATH,[\s\S]*?readFileSync,[\s\S]*?writeFileSync,[\s\S]*?\}\)/,
      "index.js must build the witness client with the persistence fs handles",
    );
  });

  test("apiCall delegates the request to witnessClient.send", () => {
    assert.match(
      INDEX_SRC,
      /await witnessClient\.send\(\{ url, method, headers, serializedBody \}\)/,
      "apiCall must send through the witness client (which owns STH + retry)",
    );
    // The old in-line STH caching / manual fetch must be gone from apiCall.
    assert.ok(
      !/let lastKnownSTH = null;/.test(INDEX_SRC),
      "index.js must not keep a module-level in-memory-only lastKnownSTH",
    );
  });
});
