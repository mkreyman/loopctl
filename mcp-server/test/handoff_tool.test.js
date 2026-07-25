/**
 * Tests for the one-call `handoff` tool (#528, follow-up to #517).
 *
 * SINGLE SOURCE OF TRUTH: every branch below runs the REAL composition code from
 * ../lib/handoff.js with the three HTTP calls injected as fakes — the same code index.js
 * ships. The final describe block source-scans index.js so the WIRING (tool declaration,
 * dispatch case, raw-function injection) cannot drift from the logic.
 *
 * Run: node --test test/*.test.js
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import {
  createHandoff,
  deriveSlug,
  handoffKey,
  repoBasename,
  HANDOFF_KEY_PREFIX,
  KEY_MAX_BYTES,
} from "../lib/handoff.js";

const INDEX_SRC = readFileSync(
  path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "index.js"),
  "utf8",
);

const REPO_URL = "git@github.com:mkreyman/claude-harness-kit.git";
const KB_PROJECT = {
  id: "b0917c9b-cc08-4cdf-8c9b-92ad1831eca5",
  kind: "kb",
  slug: "claude-harness-kit",
  name: "claude-harness-kit",
};

/**
 * Recording fakes shaped exactly like `apiCall` results: a success is the parsed body, a
 * failure is `{ error: true, status, body }`.
 */
function fakes({ resolve = [], create = [], post = null } = {}) {
  const calls = { resolve: [], create: [], post: [] };
  const resolveQueue = [...resolve];
  const createQueue = [...create];

  return {
    calls,
    deps: {
      resolveProject: async (args) => {
        calls.resolve.push(args);
        return resolveQueue.length ? resolveQueue.shift() : { error: true, status: 404, body: {} };
      },
      createKbScope: async (args) => {
        calls.create.push(args);
        return createQueue.length ? createQueue.shift() : { project: KB_PROJECT };
      },
      channelPost: async (args) => {
        calls.post.push(args);
        return post ?? { post: { id: "post-1", key: args.key }, created: true, meta: {} };
      },
    },
  };
}

const notFound = { error: true, status: 404, body: { error: { code: "not_found" } } };

// ---------------------------------------------------------------------------
// handoffKey — the convention that makes a handoff discoverable + claimable
// ---------------------------------------------------------------------------

describe("handoffKey", () => {
  test("prefixes a bare anchor", () => {
    assert.deepEqual(handoffKey("repo#812"), {
      key: "handoff:repo#812",
      anchor: "repo#812",
    });
  });

  test("is idempotent when the anchor already carries the prefix", () => {
    const { key } = handoffKey("handoff:repo#812");
    assert.equal(key, "handoff:repo#812");
    assert.ok(!key.startsWith(`${HANDOFF_KEY_PREFIX}${HANDOFF_KEY_PREFIX}`));
  });

  test("trims surrounding whitespace", () => {
    assert.equal(handoffKey("  repo#812  ").key, "handoff:repo#812");
  });

  test("rejects an empty or whitespace-only anchor with actionable text", () => {
    for (const value of ["", "   ", undefined, null, 42]) {
      const result = handoffKey(value);
      assert.ok(result.error, `expected ${JSON.stringify(value)} to be rejected`);
      assert.match(result.error, /anchor is required/);
      assert.match(result.error, /channel_handoffs/);
    }
  });

  test("rejects control characters and NUL", () => {
    for (const code of [0x00, 0x01, 0x0a, 0x1f, 0x7f]) {
      const result = handoffKey(`a${String.fromCharCode(code)}b`);
      assert.ok(result.error, `expected charCode ${code} to be rejected`);
      assert.match(result.error, /control characters/);
    }
  });

  test("enforces the 200-byte key cap, counting BYTES not characters", () => {
    const prefixBytes = Buffer.byteLength(HANDOFF_KEY_PREFIX, "utf8");
    const maxAnchor = "a".repeat(KEY_MAX_BYTES - prefixBytes);
    assert.equal(handoffKey(maxAnchor).key.length, KEY_MAX_BYTES);
    assert.match(handoffKey(`${maxAnchor}a`).error, /too long/);

    // A multi-byte anchor that is UNDER the cap in characters but OVER it in bytes.
    const multibyte = "é".repeat(KEY_MAX_BYTES - prefixBytes);
    assert.match(handoffKey(multibyte).error, /too long/);
  });
});

