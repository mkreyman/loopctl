/**
 * THE FALSE CLAIM THIS PACKAGE KEEPS RE-GROWING, guarded mechanically.
 *
 * The claim: that a wrong-role key on an `exact_role: :orchestrator` custody verb produces a
 * 403 which "reads as the story being unverifiable / unfreeable / unclaimable rather than the
 * key being the wrong one", and therefore that pinning LOOPCTL_ORCH_KEY exists to avoid a
 * confusing error. It is false. `LoopctlWeb.Plugs.RequireRole` is mounted FIRST on those
 * actions; its exact-role clause (`require_role.ex:65-75`) halts through `forbid/3`
 * (`require_role.ex:112-128`) with 403, `code: "insufficient_role"`,
 * `required_roles: ["orchestrator"]` and "This endpoint requires the orchestrator role". A
 * halted request never reaches the controller, so it never reaches the custody 409s in
 * `Loopctl.Progress` at all. The role error names the role.
 *
 * Its companion, from the same round: that the four other custody verbs "now refuse locally,
 * naming the variable" when LOOPCTL_ORCH_KEY is unset. They do not — `orchestratorKeyArgs`
 * returns no options at all in that case and the global key is still sent.
 *
 * And the SHAPE both share, which the last pattern below catches generically: "the 403 reads as
 * <something about the domain> rather than <the real cause>". That is the sentence that keeps
 * being written, about whichever gate is at hand, and it is wrong for the same reason every
 * time — loopctl's refusals carry a `code` and the plug that produced them. It caught a third
 * site the sweeps never reached, in `lib/handoff.js`, about `create_project`'s human-anchor
 * gate: #505 gave that 403 a `remediation.agent_native_alternative` naming `create_kb_scope`,
 * so it points somewhere, and the comment saying it "reads as a wall" had outlived the fix.
 *
 * WHY A TEST AND NOT A SWEEP. Three review rounds found this claim. Round 2 removed it "in all
 * seven places" by hand and left two that round 3 then found — `index.js`'s `apiCall` comment
 * and the ROOT CHANGELOG's operator-facing release notes — while `lib/custody-key.js`, the
 * module written to stop the claim, asserted a correction that had not happened. Writing this
 * guard turned up a third the sweeps had never reached, in `lib/handoff.js`. A sweep that
 * missed sites twice is not a mechanism.
 *
 * HOW IT ADMITS THE DISPROOFS. Several files must QUOTE the claim in order to refute it, so a
 * flat ban would forbid its own remedy. The rule is a NEIGHBOURHOOD: a disproof marker — "an
 * earlier draft", "claimed", "is false", "do not reintroduce", "NOT because", "for the record",
 * "they do not" — must sit within a couple of sentences of the claim, in the same paragraph.
 * Asserting it is what fails; quoting it next to its refutation is what the fixed sites do.
 *
 * The window is why this is not per-paragraph. A marker ANYWHERE in a paragraph admits the whole
 * paragraph, and the refutation in `lib/custody-key.js` runs a dozen lines — so the paragraph
 * rule let an assertion be reintroduced at the far end of the very block that disproves it, and
 * a mutation proved it: rewriting the quotation as a bare assertion left the suite green
 * (exit 1) because "Do not reintroduce that justification" nine lines below still admitted it.
 *
 * Scope is this package plus the ROOT CHANGELOG.md, because the worst copy of the claim shipped
 * in the root changelog's operator-facing release notes, which no test under mcp-server/ read.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const PKG = path.join(DIR, "..");
const REPO = path.join(PKG, "..");

const SKIP_DIRS = new Set(["node_modules", ".git", "dist", "coverage", ".claude"]);
const SCANNED_EXT = new Set([".js", ".mjs", ".md"]);

/**
 * This file is excluded from its own scan, and it is the ONLY exclusion. It has to carry every
 * claim pattern verbatim as data, and the `quoting` fixture below quotes two of the disproof
 * sites word for word, so scanning it would report the detector as the offender. Nothing else
 * gets an exemption: an exclusion list is how a guard quietly stops guarding, which is the
 * failure mode this whole file exists to end.
 */
const SELF = fileURLToPath(import.meta.url);

/** Every .js/.md under mcp-server/, plus the root CHANGELOG the claim also reached. */
function filesToScan() {
  const found = [];

  (function walk(dir) {
    for (const entry of readdirSync(dir)) {
      if (SKIP_DIRS.has(entry)) continue;

      const full = path.join(dir, entry);
      if (statSync(full).isDirectory()) walk(full);
      else if (full !== SELF && SCANNED_EXT.has(path.extname(entry))) found.push(full);
    }
  })(PKG);

  found.push(path.join(REPO, "CHANGELOG.md"));
  return found;
}

