/**
 * A TOOL'S DESCRIPTION MAY NOT OFFER A PARAMETER ITS SCHEMA DOES NOT DECLARE (loopctl #846.5).
 *
 * THE DEFECT. `place_dispatch`'s description said loopctl fills `repo` and `base_branch` from
 * the project's intake source and that a caller may "pass any of them to override"; its
 * `inputSchema` declared `base_branch` and not `repo`. loopctl's own refusal then instructed
 * the operator to use the undeclared one: `409 no_intake_source` says "Enrol an intake source
 * for the project, or pass `repo` and `base_branch` explicitly"
 * (`lib/loopctl_web/controllers/dispatch_placement_controller.ex:418-426`).
 *
 * It worked only by tolerance. The schema sets no `additionalProperties: false`, so an
 * undeclared `repo` passed the client validator untyped and reached the endpoint; a stricter
 * MCP client, or one reasonable decision to close the schema, removes the only expressible
 * remedy for that refusal, and the operator has no way to see why — the parameter they were
 * told to pass was never declared.
 *
 * WHY THE CHECK READS DESCRIPTIONS INSTEAD OF PINNING THIS TOOL. The same drift is possible on
 * any tool whose description enumerates overrides, and a per-defect test cannot find the next
 * one. `offeredParameters` (`test/tool-surface.js`) is deliberately narrow — a description
 * names response fields, error codes, sibling tools and enum values too, and a blanket rule
 * over every backticked token found 111 of them across 147 tools. Only two shapes are claimed
 * as offers: an offer VERB governing a token directly, and an ANAPHORIC offer ("pass any of
 * them") whose referent is the enumeration in the sentence before it. The second shape is the
 * one that matters here: nothing adjacency-based reaches across the sentence boundary that hid
 * `repo`.
 *
 * THE EXTRACTOR IS PINNED SEPARATELY, on fixtures. Running it over the shipped surface proves
 * the surface is clean; it does not prove the extractor can still say anything. The fixtures
 * below are hand-written declarations that fail it, so a rule quietly narrowed into inertness
 * turns them red.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { declaredParameters, loadTools, offeredParameters } from "./tool-surface.js";

const TOOLS = loadTools();

function toolNamed(name) {
  const tool = TOOLS.find((t) => t.name === name);
  assert.ok(tool, `${name} is not declared`);
  return tool;
}

describe("the offer extractor itself", () => {
  test("reads a DIRECT offer — an offer verb governing the token", () => {
    assert.deepEqual([...offeredParameters("Pass `repo` to override the default.")], ["repo"]);
    assert.deepEqual([...offeredParameters("Send the `base_branch` too.")], ["base_branch"]);
    assert.deepEqual([...offeredParameters("Set `max_turns` for a longer session.")], ["max_turns"]);
  });

  test("reads an ANAPHORIC offer — the enumeration the cue refers back to", () => {
    // The shape that hid #846.5. The tokens are in one sentence and the offer is in the next.
    const offered = offeredParameters(
      "loopctl fills `repo` and `base_branch` from the intake source. Pass any of them to override.",
    );

    assert.ok(offered.has("repo"), "the anaphoric window did not reach the previous sentence");
    assert.ok(offered.has("base_branch"));
  });

  test("does NOT read a response field, an error code or a destination tool as an offer", () => {
    // These are the false positives a blanket rule produces, and each is a real sentence
    // shape from this surface. If any starts being reported, the check has stopped being
    // about parameters and the shipped-surface scan below becomes noise an author silences.
    assert.equal(offeredParameters("Returns `claim_epoch` and `lock_version`.").size, 0);
    assert.equal(offeredParameters("409 `invalid_transition` names the stage.").size, 0);
    assert.equal(
      offeredParameters("Returns the hex attestation to pass to `dispatch`.").size,
      0,
      "`pass to X` names a destination tool, not a parameter of this one",
    );
    assert.equal(
      offeredParameters("Set LOOPCTL_ORCH_KEY to an orchestrator-role key.").size,
      0,
      "an env var is not a parameter",
    );
  });

  test("catches a synthetic tool whose description offers what its schema lacks", () => {
    // The whole check, against declarations that exist only here — so it stays falsifiable
    // when every shipped description is clean, which is the state this PR leaves them in.
    const fixtures = [
      {
        name: "direct",
        description: "Pass `region` to override the default.",
        inputSchema: { type: "object", properties: { id: { type: "string" } } },
        expected: ["region"],
      },
      {
        name: "anaphoric",
        description:
          "loopctl derives `repo` and `branch` from the story. Pass any of them to override.",
        inputSchema: { type: "object", properties: { branch: { type: "string" } } },
        expected: ["repo"],
      },
      {
        name: "clean",
        description: "Pass `branch` to override the default.",
        inputSchema: { type: "object", properties: { branch: { type: "string" } } },
        expected: [],
      },
    ];

    for (const fixture of fixtures) {
      const declared = declaredParameters(fixture);
      const undeclared = [...offeredParameters(fixture.description)].filter(
        (p) => !declared.has(p),
      );
      assert.deepEqual(undeclared.sort(), fixture.expected, `fixture ${fixture.name}`);
    }
  });
});

describe("every declared tool", () => {
  test("declares every parameter its own description offers", () => {
    const drift = [];

    for (const tool of TOOLS) {
      const declared = declaredParameters(tool);
      for (const offered of offeredParameters(tool.description ?? "")) {
        if (!declared.has(offered)) drift.push(`${tool.name}: offers \`${offered}\``);
      }
    }

    assert.deepEqual(
      drift,
      [],
      "a tool description tells the caller to pass a parameter its inputSchema does not " +
        "declare. It reaches the server today only because no schema here sets " +
        "additionalProperties: false. Declare it, or stop offering it.",
    );
  });

  test("the scan is not vacuous — it reads the descriptions it claims to", () => {
    // A guard that silently stopped finding descriptions would pass the assertion above for
    // ever. Anchored on the tool the defect was found on, whose description does carry an
    // anaphoric offer.
    const offered = offeredParameters(toolNamed("place_dispatch").description);

    assert.ok(offered.size > 0, "place_dispatch's description yielded no offers at all");
    assert.ok(offered.has("repo"), "the offer of `repo` is no longer being read");
  });
});

describe("place_dispatch declares `repo`", () => {
  test("it is in the schema, typed, and says base_branch belongs with it", () => {
    const repo = toolNamed("place_dispatch").inputSchema.properties.repo;

    assert.ok(repo, "place_dispatch does not declare `repo`");
    assert.equal(repo.type, "string");
    assert.match(
      repo.description,
      /base_branch/,
      "the declaration does not say base_branch is expected alongside it",
    );
  });
});
