// update_project: the MCP route to PATCH /api/v1/projects/:id (loopctl #1036). Without it no
// session could set a work project's repo_url, so SessionStart resolved no channel for it.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { updateProject } from "../lib/project-update.js";
import { stripComments } from "./tool-surface.js";

const dir = path.dirname(fileURLToPath(import.meta.url));
const indexSource = stripComments(readFileSync(path.join(dir, "..", "index.js"), "utf8"));
const handoffSource = readFileSync(path.join(dir, "..", "lib", "handoff.js"), "utf8");
const ID = "362b88d7-b551-4052-8a99-4fcc7fd6f8e2";

function recorder() {
  const calls = [];
  const apiCall = async (...args) => {
    calls.push(args);
    return { ok: true };
  };
  return { calls, apiCall };
}

describe("update_project request", () => {
  test("PATCHes only the named fields, never status", async () => {
    const { calls, apiCall } = recorder();
    await updateProject(
      { project_id: ID, repo_url: "https://github.com/mkreyman/second_brain", status: "archived", name: null },
      { apiCall },
    );
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0], ["PATCH", `/api/v1/projects/${ID}`, { repo_url: "https://github.com/mkreyman/second_brain" }]);
  });

  test("sends a slug, so a kb scope can be renamed to its repo basename (#1038)", async () => {
    const { calls, apiCall } = recorder();
    await updateProject({ project_id: ID, slug: "home_care_billing" }, { apiCall });
    assert.deepEqual(calls[0][2], { slug: "home_care_billing" });
  });

  test("an empty mission is sent, so it can be cleared", async () => {
    const { calls, apiCall } = recorder();
    await updateProject({ project_id: ID, mission: "" }, { apiCall });
    assert.deepEqual(calls[0][2], { mission: "" });
  });

  test("refuses an update naming no field, and sends nothing", async () => {
    const { calls, apiCall } = recorder();
    const result = await updateProject({ project_id: ID, status: "archived" }, { apiCall });
    assert.equal(result.error, true);
    assert.match(result.body, /needs at least one of/);
    assert.equal(calls.length, 0);
  });

  test("refuses a malformed id, and sends nothing", async () => {
    const { calls, apiCall } = recorder();
    const result = await updateProject({ project_id: "second-brain", repo_url: "x" }, { apiCall });
    assert.equal(result.error, true);
    assert.equal(calls.length, 0);
  });
});

describe("update_project wiring", () => {
  test("is declared, dispatched and sent with the orchestrator-pinned key", () => {
    assert.match(indexSource, /name: "update_project"/);
    assert.match(indexSource, /case "update_project":\s*\n\s*return await updateProject\(args\);/);
    assert.match(indexSource, /updateProjectRequest\(args, \{ apiCall: orchestratorPinnedApiCall \}\)/);
    assert.match(indexSource, /ambiguous_resolution fleet-wide/);
  });
});

describe("handoff post remediation on a work project", () => {
  test("names the membership story, not a second channel", () => {
    assert.match(handoffSource, /membership story/);
    assert.match(handoffSource, /never a second channel/);
    assert.match(handoffSource, /request_review/);
  });
});
