/**
 * US-52.17 on the MCP side: work_item_note and work_item_notes.
 *
 * The request shape is tested against lib/work-items.js; the last block source-pins index.js
 * so a tool cannot be declared without being dispatched to its own handler, or dispatched on
 * a key other than the session's own.
 *
 * Run: node --test test/*.test.js
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { listWorkItemNotes, notesPath, writeWorkItemNote } from "../lib/work-items.js";
import { stripComments } from "./tool-surface.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");
const README = readFileSync(path.join(DIR, "..", "README.md"), "utf8");

const STORY_ID = "d9975b31-032d-4f44-b154-c48af09640c7";

function fakeApi(response = { ok: true }) {
  const calls = [];
  const apiCall = async (method, apiPath, body) => {
    calls.push({ method, path: apiPath, body });
    return response;
  };
  return { calls, apiCall };
}

describe("work_item_note", () => {
  test("POSTs the section and body to the story's notes", async () => {
    const { calls, apiCall } = fakeApi();
    await writeWorkItemNote({ story_id: STORY_ID, section: "plan", body: "do x" }, { apiCall });

    assert.deepEqual(calls, [
      { method: "POST", path: notesPath(STORY_ID), body: { section: "plan", body: "do x" } },
    ]);
    assert.equal(notesPath(STORY_ID), `/api/v1/stories/${STORY_ID}/notes`);
  });

  test("carries an idempotency_key when one is given", async () => {
    const { calls, apiCall } = fakeApi();
    await writeWorkItemNote(
      { story_id: STORY_ID, section: "decision", body: "b", idempotency_key: "k-1" },
      { apiCall },
    );

    assert.equal(calls[0].body.idempotency_key, "k-1");
  });

  test("refuses locally, sending nothing, on a bad id, section or empty body", async () => {
    for (const args of [
      { story_id: "not-a-uuid", section: "plan", body: "b" },
      { story_id: STORY_ID, section: "diary", body: "b" },
      { story_id: STORY_ID, section: "plan", body: "  " },
      { story_id: STORY_ID, section: "plan" },
    ]) {
      const { calls, apiCall } = fakeApi();
      const result = await writeWorkItemNote(args, { apiCall });
      assert.equal(result.error, true);
      assert.equal(calls.length, 0);
    }
  });
});

describe("work_item_notes", () => {
  test("GETs the first page with no query", async () => {
    const { calls, apiCall } = fakeApi();
    await listWorkItemNotes({ story_id: STORY_ID }, { apiCall });

    assert.deepEqual(calls, [{ method: "GET", path: notesPath(STORY_ID), body: null }]);
  });

  test("passes section, limit and after as the query", async () => {
    const { calls, apiCall } = fakeApi();
    await listWorkItemNotes(
      { story_id: STORY_ID, section: "progress", limit: 10, after: "cur" },
      { apiCall },
    );

    assert.equal(calls[0].path, `${notesPath(STORY_ID)}?section=progress&limit=10&after=cur`);
  });

  test("refuses locally on an unknown section or a bad limit", async () => {
    for (const args of [
      { story_id: STORY_ID, section: "diary" },
      { story_id: STORY_ID, limit: 0 },
      { story_id: STORY_ID, after: 5 },
    ]) {
      const { calls, apiCall } = fakeApi();
      const result = await listWorkItemNotes(args, { apiCall });
      assert.equal(result.error, true);
      assert.equal(calls.length, 0);
    }
  });
});

describe("the wiring in index.js", () => {
  const wiring = { work_item_note: "workItemNoteTool", work_item_notes: "workItemNotesTool" };

  test("each tool is declared, dispatched to its own handler, and has a README row", () => {
    for (const [name, handler] of Object.entries(wiring)) {
      assert.ok(INDEX_SRC.includes(`name: "${name}"`), `${name} is not declared`);
      assert.match(
        INDEX_SRC,
        new RegExp(`case "${name}":\\s*return await ${handler}\\(`),
        `${name} is not dispatched to ${handler}()`,
      );
      assert.ok(
        README.split("\n").some((line) => line.startsWith("| `" + name + "` |")),
        `${name} has no row in a README tool table`,
      );
    }
  });

  test("each handler sends the session's own key and calls its own request builder", () => {
    const builders = { workItemNoteTool: "writeWorkItemNote", workItemNotesTool: "listWorkItemNotes" };

    for (const [handler, builder] of Object.entries(builders)) {
      const start = INDEX_SRC.indexOf(`async function ${handler}(`);
      assert.ok(start > -1, `${handler} was not found`);
      const end = INDEX_SRC.indexOf("\nasync function ", start + 1);
      assert.ok(end > start, `${handler} has no following function to bound it`);
      const body = stripComments(INDEX_SRC.slice(start, end));

      assert.match(body, new RegExp(`${builder}\\(`), `${handler} does not call ${builder}`);
      assert.match(body, /agentKey\(\)/, `${handler} does not send the session's own key`);
      assert.doesNotMatch(body, /LOOPCTL_(ORCH|USER)_KEY/, `${handler} sends another key`);
    }
  });
});
