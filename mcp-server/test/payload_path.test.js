/**
 * Tests for import_stories `payload_path` reading (lib/payload-path.js).
 *
 * Regression for a reported disclosure: a hostile payload_path such as /etc/passwd made
 * JSON.parse throw, and the SyntaxError message (which quotes the file's content) was
 * echoed back to the caller. A valid non-payload JSON file (credentials) was uploaded.
 *
 * Runs the REAL reader against real files in a temp dir; the last block source-scans
 * index.js so the wiring cannot drift from the logic.
 *
 * Run: node --test test/*.test.js
 */

import { test, describe, before, after } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, symlinkSync, mkdirSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { readPayloadFile } from "../lib/payload-path.js";

const SECRET = "root:x:0:0:SECRET-MARKER";

let dir;
const at = (name) => path.join(dir, name);

before(() => {
  dir = mkdtempSync(path.join(tmpdir(), "payload-path-"));
  writeFileSync(at("stories.json"), JSON.stringify({ epics: [{ number: 1, stories: [] }] }));
  writeFileSync(at("passwd"), `${SECRET}\n`);
  writeFileSync(at("garbage.json"), `${SECRET}\n`);
  writeFileSync(at("creds.json"), JSON.stringify({ token: "SECRET-MARKER" }));
  writeFileSync(at("array.json"), JSON.stringify([{ epics: [] }]));
  symlinkSync(at("passwd"), at("link-to-passwd.json"));
  symlinkSync("/proc/self/environ", at("link-to-proc.json"));
  mkdirSync(at("dir.json"));
});

after(() => rmSync(dir, { recursive: true, force: true }));

function assertRefusedWithoutLeak(result) {
  assert.equal(result.error, true);
  assert.equal(result.status, 0);
  assert.ok(!result.body.includes("SECRET-MARKER"), `body leaked file content: ${result.body}`);
  assert.ok(!result.body.includes("Unexpected token"), `body echoed a parser message: ${result.body}`);
}

describe("payload_path accepts a real import payload", () => {
  test("returns the parsed object", async () => {
    const result = await readPayloadFile(at("stories.json"));
    assert.deepEqual(result, { epics: [{ number: 1, stories: [] }] });
  });
});

describe("payload_path never discloses or uploads a non-payload file", () => {
  test("a non-JSON file with no .json extension is refused before it is read", async () => {
    let read = false;
    const fs = { realpath: async () => { read = true; }, stat: async () => { read = true; }, readFile: async () => { read = true; } };
    const result = await readPayloadFile(at("passwd"), { fs });
    assertRefusedWithoutLeak(result);
    assert.match(result.body, /must be a \.json file/);
    assert.equal(read, false);
  });

  test("/etc/passwd is refused without echoing content", async () => {
    assertRefusedWithoutLeak(await readPayloadFile("/etc/passwd"));
  });

  test("a .json file that does not parse reports 'not valid JSON' and no content", async () => {
    const result = await readPayloadFile(at("garbage.json"));
    assertRefusedWithoutLeak(result);
    assert.match(result.body, /is not valid JSON\.$/);
  });

  test("valid JSON without an epics array is refused, so it is never POSTed", async () => {
    const result = await readPayloadFile(at("creds.json"));
    assertRefusedWithoutLeak(result);
    assert.match(result.body, /not an import payload/);
  });

  test("a top-level array is refused", async () => {
    assertRefusedWithoutLeak(await readPayloadFile(at("array.json")));
  });

  test("a .json symlink to a non-.json file is refused on its realpath", async () => {
    const result = await readPayloadFile(at("link-to-passwd.json"));
    assertRefusedWithoutLeak(result);
    assert.match(result.body, /must be a \.json file/);
  });

  test("a .json symlink into /proc is refused as a pseudo-filesystem", async () => {
    const result = await readPayloadFile(at("link-to-proc.json"));
    assertRefusedWithoutLeak(result);
    assert.match(result.body, /pseudo-filesystem/);
  });

  test("a lexical /proc path is refused", async () => {
    assert.match((await readPayloadFile("/proc/self/environ.json")).body, /pseudo-filesystem/);
    assert.match((await readPayloadFile("/sys/../proc/x.json")).body, /pseudo-filesystem/);
  });

  test("a directory is refused", async () => {
    assert.match((await readPayloadFile(at("dir.json"))).body, /not a regular file/);
  });

  test("a missing file reports only the error code", async () => {
    const result = await readPayloadFile(at("nope.json"));
    assertRefusedWithoutLeak(result);
    assert.match(result.body, /\(ENOENT\)\.$/);
  });

  test("a relative path is refused", async () => {
    assert.match((await readPayloadFile("stories.json")).body, /must be absolute/);
  });
});

describe("index.js wiring", () => {
  const src = readFileSync(
    path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "index.js"),
    "utf8",
  );

  test("imports readPayloadFile and delegates payload_path to it", () => {
    assert.match(src, /import \{ readPayloadFile \} from "\.\/lib\/payload-path\.js";/);
    assert.match(src, /return readPayloadFile\(payloadPath\);/);
  });

  test("index.js no longer reads payload_path itself or echoes err.message for it", () => {
    assert.ok(!/Could not read payload_path '\$\{payloadPath\}': \$\{err\.message\}/.test(src));
    assert.ok(!/fs\.readFile\(payloadPath/.test(src));
  });
});