// ---------------------------------------------------------------------------
// slug/name derivation — determinism is the anti-duplicate-scope guarantee (AC4)
// ---------------------------------------------------------------------------

describe("repoBasename / deriveSlug", () => {
  test("handles every remote form", () => {
    assert.equal(deriveSlug("git@github.com:mkreyman/claude-harness-kit.git"), "claude-harness-kit");
    assert.equal(deriveSlug("https://github.com/mkreyman/claude-harness-kit"), "claude-harness-kit");
    assert.equal(deriveSlug("https://github.com/mkreyman/claude-harness-kit/"), "claude-harness-kit");
    assert.equal(deriveSlug("ssh://git@github.com/mkreyman/loopctl.git"), "loopctl");
    assert.equal(deriveSlug("mkreyman/loopctl"), "loopctl");
    assert.equal(deriveSlug("https://github.com/o/repo.git?ref=main#frag"), "repo");
  });

  test("normalizes underscores and case to the existing slug convention", () => {
    // The tenant's repo home_care_billing already maps to slug home-care-billing.
    assert.equal(deriveSlug("https://github.com/mkreyman/home_care_billing"), "home-care-billing");
    assert.equal(deriveSlug("git@github.com:o/AVA_Home_Care.git"), "ava-home-care");
  });

  test("preserves original casing for the display NAME", () => {
    assert.equal(repoBasename("git@github.com:o/AVA_Home_Care.git"), "AVA_Home_Care");
  });

  test("is deterministic — the same URL always derives the same slug (AC4)", () => {
    const runs = new Set(Array.from({ length: 5 }, () => deriveSlug(REPO_URL)));
    assert.equal(runs.size, 1);
    // Equivalent spellings of the same repo converge on one slug, so a retry that
    // spells the remote differently still resolves rather than creating a duplicate.
    assert.equal(
      deriveSlug("https://github.com/mkreyman/claude-harness-kit"),
      deriveSlug("git@github.com:mkreyman/claude-harness-kit.git"),
    );
  });

  test("produces a slug the server's format regex accepts, including at the length cap", () => {
    const serverFormat = /^[a-z0-9][a-z0-9-]*[a-z0-9]$/;
    const inputs = [
      REPO_URL,
      "o/repo_with_a_very_long_name_that_exceeds_sixty_three_characters_for_sure_yes",
      "o/UPPER_case-Mixed_99",
      // A truncation boundary that would otherwise leave a trailing hyphen.
      `o/${"a".repeat(62)}_tail`,
    ];
    for (const input of inputs) {
      const slug = deriveSlug(input);
      assert.ok(slug, `expected a slug for ${input}`);
      assert.ok(slug.length >= 2 && slug.length <= 63, `slug length out of range: ${slug}`);
      assert.match(slug, serverFormat);
    }
  });

  test("returns null when nothing valid can be derived", () => {
    for (const input of ["o/x", "o/---", "", "   ", null, undefined, "/"]) {
      assert.equal(deriveSlug(input), null, `expected null for ${JSON.stringify(input)}`);
    }
  });
});

// ---------------------------------------------------------------------------
// createHandoff — the composed sender flow
// ---------------------------------------------------------------------------

