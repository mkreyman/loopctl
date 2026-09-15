/**
 * Every in-document link in README.md resolves to a heading that exists.
 *
 * The defect: `### Runner tools (user key)` was renamed to `### Runner and delivery-loop
 * tools` and the `[runner tools](#runner-tools-user-key)` link in the environment-variable
 * table was left behind, pointing at an anchor GitHub no longer generates. A dead anchor
 * scrolls nowhere and says nothing, so nobody reports it — and the README is the document an
 * operator reads BEFORE they have a working configuration.
 *
 * Slugging follows GitHub's rule: lower-case, drop everything that is not a word character,
 * a space or a hyphen, then spaces to hyphens. That is why `First-time setup — provision your
 * BYO LLM keys` anchors as `first-time-setup--provision-your-byo-llm-keys` — the em dash is
 * dropped and its two surrounding spaces become two hyphens.
 *
 * Run: node --test test/*.test.js
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const README = readFileSync(path.join(DIR, "..", "README.md"), "utf8");

function slug(heading) {
  return heading
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s_-]/gu, "")
    .replace(/\s/g, "-");
}

function headingAnchors(markdown) {
  const anchors = new Set();
  for (const line of markdown.split("\n")) {
    const match = /^#{1,6}\s+(.*)$/.exec(line);
    if (match) anchors.add(slug(match[1]));
  }
  return anchors;
}

function internalLinks(markdown) {
  const found = [];
  markdown.split("\n").forEach((line, index) => {
    for (const match of line.matchAll(/\]\(#([^)]+)\)/g)) {
      found.push({ anchor: match[1], line: index + 1 });
    }
  });
  return found;
}

describe("README in-document links", () => {
  test("the slugger reproduces the anchors GitHub actually generates", () => {
    // Pinned separately, because the check below is only as good as this function: a slugger
    // that returned the link text verbatim would pass every link in the file.
    assert.equal(slug("Runner and delivery-loop tools"), "runner-and-delivery-loop-tools");
    assert.equal(
      slug("First-time setup — provision your BYO LLM keys"),
      "first-time-setup--provision-your-byo-llm-keys",
    );
    assert.equal(slug("Witness protocol (STH)"), "witness-protocol-sth");
    assert.equal(
      slug("Design invariant: no model-visible `confirm`/`approved` argument"),
      "design-invariant-no-model-visible-confirmapproved-argument",
    );
  });

  test("every anchor link points at a heading that exists", () => {
    const anchors = headingAnchors(README);
    const links = internalLinks(README);

    // A check with nothing to check is a green that means nothing.
    assert.ok(links.length >= 5, `only ${links.length} in-document links found`);

    const broken = links.filter((link) => !anchors.has(link.anchor));

    assert.deepEqual(
      broken,
      [],
      `broken anchors: ${broken.map((b) => `README.md:${b.line} -> #${b.anchor}`).join(", ")}`,
    );
  });
});
