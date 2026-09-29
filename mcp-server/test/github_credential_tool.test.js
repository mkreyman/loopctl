/**
 * `github_credential` / `set_github_credential` / `clear_github_credential` — the MCP half
 * of `GET|PUT|DELETE /api/v1/tenants/me/github-credential` (#936).
 *
 * The last block source-pins index.js: a tool declared and not dispatched, or dispatched
 * to the wrong handler, is the endpoint-without-a-tool defect inside the MCP server.
 *
 * Run: node --test test/*.test.js
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import {
  GITHUB_CREDENTIAL_PATH,
  clearGithubCredential,
  githubCredential,
  setGithubCredential,
} from "../lib/github-credential.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");
const README = readFileSync(path.join(DIR, "..", "README.md"), "utf8");

function fakeApi(response = { ok: true }) {
  const calls = [];
  const apiCall = async (method, apiPath, body) => {
    calls.push({ method, path: apiPath, body });
    return response;
  };
  return { calls, apiCall };
}

describe("github credential tools", () => {
  test("the path is the route loopctl serves", () => {
    assert.equal(GITHUB_CREDENTIAL_PATH, "/api/v1/tenants/me/github-credential");
  });

  test("github_credential GETs with no body", async () => {
    const { calls, apiCall } = fakeApi();
    await githubCredential({}, { apiCall });
    assert.deepEqual(calls, [{ method: "GET", path: GITHUB_CREDENTIAL_PATH, body: null }]);
  });

  test("set_github_credential PUTs the token and nothing else", async () => {
    const { calls, apiCall } = fakeApi();
    await setGithubCredential({ token: "github_pat_abc", extra: "x" }, { apiCall });
    assert.deepEqual(calls, [
      { method: "PUT", path: GITHUB_CREDENTIAL_PATH, body: { token: "github_pat_abc" } },
    ]);
  });

  test("set_github_credential refuses a missing or blank token locally", async () => {
    for (const args of [{}, { token: "  " }, { token: 7 }]) {
      const { calls, apiCall } = fakeApi();
      const result = await setGithubCredential(args, { apiCall });
      assert.equal(calls.length, 0);
      assert.equal(result.error, true);
    }
  });

  test("clear_github_credential DELETEs with no body", async () => {
    const { calls, apiCall } = fakeApi();
    await clearGithubCredential({}, { apiCall });
    assert.deepEqual(calls, [{ method: "DELETE", path: GITHUB_CREDENTIAL_PATH, body: null }]);
  });
});

describe("index.js wiring", () => {
  for (const [tool, handler] of [
    ["github_credential", "githubCredential"],
    ["set_github_credential", "setGithubCredential"],
    ["clear_github_credential", "clearGithubCredential"],
  ]) {
    test(`${tool} is declared, dispatched to ${handler}, and in the README`, () => {
      assert.match(INDEX_SRC, new RegExp(`name: "${tool}",`));
      assert.match(
        INDEX_SRC,
        new RegExp(`case "${tool}":\\s*return await ${handler}\\(args\\);`),
      );
      assert.match(README, new RegExp(`\\| \`${tool}\` \\|`));
    });
  }

  test("every handler pins the exact user key", () => {
    assert.match(
      INDEX_SRC,
      /function userKeyApi\(\) \{[\s\S]*?process\.env\.LOOPCTL_USER_KEY, \{ exactKey: true \}/,
    );
  });
});