describe("createHandoff — existing channel (AC2)", () => {
  test("resolves, posts with the handoff: key, and never creates a scope", async () => {
    const { deps, calls } = fakes({ resolve: [{ project: KB_PROJECT }] });

    const result = await createHandoff(
      {
        anchor: "claude-harness-kit:review-vs-goal",
        body: "Review the kit against its goal. Full context: docs/handoff.md",
        repo_url: REPO_URL,
        to_capability: "fly-auth",
        refs: [{ type: "file", value: "docs/handoff.md" }],
      },
      deps,
    );

    assert.equal(result.error, undefined);
    assert.equal(calls.create.length, 0, "must not create a scope when one resolves");
    assert.equal(calls.post.length, 1);
    assert.equal(calls.post[0].key, "handoff:claude-harness-kit:review-vs-goal");
    assert.equal(calls.post[0].project_id, KB_PROJECT.id);
    assert.equal(calls.post[0].to_capability, "fly-auth");
    assert.deepEqual(calls.post[0].refs, [{ type: "file", value: "docs/handoff.md" }]);

    assert.equal(result.handoff.channel.created, false);
    assert.equal(result.handoff.channel.source, "resolved");
    assert.equal(result.handoff.channel.project_id, KB_PROJECT.id);
    assert.equal(result.handoff.key, "handoff:claude-harness-kit:review-vs-goal");
    assert.equal(result.handoff.anchor, "claude-harness-kit:review-vs-goal");
  });

  test("an explicit project_id skips resolution entirely", async () => {
    const { deps, calls } = fakes();

    const result = await createHandoff(
      { anchor: "a#1", body: "tldr + pointer", project_id: KB_PROJECT.id },
      deps,
    );

    assert.equal(calls.resolve.length, 0);
    assert.equal(calls.create.length, 0);
    assert.equal(result.handoff.channel.source, "explicit");
    assert.equal(result.handoff.channel.project_id, KB_PROJECT.id);
  });

  test("surfaces the receiver's next calls so the loop can be closed", async () => {
    const { deps } = fakes({ resolve: [{ project: KB_PROJECT }] });
    const result = await createHandoff({ anchor: "a#1", body: "tldr", repo_url: REPO_URL }, deps);

    const next = result.handoff.receiver_next.join(" ");
    assert.match(next, /channel_handoffs/);
    assert.match(next, /channel_claim/);
    assert.match(next, /channel_done/);
    assert.match(next, /handoff:a#1/);
  });
});

describe("createHandoff — no project yet (AC3, the #517 case)", () => {
  test("creates a kb scope from the derived slug, then posts", async () => {
    const { deps, calls } = fakes({ resolve: [notFound], create: [{ project: KB_PROJECT }] });

    const result = await createHandoff(
      { anchor: "claude-harness-kit:review", body: "tldr + pointer", repo_url: REPO_URL },
      deps,
    );

    assert.equal(result.error, undefined);
    assert.equal(calls.create.length, 1);
    assert.equal(calls.create[0].slug, "claude-harness-kit");
    assert.equal(calls.create[0].name, "claude-harness-kit");
    assert.equal(calls.create[0].repo_url, REPO_URL);
    assert.equal(calls.post[0].project_id, KB_PROJECT.id);

    assert.equal(result.handoff.channel.created, true);
    assert.equal(result.handoff.channel.source, "created");
    assert.equal(result.handoff.channel.kind, "kb");
  });

  test("an explicit slug overrides the derived one", async () => {
    const { deps, calls } = fakes({ resolve: [notFound] });
    await createHandoff(
      { anchor: "a#1", body: "tldr", repo_url: REPO_URL, slug: "custom-scope" },
      deps,
    );
    assert.equal(calls.create[0].slug, "custom-scope");
  });

  test("passes name/description/tech_stack through to the create only", async () => {
    const { deps, calls } = fakes({ resolve: [notFound] });
    await createHandoff(
      {
        anchor: "a#1",
        body: "tldr",
        repo_url: REPO_URL,
        name: "Harness Kit",
        description: "d",
        tech_stack: "t",
      },
      deps,
    );
    assert.equal(calls.create[0].name, "Harness Kit");
    assert.equal(calls.create[0].description, "d");
    assert.equal(calls.create[0].tech_stack, "t");
    assert.equal(calls.post[0].name, undefined);
  });

  test("NEVER attempts create_project — only create_kb_scope is injected", () => {
    // Structural guarantee: the composition has no create_project dependency at all, so
    // the #517 dead-end (403 custody_tier_required) is unreachable by construction.
    const src = readFileSync(
      path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "lib", "handoff.js"),
      "utf8",
    );
    assert.ok(
      !/createProject|\/api\/v1\/projects"/.test(src),
      "lib/handoff.js must not reference the work-project create path",
    );
  });
});

describe("createHandoff — create_channel: false (AC5)", () => {
  test("returns an actionable error and creates nothing", async () => {
    const { deps, calls } = fakes({ resolve: [notFound] });

    const result = await createHandoff(
      { anchor: "a#1", body: "tldr", repo_url: REPO_URL, create_channel: false },
      deps,
    );

    assert.equal(result.error, true);
    assert.equal(result.stage, "resolve");
    assert.equal(result.status, 404);
    assert.equal(calls.create.length, 0, "must not create when create_channel is false");
    assert.equal(calls.post.length, 0);
    assert.match(result.body, /create_kb_scope/);
    assert.match(result.body, /create_channel is false/);
  });
});