/**
 * The claim's recognisable forms. Each is a phrase that only ever appears when this specific
 * justification is being made or quoted; none is a generic English construction.
 */
const CLAIM_PATTERNS = [
  /the story being un[a-z]+/i,
  /custody refusal about the story/i,
  /403 attributed to the wrong cause/i,
  /now refuse locally/i,
  /\b403\b[^.]{0,200}\breads? (?:as|like)\b/i,
];

/** A paragraph carrying one of these is refuting the claim, not making it. */
const DISPROOF_MARKERS = [
  /earlier (?:draft|version)/i,
  /\bclaimed\b/i,
  /\bis false\b/i,
  /do not reintroduce/i,
  /do not write that claim/i,
  /\bNOT because\b/,
  /for the record/i,
  /\bthey do not\b/i,
];

/**
 * Paragraphs, with comment furniture treated as blank. A block-comment paragraph break is
 * ` *` on its own line and a line-comment one is `//`; both must separate paragraphs, or a
 * whole file's worth of JSDoc would count as one.
 */
function paragraphs(source) {
  return source.split(/\n[ \t]*(?:\*|\/\/|#)?[ \t]*\n/);
}

/**
 * How far from the claim a disproof marker may sit: roughly the sentence before it and the
 * sentence after, either order. Both orders occur in the real disproofs — `custody-key.js`
 * leads with "claimed" and follows with "That is false"; the root CHANGELOG leads with "An
 * earlier draft of this entry" and follows with "They do not".
 */
const MARKER_LOOKBEHIND = 240;
const MARKER_LOOKAHEAD = 160;

function admitted(paragraph, match) {
  const start = Math.max(0, match.index - MARKER_LOOKBEHIND);
  const end = match.index + match[0].length + MARKER_LOOKAHEAD;
  const neighbourhood = paragraph.slice(start, end);

  return DISPROOF_MARKERS.some((re) => re.test(neighbourhood));
}

function lineOf(source, needle) {
  return source.slice(0, source.indexOf(needle)).split("\n").length;
}

function offences(file) {
  const source = readFileSync(file, "utf8");
  const hits = [];

  for (const para of paragraphs(source)) {
    for (const pattern of CLAIM_PATTERNS) {
      const match = pattern.exec(para);
      if (!match || admitted(para, match)) continue;

      hits.push({
        file: path.relative(REPO, file),
        line: lineOf(source, para) + para.slice(0, match.index).split("\n").length - 1,
        text: match[0],
      });
    }
  }

  return hits;
}

describe("the 403-is-confusing justification appears nowhere as an assertion", () => {
  test("no file states it; the files that quote it stand next to their disproof", () => {
    const hits = filesToScan().flatMap(offences);

    assert.deepEqual(
      hits,
      [],
      "the disproved justification is asserted at:\n" +
        hits.map((h) => `  ${h.file}:${h.line} — ${JSON.stringify(h.text)}`).join("\n") +
        "\nIt is false: RequireRole halts FIRST with code insufficient_role and " +
        "required_roles [orchestrator], so the request never reaches a custody 409. " +
        "See lib/custody-key.js. If you are quoting it in order to refute it, put the " +
        "refutation in the same paragraph and within a sentence or so of the quote.",
    );
  });

  test("the scan reaches the files it claims to, and the patterns still match something", () => {
    // Without this the guard above passes vacuously the moment the walker breaks, the
    // extension set changes, or a pattern stops matching the wording it was written for.
    const scanned = filesToScan().map((f) => path.relative(REPO, f));

    for (const expected of [
      "mcp-server/index.js",
      "mcp-server/lib/custody-key.js",
      "mcp-server/lib/delivery-loop.js",
      "mcp-server/README.md",
      "mcp-server/CHANGELOG.md",
      "CHANGELOG.md",
    ]) {
      assert.ok(scanned.includes(expected), `${expected} is not being scanned`);
    }

    // The two surviving QUOTATIONS. Each must still match a claim pattern — proving the
    // patterns recognise the real wording — and must still be admitted by a marker.
    const quoting = [
      ["mcp-server/lib/custody-key.js", /custody refusal about the STORY/],
      ["mcp-server/lib/delivery-loop.js", /the story being unclaimable/],
    ];

    for (const [file, wording] of quoting) {
      const source = readFileSync(path.join(REPO, file), "utf8");

      assert.match(source, wording, `${file} no longer quotes the claim it disproves`);
      assert.ok(
        CLAIM_PATTERNS.some((re) => re.test(source)),
        `no CLAIM_PATTERN matches ${file}, so the guard would not see a reintroduction there`,
      );
      assert.deepEqual(offences(path.join(REPO, file)), [], `${file} lost its disproof marker`);
    }
  });
});
