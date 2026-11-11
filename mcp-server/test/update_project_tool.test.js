// update_project: the MCP route to PATCH /api/v1/projects/:id (loopctl #1036). Without it no
// session could set a work project's repo_url, so SessionStart resolved no channel for it.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const dir = path.dirname(fileURLToPath(import.meta.url));
const indexSource = readFileSync(path.join(dir, "..", "index.js"), "utf8");
const handoffSource = readFileSync(path.join(dir, "..", "lib", "handoff.js"), "utf8");

describe("update_project", () => {
  test("is defined, dispatched and sent with the orchestrator-pinned key", () => {
    assert.match(indexSource, /name: "update_project"/);
    assert.match(indexSource, /case "update_project":\s*\n\s*return await updateProject\(args\);/);
    assert.match(indexSource, /orchestratorPinnedApiCall\("PATCH", `\/api\/v1\/projects\/\$\{project_id\}`, body\)/);
  });

  test("never sends slug or status, and refuses an empty update", () => {
    const fields = indexSource.match(/const PROJECT_UPDATABLE = \[([^\]]*)\]/);
    assert.ok(fields, "PROJECT_UPDATABLE is declared");
    assert.doesNotMatch(fields[1], /slug|status/);
    assert.match(fields[1], /"repo_url"/);
    assert.match(indexSource, /update_project needs at least one of/);
  });

  test("warns that a repo_url must be on one active project only", () => {
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