describe("createHandoff — failure passthrough (AC6)", () => {
  test("a non-404 resolve failure does NOT trigger a create", async () => {
    const { deps, calls } = fakes({
      resolve: [{ error: true, status: 401, body: { error: { code: "unauthorized" } } }],
    });

    const result = await createHandoff({ anchor: "a#1", body: "tldr", repo_url: REPO_URL }, deps);

    assert.equal(result.error, true);
    assert.equal(result.stage, "resolve");
    assert.equal(result.status, 401);
    assert.equal(calls.create.length, 0, "an auth failure must not be papered over by a create");
    assert.equal(calls.post.length, 0);
  });

  test("a 403 on create is surfaced verbatim with remediation", async () => {
    const body = { error: { code: "custody_tier_required" } };
    const { deps, calls } = fakes({
      resolve: [notFound, notFound],
      create: [{ error: true, status: 403, body }],
    });

    const result = await createHandoff({ anchor: "a#1", body: "tldr", repo_url: REPO_URL }, deps);

    assert.equal(result.error, true);
    assert.equal(result.stage, "create_channel");
    assert.equal(result.status, 403);
    assert.deepEqual(result.body, body, "the server body must be passed through unchanged");
    assert.equal(result.attempted_slug, "claude-harness-kit");
    assert.match(result.remediation, /kb_project_scopes/);
    assert.equal(calls.post.length, 0);
  });

  test("a 422 on create explains the cap and the explicit-slug escape", async () => {
    const { deps } = fakes({
      resolve: [notFound, notFound],
      create: [{ error: true, status: 422, body: { error: { code: "unprocessable_entity" } } }],
    });

    const result = await createHandoff({ anchor: "a#1", body: "tldr", repo_url: REPO_URL }, deps);

    assert.equal(result.stage, "create_channel");
    assert.match(result.remediation, /max_projects/);
    assert.match(result.remediation, /archive_kb_scope/);
  });

  test("a post failure still reports the channel that was created", async () => {
    const { deps } = fakes({
      resolve: [notFound],
      create: [{ project: KB_PROJECT }],
      post: { error: true, status: 422, body: { error: { code: "unprocessable_entity" } } },
    });

    const result = await createHandoff({ anchor: "a#1", body: "tldr", repo_url: REPO_URL }, deps);

    assert.equal(result.error, true);
    assert.equal(result.stage, "post");
    assert.equal(result.status, 422);
    // Without this the retry cannot tell a scope was already created and would make another.
    assert.equal(result.channel.created, true);
    assert.equal(result.channel.project_id, KB_PROJECT.id);
  });

  test("a 2xx resolve with no project refuses to create rather than guessing", async () => {
    const { deps, calls } = fakes({ resolve: [{ matched_by: "slug" }] });

    const result = await createHandoff({ anchor: "a#1", body: "tldr", repo_url: REPO_URL }, deps);

    assert.equal(result.error, true);
    assert.equal(result.stage, "resolve");
    assert.equal(calls.create.length, 0);
  });
});

describe("createHandoff — concurrent create race converges on one scope (AC4)", () => {
  test("a failed create re-resolves and uses the scope the peer created", async () => {
    const { deps, calls } = fakes({
      // 1st resolve: nothing. Create loses the race. 2nd resolve: the peer's scope.
      resolve: [notFound, { project: KB_PROJECT }],
      create: [{ error: true, status: 422, body: { error: { code: "slug_taken" } } }],
    });

    const result = await createHandoff({ anchor: "a#1", body: "tldr", repo_url: REPO_URL }, deps);

    assert.equal(result.error, undefined, "a lost race must converge, not fail");
    assert.equal(calls.create.length, 1, "must not retry the create");
    assert.equal(result.handoff.channel.created, false);
    assert.equal(result.handoff.channel.raced, true);
    assert.equal(result.handoff.channel.project_id, KB_PROJECT.id);
    assert.equal(calls.post[0].project_id, KB_PROJECT.id);
  });

  test("the race re-resolve uses the deterministic slug, not just the repo_url", async () => {
    const { deps, calls } = fakes({
      resolve: [notFound, { project: KB_PROJECT }],
      create: [{ error: true, status: 422, body: {} }],
    });

    await createHandoff({ anchor: "a#1", body: "tldr", repo_url: REPO_URL }, deps);

    assert.equal(calls.resolve.length, 2);
    assert.equal(calls.resolve[1].slug, "claude-harness-kit");
  });
});

