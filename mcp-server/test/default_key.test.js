/**
 * The default key falls back to the session's agent key, so a session holding only an agent
 * key (a holder session, the e2e two-sessions shape) can call default-key tools such as
 * list_stories instead of getting "No API key configured".
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { resolveDefaultKey } from "../lib/default-key.js";

const PKG_DIR = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const INDEX_SRC = readFileSync(path.join(PKG_DIR, "index.js"), "utf8");

const agent = () => "holder-credential";
const none = () => undefined;

test("an agent-key-only session sends its agent key", () => {
  assert.equal(resolveDefaultKey({ env: {}, agentKey: agent }), "holder-credential");
});

test("the earlier keys still win, in their old order", () => {
  const env = { LOOPCTL_API_KEY: "api", LOOPCTL_ORCH_KEY: "orch" };
  assert.equal(resolveDefaultKey({ env, keyOverride: "user", agentKey: agent }), "api");
  assert.equal(
    resolveDefaultKey({ env: { LOOPCTL_ORCH_KEY: "orch" }, keyOverride: "user", agentKey: agent }),
    "user",
  );
  assert.equal(resolveDefaultKey({ env: { LOOPCTL_ORCH_KEY: "orch" }, agentKey: agent }), "orch");
});

test("with no key at all it answers nothing, so apiCall reports the missing key", () => {
  assert.equal(resolveDefaultKey({ env: {}, agentKey: none }), undefined);
});

test("index.js resolves the default key through it, with the session's agentKey", () => {
  assert.match(
    INDEX_SRC,
    /function resolveKey\(keyOverride\) \{\s*return resolveDefaultKey\(\{ env: process\.env, keyOverride, agentKey \}\);/,
  );
});
