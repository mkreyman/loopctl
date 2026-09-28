/**
 * The epics tools (loopctl #876): each request's verb, path and body, the local refusals, and
 * the wiring — a tool declared and not dispatched, or dispatched and not declared, is the
 * reachability defect this issue was filed for, inside the MCP server.
 *
 * Run: node --test test/*.test.js
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import {
  createEpic,
  deleteEpic,
  epicProgress,
  getEpic,
  listEpics,
  updateEpic,
} from "../lib/epics.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");
const README = readFileSync(path.join(DIR, "..", "README.md"), "utf8");

const PROJECT = "2b124878-8d23-412e-b421-992dece8ec96";
const EPIC = "f016e82b-6926-4bab-912c-5a9236ed19e8";

const TOOLS = [
  ["list_epics", "listEpics"],
  ["create_epic", "createEpic"],
  ["get_epic", "getEpic"],
  ["update_epic", "updateEpic"],
  ["delete_epic", "deleteEpic"],
  ["epic_progress", "epicProgress"],
];

function fakeApi(response = { ok: true }) {
  const calls = [];
  const apiCall = async (method, apiPath, body) => {
    calls.push({ method, path: apiPath, body });
    return response;
  };
  return { calls, apiCall };
}

describe("epic requests", () => {
  test("a null optional argument is not sent as the string null", async () => {
    const api = fakeApi();
    await listEpics({ project_id: PROJECT, phase: null, page: null }, api);
    assert.equal(api.calls[0].path, `/api/v1/projects/${PROJECT}/epics`);
  });

  test("list_epics GETs the project's epics with its query", async () => {
    const api = fakeApi();
    await listEpics({ project_id: PROJECT, page: 2, page_size: 5, phase: "build" }, api);
    assert.deepEqual(api.calls, [
      {
        method: "GET",
        path: `/api/v1/projects/${PROJECT}/epics?page=2&page_size=5&phase=build`,
        body: undefined,
      },
    ]);
  });

  test("create_epic POSTs only the fields given, and needs number and title", async () => {
    const api = fakeApi();
    await createEpic({ project_id: PROJECT, number: 7, title: "Intake" }, api);
    assert.deepEqual(api.calls, [
      { method: "POST", path: `/api/v1/projects/${PROJECT}/epics`, body: { number: 7, title: "Intake" } },
    ]);

    const stringNumber = fakeApi();
    await createEpic({ project_id: PROJECT, number: "8", title: "Cast as the server casts" }, stringNumber);
    assert.equal(stringNumber.calls.length, 1);

    for (const args of [
      { project_id: PROJECT, number: "8a", title: "not an integer string" },
      { project_id: PROJECT, title: "no number" },
      { project_id: PROJECT, number: 7 },
    ]) {
      const refused = fakeApi();
      const result = await createEpic(args, refused);
      assert.equal(result.error, true);
      assert.equal(refused.calls.length, 0);
    }
  });

  test("get_epic, delete_epic and epic_progress address the epic", async () => {
    const api = fakeApi();
    await getEpic({ epic_id: EPIC }, api);
    await deleteEpic({ epic_id: EPIC }, api);
    await epicProgress({ epic_id: EPIC }, api);

    assert.deepEqual(
      api.calls.map((c) => `${c.method} ${c.path}`),
      [
        `GET /api/v1/epics/${EPIC}`,
        `DELETE /api/v1/epics/${EPIC}`,
        `GET /api/v1/epics/${EPIC}/progress`,
      ],
    );
  });

  test("update_epic sends the named fields and refuses a null or a call naming none", async () => {
    const api = fakeApi();
    await updateEpic({ epic_id: EPIC, title: "Renamed" }, api);
    assert.deepEqual(api.calls, [
      { method: "PATCH", path: `/api/v1/epics/${EPIC}`, body: { title: "Renamed" } },
    ]);

    for (const args of [{ epic_id: EPIC }, { epic_id: EPIC, title: "t", description: null }]) {
      const refused = fakeApi();
      const result = await updateEpic(args, refused);
      assert.equal(result.error, true);
      assert.equal(refused.calls.length, 0);
    }
  });

  test("a malformed or missing id is refused locally and never sent", async () => {
    for (const [fn, args] of [
      [listEpics, { project_id: "not-a-uuid" }],
      [createEpic, { number: 1, title: "t" }],
      [getEpic, { epic_id: "12" }],
      [updateEpic, { epic_id: "", title: "t" }],
      [deleteEpic, {}],
      [epicProgress, { epic_id: "x" }],
    ]) {
      const api = fakeApi();
      const result = await fn(args, api);
      assert.equal(result.error, true);
      assert.equal(api.calls.length, 0);
    }
  });
});

describe("epic tools are wired", () => {
  for (const [tool, handler] of TOOLS) {
    test(`${tool} is declared, dispatched to ${handler}, and documented`, () => {
      assert.match(INDEX_SRC, new RegExp(`name: "${tool}",`));
      assert.match(
        INDEX_SRC,
        new RegExp(`case "${tool}":\\s*\\n\\s*return await ${handler}\\(args\\);`),
      );
      assert.match(README, new RegExp(`\\| \`${tool}\` \\|`));
    });
  }

  test("writes carry the key their gate needs, and a global key cannot displace it", () => {
    const body = (handler) => {
      const start = INDEX_SRC.indexOf(`async function ${handler}(args)`);
      assert.ok(start >= 0, handler);
      return INDEX_SRC.slice(start, INDEX_SRC.indexOf("\n}\n", start));
    };

    for (const handler of ["createEpic", "updateEpic"]) {
      assert.match(body(handler), /orchestratorKeyArgs\(\)/, handler);
      assert.match(body(handler), /orch\.override, orch\.options/, handler);
    }

    assert.match(body("deleteEpic"), /process\.env\.LOOPCTL_USER_KEY/);
    assert.match(body("deleteEpic"), /exactKey: true/);
  });
});
