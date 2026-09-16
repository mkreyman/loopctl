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
 * TWO THINGS THIS SCANNER GETS RIGHT THAT THE FIRST VERSION DID NOT (#846 review round 2).
 * Both are latent on today's README — it has no duplicate headings and no heading-shaped line
 * inside a fence — which is exactly why they are pinned against FIXTURES below rather than
 * against the file itself. A check that cannot fail today is not a check.
 *
 *   1. FENCED CODE BLOCKS ARE NOT MARKDOWN. `^#{1,6}\s+(.*)$` matches a shell comment, and
 *      this README carries bash and json fences. A future `# set your keys` inside one would
 *      mint a phantom anchor that a genuinely broken link could then resolve to — the scanner
 *      would go green on the very defect it exists to catch. The link side has the mirror bug:
 *      a `](#…)` in an example payload is not a link anyone can click, and checking it makes
 *      the README's own documentation fail the README's own test.
 *   2. GITHUB SUFFIXES DUPLICATE HEADINGS. Two `## Requirements` headings anchor as
 *      `requirements` and `requirements-1`. Collapsing them into one `Set` reports a link to
 *      `#requirements-1` — the form GitHub actually generates, and therefore the form a
 *      correct link takes — as broken, while `#requirements` passes and scrolls to the wrong
 *      section.
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

/**
 * The document's lines with every FENCED code block blanked out.
 *
 * Blanked rather than removed, so the line numbers in a failure message still point at the
 * right line of README.md.
 *
 * A fence opens on ``` or ~~~ (three or more, up to three leading spaces) and closes on the
 * same character, at least as long, with nothing but whitespace after it — CommonMark's rule,
 * and the reason an info string like ```bash does not close the block it opens. An
 * unterminated fence blanks the rest of the document, which is the safe direction: a scanner
 * that sees less can only report a link as broken, never mint an anchor that is not there.
 */
function withoutFencedBlocks(markdown) {
  const lines = [];
  let fence = null;

  for (const line of markdown.split("\n")) {
    if (fence === null) {
      const open = /^ {0,3}(`{3,}|~{3,})/.exec(line);
      if (open) {
        fence = open[1];
        lines.push("");
        continue;
      }
      lines.push(line);
      continue;
    }

    const close = /^ {0,3}(`{3,}|~{3,})\s*$/.exec(line);
    if (close && close[1][0] === fence[0] && close[1].length >= fence.length) fence = null;
    lines.push("");
  }

  return lines;
}

function headingAnchors(markdown) {
  const anchors = new Set();
  const seen = new Map();

  for (const line of withoutFencedBlocks(markdown)) {
    const match = /^#{1,6}\s+(.*)$/.exec(line);
    if (!match) continue;

    const base = slug(match[1]);
    const seenBefore = seen.get(base) ?? 0;
    seen.set(base, seenBefore + 1);
    // GitHub: first occurrence keeps the bare slug, the nth gets `-{n-1}`.
    anchors.add(seenBefore === 0 ? base : `${base}-${seenBefore}`);
  }

  return anchors;
}

function internalLinks(markdown) {
  const found = [];
  withoutFencedBlocks(markdown).forEach((line, index) => {
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

  test("a heading inside a fenced block mints no anchor", () => {
    // The phantom-anchor case, on a fixture: today's README has no heading-shaped line inside
    // a fence, so the real file cannot exercise this and a check against it would be green
    // whatever this function did.
    const fixture = [
      "## Real heading",
      "",
      "```bash",
      "# set your keys",
      "export LOOPCTL_ORCH_KEY=lc_...",
      "```",
      "",
      "~~~json",
      "### not a heading either",
      "~~~",
    ].join("\n");

    const anchors = headingAnchors(fixture);

    assert.ok(anchors.has("real-heading"), "the heading outside the fence was lost");
    assert.ok(!anchors.has("set-your-keys"), "a shell comment inside a fence minted an anchor");
    assert.ok(!anchors.has("not-a-heading-either"), "a ~~~ fence was not honoured");
  });

  test("an anchor link inside a fenced block is not checked", () => {
    // The mirror bug: a link in an EXAMPLE is documentation, not navigation. Checking it makes
    // the README fail its own test for showing someone what markdown looks like.
    const fixture = ["# Heading", "", "```md", "[see](#a-section-that-does-not-exist)", "```"].join(
      "\n",
    );

    assert.deepEqual(internalLinks(fixture), []);
  });

  test("an info string does not close the fence it opens", () => {
    // ```bash is an OPENING fence. A scanner that closed on it would treat the block's body as
    // prose and re-open on the real closing fence, inverting inside and outside.
    const fixture = ["```bash", "# phantom", "```", "", "## After the fence"].join("\n");

    const anchors = headingAnchors(fixture);

    assert.ok(!anchors.has("phantom"));
    assert.ok(anchors.has("after-the-fence"), "everything after the fence was swallowed");
  });

  test("duplicate headings anchor the way GitHub suffixes them", () => {
    const fixture = ["## Requirements", "## Requirements", "## Requirements"].join("\n");

    const anchors = headingAnchors(fixture);

    assert.deepEqual([...anchors].sort(), ["requirements", "requirements-1", "requirements-2"]);
  });

  test("every anchor link points at a heading that exists", () => {
    const anchors = headingAnchors(README);
    const links = internalLinks(README);

    // A check with nothing to check is a green that means nothing — and now that the scanner
    // BLANKS parts of the file, an over-eager stripper is a live way to reach that state.
    assert.ok(links.length >= 5, `only ${links.length} in-document links found`);
    assert.ok(anchors.size >= 20, `only ${anchors.size} headings found; is the stripper eating the file?`);

    const broken = links.filter((link) => !anchors.has(link.anchor));

    assert.deepEqual(
      broken,
      [],
      `broken anchors: ${broken.map((b) => `README.md:${b.line} -> #${b.anchor}`).join(", ")}`,
    );
  });
});
