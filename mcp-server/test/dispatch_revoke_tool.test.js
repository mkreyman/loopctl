/**
 * `revoke_dispatch` — the MCP half of `POST /api/v1/dispatches/:id/revoke`.
 *
 * The endpoint exists because `Loopctl.Dispatches.revoke/2` was reachable by nothing
 * outside the app; the TOOL exists because an endpoint with no tool is the same defect
 * one layer out — `curl` at loopctl is refused by the fleet's guardrail, so a route with
 * no tool is a verb only a shell on the production node can use.
 *
 * The last block source-pins index.js, because a tool declared and not dispatched (or
 * dispatched to the wrong handler) is exactly that defect INSIDE the MCP server, and it
 * is invisible until someone tries to use it.
 *
 * Run: node --test test/*.test.js
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { revokeDispatch, revokeDispatchPath } from "../lib/dispatch-revoke.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");
const README = readFileSync(path.join(DIR, "..", "README.md"), "utf8");

const DISPATCH_ID = "9d19c86d-d491-4a4d-b188-6b53beee4a17";

function fakeApi(response = { ok: true }) {
  const calls = [];
  const apiCall = async (method, apiPath, body) => {
    calls.push({ method, path: apiPath, body });
    return response;
  };
  return { calls, apiCall };
}

describe("revoke_dispatch", () => {
  test("POSTs to the dispatch's revoke route with no body", async () => {
    const { calls, apiCall } = fakeApi();

    await revokeDispatch({ dispatch_id: DISPATCH_ID }, { apiCall });

    assert.equal(calls.length, 1);
    assert.equal(calls[0].method, "POST");
    assert.equal(calls[0].path, `/api/v1/dispatches/${DISPATCH_ID}/revoke`);
    assert.equal(calls[0].body, null);
  });

  test("the path it builds is the route loopctl serves", () => {
    assert.equal(revokeDispatchPath(DISPATCH_ID), `/api/v1/dispatches/${DISPATCH_ID}/revoke`);
  });

  test("returns whatever the API answered, unedited", async () => {
    const payload = { data: { revoked_count: 2 } };
    const { apiCall } = fakeApi(payload);

    assert.deepEqual(await revokeDispatch({ dispatch_id: DISPATCH_ID }, { apiCall }), payload);
  });
});

describe("local refusals — before any call", () => {
  test("a missing dispatch_id sends nothing", async () => {
    const { calls, apiCall } = fakeApi();

    const result = await revokeDispatch({}, { apiCall });

    assert.equal(result.error, true);
    assert.match(result.body, /`dispatch_id` is required/);
    assert.equal(calls.length, 0, "a refused call must not reach the API");
  });

  test("a malformed dispatch_id sends nothing and does NOT echo the value", async () => {
    // Two reasons this is refused locally rather than left to the server. A path id that
    // is not a UUID reaches `Ecto.Query.CastError` and answers 404 — the SAME 404 a
    // well-formed id naming no dispatch gets, so two problems with opposite remedies had
    // one indistinguishable answer. And a malformed id is often a token pasted into the
    // wrong argument, while a tool result lands in the transcript.
    const { calls, apiCall } = fakeApi();
    const secret = "loopctl_sk_notarealkeybutshapedlikeone";

    const result = await revokeDispatch({ dispatch_id: secret }, { apiCall });

    assert.equal(result.error, true);
    assert.match(result.body, /must be a UUID/);
    assert.ok(!result.body.includes(secret), "the refusal must never echo the value");
    assert.equal(calls.length, 0);
  });

  test("an empty or non-string dispatch_id is refused", async () => {
    const { calls, apiCall } = fakeApi();

    for (const bad of ["", "   ", 42, null, undefined, {}]) {
      const result = await revokeDispatch({ dispatch_id: bad }, { apiCall });
      assert.equal(result.error, true, `${JSON.stringify(bad)} should be refused`);
    }

    assert.equal(calls.length, 0);
  });
});

describe("the tool description states what the endpoint refuses", () => {
  // The repo's rule: a session reads the description instead of the controller, so what
  // it says about refusals and about BLAST RADIUS is load-bearing text and not prose.
  const start = INDEX_SRC.indexOf('name: "revoke_dispatch"');
  const end = INDEX_SRC.indexOf('required: ["dispatch_id"]', start);
  const declaration = INDEX_SRC.slice(start, end);

  test("it is declared at all", () => {
    assert.ok(start > -1, "revoke_dispatch is not declared in index.js");
    assert.ok(end > start, "the revoke_dispatch declaration has no inputSchema to bound it");
  });

  test("it says the revoke CASCADES, in all three places the claim has to appear", () => {
    // The single most surprising thing about the endpoint. `Dispatches.revoke/2` matches
    // `d.id == ^dispatch_id or ^dispatch_id in d.lineage_path`, so revoking a root revokes
    // the tree. A description that omitted this would invite exactly that.
    //
    // Three SEPARATE assertions, not one alternation. The first version was
    // `/subtree|descendant/i`, and `bin/mutate.sh` came back exit 1: deleting the headline
    // left the passing mention further down, so the loose match could not tell "the warning
    // is here" from "a word from it survives somewhere". Each claim is now pinned where a
    // reader actually meets it — the headline, the mechanism, and the parameter's own
    // description, which is the one an LLM reads while filling the argument in.
    assert.match(declaration, /WHOLE SUBTREE/, "the headline no longer says it cascades");
    assert.match(declaration, /lineage_path/, "it no longer says WHY it cascades");
    assert.match(
      declaration,
      /every descendant/,
      "the dispatch_id parameter no longer says what revoking it reaches",
    );
  });

  test("it names the role gate and says the hierarchy applies", () => {
    assert.match(declaration, /role: :orchestrator/);
    assert.match(declaration, /insufficient_role/);
    assert.match(declaration, /not exact_role/);
  });

  test("it names the lineage-ceiling refusal", () => {
    assert.match(declaration, /dispatch_outside_caller_lineage/);
  });

  test("it says implementer_dispatch_id is NOT cleared", () => {
    // The custody-safety claim. Without it a reader could assume a revoke launders
    // provenance and reach for it to escape an L4 gate.
    assert.match(declaration, /implementer_dispatch_id/);
  });

  test("it is honest that the TTL sweeps clear the slot on their own", () => {
    // `force_unclaim_story`'s description had to be corrected twice for claiming
    // "nothing else frees it" when two other mechanisms did. This one says so up front.
    assert.match(declaration, /RevokeExpiredDispatchesWorker/);
    assert.match(declaration, /force_unclaim_story/);
  });
});

describe("the wiring in index.js", () => {
  test("declared, dispatched TO ITS OWN HANDLER, and documented", () => {
    // THE CASE LABEL ALONE IS NOT THE WIRING. Pointing `case "revoke_dispatch":` at some
    // other handler leaves the label in place, so a grep for the label alone stays green
    // while the tool calls a different endpoint. The handler identifier is what decides
    // what the call does, so that is what is asserted.
    assert.ok(INDEX_SRC.includes('name: "revoke_dispatch"'), "revoke_dispatch is not declared");

    assert.match(
      INDEX_SRC,
      /case "revoke_dispatch":\s*return await revokeDispatch\(/,
      "revoke_dispatch is not dispatched to revokeDispatch()",
    );

    // The ROW, not a bare `includes` — the name appears in surrounding prose, so a tool
    // could lose its row and a substring match would not notice. The row is what an
    // operator reads.
    assert.ok(
      README.split("\n").some((line) => line.startsWith("| `revoke_dispatch` |")),
      "revoke_dispatch has no row in a README tool table",
    );
  });

  test("the handler forwards to the shared request module rather than re-implementing it", () => {
    // Comments stripped first: the handler carries a comment naming these same
    // identifiers, so the raw slice is satisfied by a site where the wiring has been
    // commented OUT — which is the shape a disabling edit takes.
    const start = INDEX_SRC.indexOf("async function revokeDispatch(");
    assert.ok(start > -1, "the revoke_dispatch handler was not found");

    const end = INDEX_SRC.indexOf("\nasync function ", start + 1);
    assert.ok(end > start, "the handler has no following function to bound it");

    const handler = INDEX_SRC.slice(start, end)
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .replace(/\/\/[^\n]*/g, "");

    assert.match(
      handler,
      /revokeDispatchRequest\(args, \{ apiCall \}\)/,
      "it does not forward to lib/dispatch-revoke.js, so the shipped path is untested",
    );
  });

  test("it pins NO env var — the gate is role:, not exact_role:", () => {
    // Deliberate, and the reason is #861 round 2: pinning LOOPCTL_ORCH_KEY unconditionally
    // refuses a configuration the SERVER accepts, because the gate tests the key's ROLE and
    // not the variable's name. An orchestrator-role LOOPCTL_API_KEY passes this endpoint.
    const start = INDEX_SRC.indexOf("async function revokeDispatch(");
    const end = INDEX_SRC.indexOf("\nasync function ", start + 1);
    const handler = INDEX_SRC.slice(start, end)
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .replace(/\/\/[^\n]*/g, "");

    assert.ok(
      !handler.includes("orchestratorKeyArgs"),
      "it pins the orchestrator key, which would refuse an orchestrator-role LOOPCTL_API_KEY",
    );
    assert.ok(!handler.includes("LOOPCTL_USER_KEY"), "it reaches for a key this gate does not need");
  });
});
