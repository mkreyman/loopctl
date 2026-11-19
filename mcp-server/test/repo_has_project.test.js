// US-52.1: a repo has one project, and the server refuses a second with 409
// repo_already_has_project. A session reads the tool description, not the controller, so
// every tool that can give a repo a second active project names the refusal.
import { test } from "node:test";
import assert from "node:assert/strict";
import { loadTools } from "./tool-surface.js";

const TOOLS_THAT_SET_A_REPO = [
  "create_project",
  "create_kb_scope",
  "update_project",
  "restore_project",
  "intake_source_enroll",
];

test("every tool that can give a repo a second project names repo_already_has_project", () => {
  const tools = new Map(loadTools().map((tool) => [tool.name, tool]));

  for (const name of TOOLS_THAT_SET_A_REPO) {
    const tool = tools.get(name);
    assert.ok(tool, `${name} is declared`);
    assert.match(tool.description, /409 repo_already_has_project/, `${name} names the 409`);
    assert.match(tool.description, /existing_project_id/, `${name} names the field to read`);
  }
});
