/**
 * TC-52.8.8 (US-52.8): every apiCall names this package in `x-loopctl-client`, and a 426 from
 * loopctl reaches the tool caller as an error naming the minimum and the remedy.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import {
  CLIENT_HEADER,
  clientHeaderValue,
  incompatibleClientError,
} from "../lib/client-version.js";
import { packageVersion } from "../lib/mcp-version.js";

const PKG_DIR = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const INDEX_SRC = readFileSync(path.join(PKG_DIR, "index.js"), "utf8");
const PKG_VERSION = JSON.parse(readFileSync(path.join(PKG_DIR, "package.json"), "utf8")).version;

function apiCallBody() {
  const start = INDEX_SRC.indexOf("async function apiCall(");
  const end = INDEX_SRC.indexOf("async function publicApiCall(");
  assert.ok(start > 0 && end > start, "apiCall and publicApiCall are both in index.js");
  return INDEX_SRC.slice(start, end);
}

describe("the header", () => {
  test("names the mcp component and this package's version", () => {
    assert.equal(CLIENT_HEADER, "x-loopctl-client");
    assert.equal(clientHeaderValue(packageVersion()), `mcp/${PKG_VERSION}`);
  });

  test("apiCall sends it on every request, from SERVER_VERSION", () => {
    const body = apiCallBody();
    assert.match(body, /\[CLIENT_HEADER\]: clientHeaderValue\(SERVER_VERSION\)/);
    assert.match(INDEX_SRC, /const SERVER_VERSION = packageVersion\(\);/);
  });

  test("is not the analytics header, which never gates anything", () => {
    assert.notEqual(CLIENT_HEADER, "x-loopctl-client-context");
  });
});

describe("a 426", () => {
  test("is an error naming the minimum, the version sent, and the remedy", () => {
    const out = incompatibleClientError(
      { error: { code: "incompatible_client_version", component: "mcp", minimum: "9.0.0" } },
      "3.19.1",
    );

    assert.equal(out.error, true);
    assert.equal(out.status, 426);
    assert.equal(out.body.code, "incompatible_client_version");
    assert.equal(out.body.minimum, "9.0.0");
    assert.equal(out.body.sent, "3.19.1");
    assert.match(out.body.message, /needs 9\.0\.0 or later/);
    assert.match(out.body.message, /\/mcp/);
    assert.match(out.body.message, /restart the session/);
    assert.match(out.body.message, /published on npm/);
  });

  test("a body without a minimum still says what to do", () => {
    const out = incompatibleClientError("<html>gateway</html>", "3.19.1");
    assert.equal(out.status, 426);
    assert.match(out.body.message, /a newer version or later/);
  });

  test("apiCall maps it before the generic error branch", () => {
    const body = apiCallBody();
    const mapped = body.indexOf("response.status === 426");
    const generic = body.indexOf("if (!response.ok)");
    assert.ok(mapped > 0, "apiCall maps a 426");
    assert.ok(mapped < generic, "the 426 is mapped before the generic error branch");
    assert.match(body, /incompatibleClientError\(responseBody, SERVER_VERSION\)/);
  });
});
