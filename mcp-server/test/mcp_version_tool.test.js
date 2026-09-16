/**
 * `mcp_version` — telling a stale surface from a missing tool (loopctl #846.7).
 *
 * MCP binds its tool list at session start, so from inside a session "this tool does not
 * exist" and "this tool exists and my process is older than it" are the same observation: a
 * name that is not in the surface. loopctl #861 is the measured case — `force_unclaim_story`
 * merged and deployed, and the session that needed it reported the capability as MISSING while
 * it was merely STALE.
 *
 * The version is what discriminates, so the thing these tests hold hardest is that the
 * reported version is READ FROM `package.json` rather than written down: a constant that
 * drifts from the package reports a version nobody is running, which is #846.7 one layer down.
 * The test reads `package.json` itself, so the assertion has two independent sources and a
 * hardcoded value cannot satisfy both.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

import { DISCOVERY_PATH, compareVersions, mcpVersion, packageVersion } from "../lib/mcp-version.js";
import { PKG_DIR, loadTools, stripComments } from "./tool-surface.js";

const INDEX_SRC = readFileSync(path.join(PKG_DIR, "index.js"), "utf8");
const README = readFileSync(path.join(PKG_DIR, "README.md"), "utf8");
const PKG = JSON.parse(readFileSync(path.join(PKG_DIR, "package.json"), "utf8"));

function fakeDiscovery(response) {
  const calls = [];
  return {
    calls,
    publicApiCall: async (method, apiPath, body) => {
      calls.push({ method, path: apiPath, body });
      return response;
    },
  };
}

describe("the running version is READ, never written down", () => {
  test("packageVersion() is package.json's version", () => {
    // Two independent reads of one fact. A constant substituted for the read satisfies
    // neither side of this, which is the mutation #846.7 is about.
    assert.equal(packageVersion(), PKG.version);
  });

  test("index.js derives SERVER_VERSION from it, so the handshake cannot drift", () => {
    // The MCP handshake already carries a version and the model never sees it; that is why
    // there is a tool at all. What must not happen is the two disagreeing.
    assert.match(
      INDEX_SRC,
      /const SERVER_VERSION = packageVersion\(\);/,
      "SERVER_VERSION is no longer derived from packageVersion()",
    );
    assert.match(
      INDEX_SRC,
      /name: "loopctl",\s*version: SERVER_VERSION,/,
      "the MCP handshake no longer reports SERVER_VERSION",
    );
  });

  test("the tool reports the version it is handed, and falls back to the package", async () => {
    const { publicApiCall } = fakeDiscovery({ mcp_server: { npm_version: "1.0.0" } });

    const injected = await mcpVersion({}, { publicApiCall, version: "9.9.9" });
    assert.equal(injected.running, "9.9.9");

    const derived = await mcpVersion({}, { publicApiCall });
    assert.equal(derived.running, PKG.version);
  });
});

describe("the comparison", () => {
  test("orders versions numerically, not lexically", () => {
    // "2.10.0" < "2.9.0" as strings, and that would report a newer client as behind.
    assert.equal(compareVersions("2.9.0", "2.10.0"), -1);
    assert.equal(compareVersions("2.10.0", "2.9.0"), 1);
    assert.equal(compareVersions("2.98.0", "2.98.0"), 0);
    assert.equal(compareVersions("2.98", "2.98.0"), 0, "a missing segment is zero");
  });

  test("declines to order what it cannot parse, rather than guessing", () => {
    assert.equal(compareVersions("2.98.0", "unknown"), null);
    assert.equal(compareVersions(undefined, "2.98.0"), null);
    assert.equal(compareVersions("2.98.0", ""), null);
  });

  test("reads the version loopctl publishes, from the unauthenticated discovery document", async () => {
    const { calls, publicApiCall } = fakeDiscovery({ mcp_server: { npm_version: "2.98.0" } });

    const result = await mcpVersion({}, { publicApiCall, version: "2.98.0" });

    assert.equal(calls.length, 1);
    assert.equal(calls[0].method, "GET");
    assert.equal(
      calls[0].path,
      "/.well-known/loopctl",
      "the discovery path moved; loopctl serves it at router.ex:113-118",
    );
    assert.equal(result.expected, "2.98.0");
    assert.equal(result.status, "current");
  });

  test("behind / ahead / current each get their own status and remedy", async () => {
    const cases = [
      ["2.97.0", "2.98.0", "behind", /\/mcp/],
      ["2.99.0", "2.98.0", "ahead", /checkout/],
      ["2.98.0", "2.98.0", "current", /genuinely does not exist/],
    ];

    for (const [running, expected, status, remedy] of cases) {
      const { publicApiCall } = fakeDiscovery({ mcp_server: { npm_version: expected } });
      const result = await mcpVersion({}, { publicApiCall, version: running });

      assert.equal(result.status, status, `${running} against ${expected}`);
      assert.match(result.remedy, remedy);
    }
  });

  test("the `behind` remedy says reconnect and says NOT to retry", async () => {
    // The whole point of the status. A retry cannot help: the tool list is fixed for the life
    // of the process, so the same call answers the same way for ever.
    const { publicApiCall } = fakeDiscovery({ mcp_server: { npm_version: "2.99.0" } });
    const result = await mcpVersion({}, { publicApiCall, version: "2.98.0" });

    assert.match(result.remedy, /DO NOT RETRY THE CALL/);
    assert.match(result.remedy, /restart the session/);
  });
});

describe("it answers when loopctl does not", () => {
  test("a failed discovery request yields `unknown` WITH the running version", async () => {
    // Half the answer is the half the caller most needs, and a version report that fails when
    // the network does would be useless in the situation it exists for.
    const { publicApiCall } = fakeDiscovery({ error: true, status: 503, body: "nope" });

    const result = await mcpVersion({}, { publicApiCall, version: "2.98.0" });

    assert.equal(result.status, "unknown");
    assert.equal(result.running, "2.98.0");
    assert.equal(result.expected, null);
    assert.match(result.detail, /discovery request failed/);
    assert.match(result.remedy, /says nothing about whether a missing tool exists/);
    assert.equal(result.error, undefined, "a version report must not be an error result");
  });

  test("the transport failure's CAUSE reaches the detail, not just `status 0`", async () => {
    // The scenario this tool exists for: a session where nothing else answers. `status 0` says
    // only that no server replied — `publicApiCall` stamps it on every local failure and puts
    // the reason in `body` (`index.js`, its catch around `fetch`) — so a typo'd LOOPCTL_SERVER,
    // a dead network and a slow one were one indistinguishable message.
    const { publicApiCall } = fakeDiscovery({
      error: true,
      status: 0,
      body: "Network error: fetch failed (getaddrinfo ENOTFOUND loopctl.invalid)",
    });

    const result = await mcpVersion({}, { publicApiCall, version: "2.98.0" });

    assert.equal(result.status, "unknown");
    assert.equal(result.running, "2.98.0", "the half that always answers must still answer");
    assert.match(result.detail, /status 0/);
    assert.match(result.detail, /ENOTFOUND/, "the cause was discarded");
  });

  test("a non-string body is rendered rather than dropped or thrown on", async () => {
    // An HTTP failure carries loopctl's own parsed error body, and a version report that
    // throws is worse than one that says little: this tool must always answer.
    const { publicApiCall } = fakeDiscovery({
      error: true,
      status: 503,
      body: { error: { message: "upstream unavailable" } },
    });

    const result = await mcpVersion({}, { publicApiCall, version: "2.98.0" });

    assert.match(result.detail, /upstream unavailable/);

    const circular = { error: "x" };
    circular.self = circular;
    const unserialisable = fakeDiscovery({ error: true, status: 0, body: circular });
    const survived = await mcpVersion(
      {},
      { publicApiCall: unserialisable.publicApiCall, version: "2.98.0" },
    );

    assert.equal(survived.status, "unknown");
    assert.match(survived.detail, /status 0/);
  });

  test("a discovery document without the field yields `unknown`, and says which field", async () => {
    const { publicApiCall } = fakeDiscovery({ spec_version: "2" });

    const result = await mcpVersion({}, { publicApiCall, version: "2.98.0" });

    assert.equal(result.status, "unknown");
    assert.match(result.detail, /mcp_server\.npm_version/);
  });

  test("names the deployment it compared against", async () => {
    // `expected` is that deployment's own tree, so a session pointed at a staging
    // LOOPCTL_SERVER is comparing against staging. A verdict with no server named cannot
    // be acted on.
    const { publicApiCall } = fakeDiscovery({ mcp_server: { npm_version: "2.98.0" } });

    const result = await mcpVersion(
      {},
      { publicApiCall, version: "2.98.0", baseUrl: "https://staging.example" },
    );

    assert.equal(result.server, "https://staging.example");
  });
});

describe("the wiring in index.js", () => {
  test("mcp_version is declared, dispatched to its own handler, and documented", () => {
    assert.ok(INDEX_SRC.includes('name: "mcp_version"'), "mcp_version is not declared");
    assert.match(
      INDEX_SRC,
      /case "mcp_version":\s*return await mcpVersion\(/,
      "mcp_version is not dispatched to mcpVersion()",
    );
    assert.ok(
      README.split("\n").some((line) => line.startsWith("| `mcp_version` |")),
      "mcp_version has no row in a README tool table",
    );
  });

  test("its handler sends NO key, and hands over the derived version", () => {
    // `publicApiCall` sends no Authorization header (`index.js`); the discovery endpoint is
    // unauthenticated. If this ever moved to `apiCall`, the tool would stop answering in
    // exactly the sessions it is for — one with no key configured, or the wrong one.
    const start = INDEX_SRC.indexOf("async function mcpVersion(");
    assert.ok(start > -1, "the mcp_version handler was not found");

    const end = INDEX_SRC.indexOf("\nasync function ", start + 1);
    assert.ok(end > start, "the handler has no following function to bound it");

    const handler = stripComments(INDEX_SRC.slice(start, end));

    assert.match(handler, /publicApiCall/, "it no longer uses the unauthenticated helper");
    assert.match(handler, /version: SERVER_VERSION/, "it does not report the derived version");
    assert.ok(
      !/\bapiCall\b(?!s)/.test(handler.replace(/publicApiCall/g, "")),
      "it reaches for the authenticated apiCall, which needs a key this tool must not require",
    );
  });

  test("takes no parameters — there is nothing for a caller to get wrong", () => {
    const tool = loadTools().find((t) => t.name === "mcp_version");

    assert.ok(tool);
    assert.deepEqual(Object.keys(tool.inputSchema.properties), []);
  });

  test("its description states the discriminator and the remedy an operator reads", () => {
    // AC-3 of #846.7: the discriminator has to be where an operator actually looks, which is
    // the tool description, not a doc.
    const tool = loadTools().find((t) => t.name === "mcp_version");

    assert.match(tool.description, /NEVER A RETRY/);
    assert.match(tool.description, /\/mcp/);
    assert.match(
      tool.description,
      /genuinely is not in this version/,
      "it does not say what `current` lets a caller conclude about a tool it cannot see",
    );
    assert.match(
      tool.description,
      /predates 2\.99\.0/,
      "it does not say what this tool's OWN absence means",
    );
  });
});

describe("the discovery path", () => {
  test("is the one loopctl serves", () => {
    assert.equal(DISCOVERY_PATH, "/.well-known/loopctl");
  });
});
