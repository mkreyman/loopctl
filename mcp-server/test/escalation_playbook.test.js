/**
 * The stuck-story playbook (lib/escalation-playbook.js): the `remedy` on each escalation_list
 * row, the `escalation_playbook` tool, and the `stuck_story` prompt, plus their wiring.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  classRemedy,
  playbook,
  REMEDIES,
  remedyFor,
  STUCK_STORY_PROMPT,
  stuckStoryPrompt,
  TAKE_OVER_STEPS,
  withRemedies,
} from "../lib/escalation-playbook.js";
import { REASON_CLASSES } from "../lib/escalations.js";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const INDEX_SRC = readFileSync(join(ROOT, "index.js"), "utf8");
const README = readFileSync(join(ROOT, "README.md"), "utf8");
const INBOX_SRC = readFileSync(
  join(ROOT, "..", "lib", "loopctl", "delivery", "escalation_inbox.ex"),
  "utf8",
);

const STORY = "11111111-2222-4333-8444-555555555555";

describe("remedies cover the server's reason classes", () => {
  test("one remedy per reason_class, no more, no fewer", () => {
    assert.deepEqual(Object.keys(REMEDIES).sort(), [...REASON_CLASSES].sort());
  });

  test("the edges the remedies name are edges the inbox classifies", () => {
    // A remedy that names an edge the server no longer emits is advice nobody can follow.
    for (const edge of [
      "merge_gate",
      "no_independent_verifier_runner",
      "verification_failed",
      "review_missing",
      "ungated_merge",
      "runner_gone",
      "merge_unanswered",
      "change_outside_lifecycle",
      "reverted_after_verify",
    ]) {
      assert.match(INBOX_SRC, new RegExp(`\\b${edge}: :`), `${edge} is not in @reason_classes`);
    }
  });
});

describe("remedyFor", () => {
  test("a row's remedy points at its class and carries no class text", () => {
    const r = remedyFor({ story_id: STORY, reason_class: "triage_escalated", edge: "triage_escalate" });
    assert.deepEqual(r, { see: "remedies.triage_escalated" });
  });

  test("an unknown or missing class falls back to other", () => {
    assert.equal(remedyFor({ reason_class: "new_class" }).see, "remedies.other");
    assert.equal(remedyFor({}).see, "remedies.other");
    assert.equal(remedyFor(null).see, "remedies.other");
  });

  test("classRemedy gives the class's meaning, options and take-over pointer", () => {
    const r = classRemedy("triage_escalated");
    assert.equal(r.meaning, REMEDIES.triage_escalated.meaning);
    assert.deepEqual(r.options, REMEDIES.triage_escalated.options);
    assert.match(r.take_over, /escalation_playbook \{reason_class: "triage_escalated"\}/);
  });

  test("a merged-change edge warns against re-queuing", () => {
    for (const edge of ["verification_failed", "review_missing", "ungated_merge"]) {
      const r = remedyFor({ reason_class: "gate_refused", edge });
      assert.match(r.warning, /already merged/, edge);
    }
    assert.equal(remedyFor({ reason_class: "gate_refused", edge: "merge_gate" }).warning, undefined);
  });

  test("work left behind names the runner worktree", () => {
    const r = remedyFor({
      story_id: STORY,
      reason_class: "budget_exhausted",
      run: { work_left_behind: "true", branch: "loop/abc" },
    });
    assert.match(r.salvage, /loop\/abc/);
    assert.ok(r.salvage.includes(`.claude/worktrees/loop-${STORY}`));
  });

  test("no salvage line unless the runner said \"true\"", () => {
    for (const value of ["false", "unknown", undefined]) {
      const r = remedyFor({ reason_class: "budget_exhausted", run: { work_left_behind: value } });
      assert.equal(r.salvage, undefined, String(value));
    }
  });

  test("the returned options are a copy, so a caller cannot edit the table", () => {
    const r = classRemedy("other");
    r.options.push("x");
    assert.ok(!REMEDIES.other.options.includes("x"));
  });
});

describe("withRemedies", () => {
  test("puts each present class's text on the page once and a pointer on each row", () => {
    const page = {
      data: [
        { story_id: STORY, reason_class: "operator_released" },
        { story_id: STORY, reason_class: "session_failed" },
        { story_id: STORY, reason_class: "session_failed" },
      ],
      next_cursor: "c1",
    };
    const out = withRemedies(page);
    assert.equal(out.next_cursor, "c1");
    assert.deepEqual(Object.keys(out.remedies).sort(), ["operator_released", "session_failed"]);
    assert.equal(out.remedies.session_failed.meaning, REMEDIES.session_failed.meaning);
    assert.deepEqual(
      out.data.map((r) => r.remedy.see),
      ["remedies.operator_released", "remedies.session_failed", "remedies.session_failed"],
    );
    assert.equal(out.data[1].remedy.meaning, undefined, "no class text repeated per row");
    assert.equal(page.data[0].remedy, undefined, "the input page is not mutated");
  });

  test("an empty page carries empty remedies", () => {
    assert.deepEqual(withRemedies({ data: [], next_cursor: null }).remedies, {});
  });

  test("an error or an unexpected shape passes through untouched", () => {
    const err = { error: true, status: 400, body: "bad" };
    assert.equal(withRemedies(err), err);
    assert.equal(withRemedies(undefined), undefined);
    const odd = { data: "nope" };
    assert.equal(withRemedies(odd), odd);
  });
});

describe("playbook", () => {
  test("whole runbook carries every class and the take-over steps", () => {
    const book = playbook();
    assert.deepEqual(Object.keys(book.by_reason_class).sort(), [...REASON_CLASSES].sort());
    assert.deepEqual(book.take_over, TAKE_OVER_STEPS);
    assert.match(book.decide, /LOOPCTL_USER_KEY/);
  });

  test("one class narrows by_reason_class only", () => {
    const book = playbook({ reason_class: "budget_exhausted" });
    assert.deepEqual(Object.keys(book.by_reason_class), ["budget_exhausted"]);
    assert.deepEqual(book.take_over, TAKE_OVER_STEPS);
  });

  test("null or an empty reason_class means the whole runbook, as escalation_list reads it", () => {
    for (const value of [null, ""]) {
      const book = playbook({ reason_class: value });
      assert.equal(book.error, undefined, String(value));
      assert.deepEqual(Object.keys(book.by_reason_class).sort(), [...REASON_CLASSES].sort());
    }
  });

  test("take-over step 4 branches from the repo's base branch, not a fixed master", () => {
    assert.match(TAKE_OVER_STEPS[3], /base_branch/);
    assert.doesNotMatch(TAKE_OVER_STEPS[3], /branch from master/);
  });

  test("an unknown class is refused locally", () => {
    const out = playbook({ reason_class: "nope" });
    assert.equal(out.error, true);
    assert.equal(out.status, 0);
    assert.match(out.body, /budget_exhausted/);
  });

  test("the take-over steps keep the rules that make a take-over safe", () => {
    const text = TAKE_OVER_STEPS.join("\n");
    assert.match(text, /Leave the story escalated/);
    assert.match(text, /Do not claim_story/);
    assert.match(text, /Fixes #<issue>/);
    assert.match(text, /resolve_escalation \{story_id, to: "done"/);
  });
});

describe("stuck_story prompt", () => {
  test("names the story when given one", () => {
    const text = stuckStoryPrompt({ story_id: STORY });
    assert.ok(text.startsWith(`Story ${STORY} is stuck.`));
    assert.match(text, /Take-over steps:/);
    for (const cls of REASON_CLASSES) assert.ok(text.includes(`- ${cls}: `), cls);
  });

  test("without a story it reviews the inbox", () => {
    assert.match(stuckStoryPrompt(), /^Call escalation_list/);
  });

  test("declares story_id as optional", () => {
    assert.equal(STUCK_STORY_PROMPT.name, "stuck_story");
    assert.deepEqual(
      STUCK_STORY_PROMPT.arguments.map((a) => [a.name, a.required]),
      [["story_id", false]],
    );
  });
});

describe("wiring in index.js and the README", () => {
  test("escalation_playbook is declared, dispatched to its own handler, and has a README row", () => {
    assert.ok(INDEX_SRC.includes('name: "escalation_playbook"'));
    assert.match(INDEX_SRC, /case "escalation_playbook":\s*return await escalationPlaybook\(/);
    assert.ok(README.split("\n").some((l) => l.startsWith("| `escalation_playbook` |")));
  });

  test("escalation_list's handler adds the remedies", () => {
    const start = INDEX_SRC.indexOf("async function escalationListRead(");
    const handler = INDEX_SRC.slice(start, INDEX_SRC.indexOf("\n}\n", start));
    assert.match(handler, /withRemedies\(/);
  });

  test("escalation_list's tool description tells sessions about the remedies", () => {
    const start = INDEX_SRC.indexOf('name: "escalation_list"');
    const decl = INDEX_SRC.slice(start, INDEX_SRC.indexOf('name: "escalation_playbook"', start));
    assert.match(decl, /`remedies`/);
    assert.match(decl, /ALREADY MERGED/);
    assert.match(decl, /`salvage`/);
  });

  test("an unknown prompt is an invalid-params error, not an internal one", () => {
    assert.match(INDEX_SRC, /new McpError\(ErrorCode\.InvalidParams, `Unknown prompt/);
  });

  test("the server declares prompts and answers both prompt requests", () => {
    assert.match(INDEX_SRC, /capabilities: \{ tools: \{\}, prompts: \{\} \}/);
    assert.match(INDEX_SRC, /setRequestHandler\(ListPromptsRequestSchema,/);
    assert.match(INDEX_SRC, /setRequestHandler\(GetPromptRequestSchema,/);
    assert.ok(README.split("\n").some((l) => l.startsWith("| `stuck_story` |")));
  });

  test("the tool's reason_class enum matches the server's classes", () => {
    const start = INDEX_SRC.indexOf('name: "escalation_playbook"');
    const decl = INDEX_SRC.slice(start, INDEX_SRC.indexOf('name: "resolve_escalation"', start));
    for (const cls of REASON_CLASSES) assert.ok(decl.includes(`"${cls}"`), cls);
  });
});
