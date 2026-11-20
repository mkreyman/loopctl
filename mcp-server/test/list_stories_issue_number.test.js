/**
 * TC-52.9.2 (US-52.9): list_stories accepts issue_number, declares it, and sends it to
 * GET /api/v1/stories; the README names it.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const PKG_DIR = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const INDEX_SRC = readFileSync(path.join(PKG_DIR, "index.js"), "utf8");
const README = readFileSync(path.join(PKG_DIR, "README.md"), "utf8");

function slice(from, to) {
  const start = INDEX_SRC.indexOf(from);
  const end = INDEX_SRC.indexOf(to, start + from.length);
  assert.ok(start > 0 && end > start, `${from} is in index.js`);
  return INDEX_SRC.slice(start, end);
}

test("the handler destructures issue_number and sends it as a query parameter", () => {
  const body = slice("async function listStories(", "async function listReadyStories(");

  assert.match(body, /\{ project_id, agent_status, verified_status, epic_id, issue_number,/);
  assert.match(body, /if \(issue_number != null\) params\.set\("issue_number", String\(issue_number\)\);/);
  assert.match(body, /apiCall\("GET", `\/api\/v1\/stories\?\$\{params\}`\)/);
});

test("the declaration names issue_number as an integer", () => {
  const decl = slice('name: "list_stories"', 'required: ["project_id"]');

  assert.match(decl, /issue_number: \{\s*type: "integer",/);
  assert.match(decl, /400/);
});

test("the README row names it", () => {
  const row = README.split("\n").find((line) => line.startsWith("| `list_stories` |"));
  assert.ok(row, "list_stories has a README row");
  assert.match(row, /`issue_number`/);
});

test("repo narrows the issue number: declared, sent, and named in the README", () => {
  const body = slice("async function listStories(", "async function listReadyStories(");
  assert.match(body, /issue_number, repo, limit,/);
  assert.match(body, /if \(repo\) params\.set\("repo", repo\);/);

  const decl = slice('name: "list_stories"', 'required: ["project_id"]');
  assert.match(decl, /repo: \{\s*type: "string",/);

  const row = README.split("\n").find((line) => line.startsWith("| `list_stories` |"));
  assert.match(row, /`repo`/);
});
