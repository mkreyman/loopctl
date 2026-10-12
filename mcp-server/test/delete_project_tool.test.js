// delete_project ARCHIVES: DELETE /api/v1/projects/:id calls Projects.archive_project/3 and
// removes no rows. Its description once claimed an irreversible delete of the project and
// everything under it, and a session reported an archived project deleted while nothing
// changed. These pin the description, the README rows and the key the call is sent with.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const dir = path.dirname(fileURLToPath(import.meta.url));
const indexSource = readFileSync(path.join(dir, "..", "index.js"), "utf8");
const readmeSource = readFileSync(path.join(dir, "..", "README.md"), "utf8");
const rootReadmeSource = readFileSync(path.join(dir, "..", "..", "README.md"), "utf8");

function toolDefinitionSource(name) {
  const start = indexSource.indexOf(`name: "${name}"`);
  assert.ok(start > 0, `${name} has a tool definition`);

  const rest = indexSource.slice(start + 1);
  const nextTool = rest.indexOf('\n    name: "');
  const terminator = rest.indexOf("\n];");
  const ends = [nextTool, terminator].filter((i) => i > 0);
  assert.ok(ends.length > 0, `${name}: found no boundary after the definition`);

  const block = rest.slice(0, Math.min(...ends));
  assert.ok(block.length > 100, `${name}: definition slice collapsed`);
  return block;
}

function readmeRow(source, name) {
  const row = source.split("\n").find((line) => line.startsWith(`| \`${name}\` |`));
  assert.ok(row, `${name} has a README row`);
  return row;
}

describe("delete_project", () => {
  test("says it archives, never that it deletes irreversibly", () => {
    const src = toolDefinitionSource("delete_project");
    assert.match(src, /ARCHIVE/);
    assert.match(src, /removes no rows/);
    assert.doesNotMatch(src, /irreversible/i);
  });

  test("names the slug staying taken, the way back and the refusals", () => {
    const src = toolDefinitionSource("delete_project");
    assert.match(src, /SLUG stays taken/);
    assert.match(src, /restore_kb_scope/);
    assert.match(src, /custody_tier_required/);
    assert.match(src, /insufficient_role/);
  });

  test("both README rows say it archives", () => {
    for (const source of [readmeSource, rootReadmeSource]) {
      const row = readmeRow(source, "delete_project");
      assert.match(row, /[Aa]rchive/);
      assert.doesNotMatch(row, /irreversible/i);
    }
  });

  test("is sent with LOOPCTL_USER_KEY pinned, so a global key cannot displace it", () => {
    const start = indexSource.indexOf("async function deleteProject(");
    assert.ok(start > 0, "deleteProject handler exists");
    const body = indexSource.slice(start, indexSource.indexOf("\n}\n", start));
    assert.match(body, /process\.env\.LOOPCTL_USER_KEY/);
    assert.match(body, /exactKey: true/);
  });
});
