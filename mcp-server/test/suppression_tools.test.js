/**
 * The reversible retrieval tombstone, on the MCP surface.
 *
 * Two things are worth pinning in a source-level test rather than a behavioural one, because
 * both are properties of the TEXT an agent reads:
 *
 *   1. the tools are registered AND dispatched (a definition with no case is a tool that
 *      always errors at call time), and
 *   2. the description distinguishes suppress from archive and unpublish. An agent picks
 *      between three retraction verbs from these strings alone, and picking `archive` when it
 *      meant `suppress` is a one-way door (#605/#606).
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const dir = path.dirname(fileURLToPath(import.meta.url));
const indexSource = readFileSync(path.join(dir, "..", "index.js"), "utf8");
const readmeSource = readFileSync(path.join(dir, "..", "README.md"), "utf8");

// The slice of the TOOLS array covering exactly one tool object. Bounded at the NEXT
// tool's `name:` key (and at the array terminator for the last entry), because an
// unbounded slice runs into its neighbour and a positive assertion then passes on the
// neighbour's text — knowledge_unsuppress's own description names knowledge_archive, so
// every "the description mentions X" check below would be satisfiable by the wrong tool.
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

describe("knowledge_suppress / knowledge_unsuppress", () => {
  test("both are registered with a definition and dispatched to their OWN handler", () => {
    // Pin the case to its HANDLER, not just to the label: `case "knowledge_suppress":`
    // followed by `return await knowledgeArchive(args)` is a tool that silently archives,
    // and a label-only assertion passes on it (the finding recorded in the corpus_* review).
    for (const [name, handler] of [
      ["knowledge_suppress", "knowledgeSuppress"],
      ["knowledge_unsuppress", "knowledgeUnsuppress"],
    ]) {
      assert.ok(indexSource.includes(`name: "${name}"`), `${name} tool definition present`);
      assert.match(
        indexSource,
        new RegExp(`case "${name}":\\s*\\n\\s*return await ${handler}\\(args\\);`),
        `${name} dispatches to ${handler}`
      );
    }
  });

  test("both are documented in the README, which is the source of truth for the list", () => {
    for (const name of ["knowledge_suppress", "knowledge_unsuppress"]) {
      assert.ok(readmeSource.includes(`\`${name}\``), `${name} has a README row`);
    }
  });

  test("suppress requires a reason — a tombstone without one is not inspectable", () => {
    const block = toolDefinitionSource("knowledge_suppress");

    assert.ok(/required: \["article_id", "reason"\]/.test(block), "reason is a required arg");
  });

  test("the description tells an agent when to pick this over archive and unpublish", () => {
    const block = toolDefinitionSource("knowledge_suppress");

    // The whole reason this tool exists: archive is terminal, unpublish means "draft".
    assert.ok(/knowledge_archive/.test(block), "names archive as the non-undoable alternative");
    assert.ok(/knowledge_unpublish/.test(block), "names unpublish as the other undoable one");
    assert.ok(/knowledge_unsuppress/.test(block), "names its own undo");
    assert.ok(/knowledge_get/.test(block), "says the article stays readable by id");
  });

  test("suppress calls POST /suppress with the reason on the AGENT key", () => {
    const idx = indexSource.indexOf("async function knowledgeSuppress");
    assert.ok(idx > 0, "knowledgeSuppress is defined");
    const block = indexSource.slice(idx, idx + 600);

    assert.ok(block.includes("/suppress`"), "posts to the suppress path");
    assert.ok(block.includes("{ reason }"), "forwards the reason as the body");
    assert.ok(block.includes("LOOPCTL_AGENT_KEY"), "agent role, per the #331 carve-out");
  });

  test("unsuppress calls POST /unsuppress with no body on the AGENT key", () => {
    const idx = indexSource.indexOf("async function knowledgeUnsuppress");
    assert.ok(idx > 0, "knowledgeUnsuppress is defined");
    const block = indexSource.slice(idx, idx + 600);

    assert.ok(block.includes("/unsuppress`"), "posts to the unsuppress path");
    assert.ok(block.includes("LOOPCTL_AGENT_KEY"), "agent role");
  });
});
