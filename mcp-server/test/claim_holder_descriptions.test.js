/**
 * US-52.14 (AC-52.14.8): every claimant tool says what a session gets on an item another
 * session holds, even one with the same agent key.
 *
 * Run: node --test test/*.test.js
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");

function constantText(name) {
  const match = INDEX_SRC.match(new RegExp(`const ${name} =([\\s\\S]*?);\\n`));
  assert.ok(match, `${name} is defined`);
  return match[1];
}

function declaration(tool) {
  const start = INDEX_SRC.indexOf(`    name: "${tool}",\n    description:`);
  assert.ok(start >= 0, `${tool} is declared`);
  const end = INDEX_SRC.indexOf("inputSchema:", start);
  return INDEX_SRC.slice(start, end);
}

test("the story refusal names held_by_other_holder and another session", () => {
  const text = constantText("HELD_BY_OTHER_HOLDER");
  assert.match(text, /held_by_other_holder/);
  assert.match(text, /another session/);
  assert.match(text, /holder_host/);
});

test("the channel refusal names already_claimed and another session", () => {
  const text = constantText("CHANNEL_HELD_BY_OTHER_SESSION");
  assert.match(text, /already_claimed/);
  assert.match(text, /another session/);
});

for (const tool of ["claim_story", "start_story", "renew_story_claim", "request_review"]) {
  test(`${tool} carries the story refusal`, () => {
    assert.match(declaration(tool), /HELD_BY_OTHER_HOLDER/);
  });
}

for (const tool of ["channel_claim", "channel_done", "channel_release"]) {
  test(`${tool} carries the channel refusal`, () => {
    assert.match(declaration(tool), /CHANNEL_HELD_BY_OTHER_SESSION/);
  });
}
