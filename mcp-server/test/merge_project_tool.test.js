// merge_project: the MCP route to POST /api/v1/projects/:id/merge_into (US-52.2).
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { mergeProject } from "../lib/project-merge.js";
import { loadTools, stripComments } from "./tool-surface.js";

const dir = path.dirname(fileURLToPath(import.meta.url));
const indexSource = stripComments(readFileSync(path.join(dir, "..", "index.js"), "utf8"));
const readme = readFileSync(path.join(dir, "..", "README.md"), "utf8");
const SOURCE = "b5343742-3dd4-4a9e-b421-baee42696f3e";
const TARGET = "eba0b4df-e9ab-4908-a316-f55c698fe8bd";

function recorder() {
  const calls = [];
  const apiCall = async (...args) => {
    calls.push(args);
    return { ok: true };
  };
  return { calls, apiCall };
}

describe("merge_project request", () => {
  test("POSTs the target and dry_run to the source's merge_into route", async () => {
    const { calls, apiCall } = recorder();
    await mergeProject({ project_id: SOURCE, target_project_id: TARGET, dry_run: true }, { apiCall });
    assert.deepEqual(calls, [
      ["POST", `/api/v1/projects/${SOURCE}/merge_into`, { target_project_id: TARGET, dry_run: true }],
    ]);
  });

  test("dry_run defaults to false", async () => {
    const { calls, apiCall } = recorder();
    await mergeProject({ project_id: SOURCE, target_project_id: TARGET }, { apiCall });
    assert.equal(calls[0][2].dry_run, false);
  });

  test("refuses a missing or malformed id, and sends nothing", async () => {
    for (const args of [{ project_id: SOURCE }, { project_id: "chg-delivery", target_project_id: TARGET }]) {
      const { calls, apiCall } = recorder();
      const result = await mergeProject(args, { apiCall });
      assert.equal(result.error, true);
      assert.equal(calls.length, 0);
    }
  });
});

describe("merge_project wiring", () => {
  test("declared, dispatched, documented, and sent with the user key", () => {
    const tool = loadTools().find((t) => t.name === "merge_project");
    assert.ok(tool, "declared");
    assert.deepEqual([...tool.inputSchema.required], ["project_id", "target_project_id"]);
    assert.match(tool.description, /409 merge_conflicts/);
    assert.match(indexSource, /case "merge_project":\s*return await mergeProject\(args\);/);
    assert.match(indexSource, /async function mergeProject[\s\S]{0,200}LOOPCTL_USER_KEY/);
    assert.ok(readme.includes("| `merge_project` |"), "README row");
  });
});