describe("createHandoff — input validation", () => {
  test("requires an anchor", async () => {
    const { deps, calls } = fakes();
    const result = await createHandoff({ body: "tldr", repo_url: REPO_URL }, deps);
    assert.equal(result.error, true);
    assert.equal(result.stage, "validate");
    assert.equal(calls.resolve.length, 0);
  });

  test("requires a body, and says pointer-not-payload", async () => {
    const { deps, calls } = fakes();
    for (const body of [undefined, "", "   "]) {
      const result = await createHandoff({ anchor: "a#1", body, repo_url: REPO_URL }, deps);
      assert.equal(result.error, true);
      assert.equal(result.stage, "validate");
      assert.match(result.body, /POINTER not a payload/);
    }
    assert.equal(calls.resolve.length, 0);
  });

  test("requires one of repo_url / slug / project_id", async () => {
    const { deps, calls } = fakes();
    const result = await createHandoff({ anchor: "a#1", body: "tldr" }, deps);
    assert.equal(result.error, true);
    assert.equal(result.stage, "validate");
    assert.match(result.body, /repo_url/);
    assert.equal(calls.resolve.length, 0);
  });

  test("reports an underivable slug instead of sending a doomed create", async () => {
    const { deps, calls } = fakes({ resolve: [notFound] });
    const result = await createHandoff({ anchor: "a#1", body: "tldr", repo_url: "o/x" }, deps);
    assert.equal(result.error, true);
    assert.equal(result.stage, "validate");
    assert.match(result.body, /explicit slug/);
    assert.equal(calls.create.length, 0);
  });

  test("validation runs before any network call", async () => {
    const { deps, calls } = fakes();
    await createHandoff({}, deps);
    assert.equal(calls.resolve.length + calls.create.length + calls.post.length, 0);
  });
});

// ---------------------------------------------------------------------------
// Wiring — index.js must expose the tool and inject the RAW request functions
// ---------------------------------------------------------------------------

describe("index.js wiring (#528)", () => {
  test("declares a `handoff` tool that teaches the key convention and pointer-not-payload", () => {
    assert.match(INDEX_SRC, /name: "handoff",/, "the handoff tool must be declared");
    const declaration = INDEX_SRC.slice(
      INDEX_SRC.indexOf('name: "handoff",'),
      INDEX_SRC.indexOf('name: "channel_post",'),
    );
    assert.match(declaration, /handoff:<anchor>/, "must document the key convention");
    assert.match(declaration, /POINTER, NOT PAYLOAD/i, "must state pointer-not-payload");
    assert.match(declaration, /channel_claim/, "must point at the receiver flow");
    assert.match(declaration, /required: \["anchor", "body"\]/);
  });

  test("dispatches the handoff tool", () => {
    assert.match(INDEX_SRC, /case "handoff":\s*\n\s*return await handoff\(args\);/);
  });

  test("injects the raw request functions, so composed calls cannot drift", () => {
    assert.match(
      INDEX_SRC,
      /createHandoff\(args, \{\s*resolveProject: resolveProjectRaw,\s*createKbScope: createKbScopeRaw,\s*channelPost: channelPostRaw,\s*\}\)/,
    );
    assert.match(INDEX_SRC, /import \{ createHandoff \} from ".\/lib\/handoff.js";/);
  });

  test("the public tools still wrap the same raw functions (no duplicated paths)", () => {
    for (const [wrapper, raw] of [
      ["resolveProject", "resolveProjectRaw"],
      ["createKbScope", "createKbScopeRaw"],
      ["channelPost", "channelPostRaw"],
    ]) {
      const re = new RegExp(
        `async function ${wrapper}\\(args[^)]*\\) \\{\\s*return toContent\\(await ${raw}\\(args\\)\\);`,
      );
      assert.match(INDEX_SRC, re, `${wrapper} must delegate to ${raw}`);
    }
    // Each request path must appear exactly once — the raw function is its only home.
    for (const p of ["/api/v1/kb-scopes\"", "/api/v1/channel/posts\""]) {
      assert.equal(
        INDEX_SRC.split(p).length - 1,
        1,
        `${p} must be declared exactly once (in its raw function)`,
      );
    }
  });
});
