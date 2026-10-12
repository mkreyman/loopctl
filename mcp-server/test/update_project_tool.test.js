// update_project is the only way back for an ARCHIVED work project: delete_project archives,
// and the PATCH that restores it had no tool. These pin what the handler sends, what it
// refuses locally (the endpoint silently drops nulls, empty calls and unknown statuses),
// the key it travels on, its wiring, and its README rows.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { updateProject, UPDATABLE } from "../lib/projects.js";

const dir = path.dirname(fileURLToPath(import.meta.url));
const indexSource = readFileSync(path.join(dir, "..", "index.js"), "utf8");
const readmeSource = readFileSync(path.join(dir, "..", "README.md"), "utf8");
const rootReadmeSource = readFileSync(path.join(dir, "..", "..", "README.md"), "utf8");

const PROJECT = "11111111-2222-4333-8444-555555555555";

function recorder() {
  const calls = [];
  const apiCall = async (method, apiPath, body) => {
    calls.push({ method, apiPath, body });
    return { ok: true };
  };
  return { calls, apiCall };
}

function readmeRow(source, name) {
  const row = source.split("\n").find((line) => line.startsWith(`| \`${name}\` |`));
  assert.ok(row, `${name} has a README row`);
  return row;
}

describe("update_project", () => {
  test("restores an archived project with a PATCH carrying only the named fields", async () => {
    const api = recorder();
    await updateProject({ project_id: PROJECT, status: "active" }, api);
    assert.deepEqual(api.calls, [
      { method: "PATCH", apiPath: `/api/v1/projects/${PROJECT}`, body: { status: "active" } },
    ]);
  });

  test("sends every updatable field it is given, and an empty string to clear one", async () => {
    const api = recorder();
    const args = {
      project_id: PROJECT,
      name: "n",
      repo_url: "",
      description: "d",
      tech_stack: "elixir",
      status: "archived",
      mission: "",
      metadata: { a: 1 },
    };
    await updateProject(args, api);
    const { project_id: _id, ...expected } = args;
    assert.deepEqual(api.calls[0].body, expected);
    assert.deepEqual(Object.keys(expected).sort(), [...UPDATABLE].sort());
  });

  test("refuses locally what the endpoint would answer 200 to and change nothing", async () => {
    for (const args of [
      { project_id: PROJECT },
      { project_id: PROJECT, description: null },
      { project_id: PROJECT, status: "actve" },
      { project_id: "not-a-uuid", status: "active" },
    ]) {
      const api = recorder();
      const result = await updateProject(args, api);
      assert.equal(result.error, true, JSON.stringify(args));
      assert.equal(api.calls.length, 0, `${JSON.stringify(args)} reached the API`);
    }
  });

  test("an unknown status names the valid ones", async () => {
    const result = await updateProject({ project_id: PROJECT, status: "deleted" }, recorder());
    assert.match(result.body, /active, archived/);
  });

  test("travels on the orchestrator-pinned key, is declared and dispatched", () => {
    const start = indexSource.indexOf("async function updateProject(");
    assert.ok(start > 0, "updateProject handler exists");
    const body = indexSource.slice(start, indexSource.indexOf("\n}\n", start));
    assert.match(body, /apiCall: orchestratorPinnedApiCall/);
    assert.match(indexSource, /name: "update_project"/);
    assert.match(indexSource, /case "update_project":\s*\n\s*return await updateProject\(args\);/);
  });

  test("delete_project's description points at update_project as the way back", () => {
    const start = indexSource.indexOf('name: "delete_project"');
    const block = indexSource.slice(start, indexSource.indexOf('name: "', start + 10));
    assert.match(block, /update_project with status active/);
    assert.doesNotMatch(block, /no MCP tool reaches/);
  });

  test("both READMEs carry a row", () => {
    assert.match(readmeRow(readmeSource, "update_project"), /status/);
    assert.match(readmeRow(rootReadmeSource, "update_project"), /[Rr]estore/);
  });
});
