/**
 * #658 — client-supplied search context.
 *
 * These pin the OBSERVABILITY contract, not a behaviour of the KB: which facts about the
 * calling agent the MCP server can actually see, and that it never invents the ones it
 * cannot. Model is the case that matters — it is NOT in the environment, and a test that
 * quietly accepted a fabricated value would put a wrong model on every row.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import { clientContext, clientContextHeader, resetRepoCache } from "../lib/client-context.js";

const here = dirname(fileURLToPath(import.meta.url));

function withEnv(vars, fn) {
  const saved = {};
  for (const [k, v] of Object.entries(vars)) {
    saved[k] = process.env[k];
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    return fn();
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

test("captures the facts that ARE observable", () => {
  withEnv(
    {
      CLAUDE_SESSION_ID: "sess-123",
      CLAUDE_EFFORT: "high",
      CLAUDE_CODE_ENTRYPOINT: "cli",
      CLAUDE_CODE_CHILD_SESSION: "1",
    },
    () => {
      const ctx = clientContext({ version: "2.9.9" });
      assert.equal(ctx.session_id, "sess-123");
      assert.equal(ctx.effort, "high");
      assert.equal(ctx.entrypoint, "cli");
      assert.equal(ctx.kind, "child");
      assert.equal(ctx.version, "2.9.9");
      assert.ok(ctx.host, "hostname is always available");
    },
  );
});

test("a MAIN session is distinguishable from a dispatched child", () => {
  // These populations search differently by construction — a child never receives the
  // recall-pack injection — and an audit measured materially different failure rates
  // across them, so averaging them hides all of it.
  withEnv({ CLAUDE_CODE_CHILD_SESSION: "1" }, () => {
    assert.equal(clientContext().kind, "child");
  });
  withEnv({ CLAUDE_CODE_CHILD_SESSION: "0" }, () => {
    assert.equal(clientContext().kind, "main");
  });
});

test("an UNSET child flag on a recognisable session IS main, not NULL", () => {
  // A main session sets no child marker, so requiring the marker put every main session in
  // the NULL bucket — the bucket that has to mean "no context sent at all".
  withEnv({ CLAUDE_CODE_CHILD_SESSION: undefined, CLAUDE_SESSION_ID: "sess-9" }, () => {
    assert.equal(clientContext().kind, "main");
  });
});

test("with nothing identifying the caller, kind is omitted rather than guessed", () => {
  withEnv(
    {
      CLAUDE_CODE_CHILD_SESSION: undefined,
      CLAUDE_SESSION_ID: undefined,
      CLAUDE_CODE_SESSION_ID: undefined,
    },
    () => {
      assert.equal("kind" in clientContext(), false);
    },
  );
});

test("a WORKFLOW agent is not falsely labelled — the flag cannot see it", () => {
  // CLAUDE_CODE_WORKFLOWS is a feature flag present in MAIN sessions too, so it must never
  // be read as "this is a workflow agent". The third value is an offline join, not a guess.
  withEnv(
    { CLAUDE_CODE_WORKFLOWS: "1", CLAUDE_CODE_CHILD_SESSION: undefined, CLAUDE_SESSION_ID: "s" },
    () => {
      // "main" is what an absent marker means; the flag must never upgrade that to a
      // workflow label. The third value is an offline join, not a guess.
      assert.equal(clientContext().kind, "main");
    },
  );
});

test("model is NOT fabricated when the runtime does not expose it", () => {
  // Verified 2026-08-12: no model variable exists in a live session's environment. The
  // field must stay absent so an offline join on session_id supplies the truth, rather
  // than every row carrying a confident guess.
  withEnv({ CLAUDE_MODEL: undefined, ANTHROPIC_MODEL: undefined }, () => {
    assert.equal("model" in clientContext(), false);
  });
});

test("model IS captured the day a variable appears", () => {
  withEnv({ CLAUDE_MODEL: "claude-opus-5" }, () => {
    assert.equal(clientContext().model, "claude-opus-5");
  });
});

test("blank env values are treated as absent, not as empty strings", () => {
  // Both session variables must be cleared: session_id falls back from CLAUDE_SESSION_ID
  // to CLAUDE_CODE_SESSION_ID, and a live session sets both.
  withEnv(
    { CLAUDE_EFFORT: "   ", CLAUDE_SESSION_ID: "", CLAUDE_CODE_SESSION_ID: undefined },
    () => {
      const ctx = clientContext();
      assert.equal("effort" in ctx, false);
      assert.equal("session_id" in ctx, false);
    },
  );
});

test("the header is base64 of the JSON payload, and round-trips", () => {
  withEnv({ CLAUDE_SESSION_ID: "sess-abc", CLAUDE_EFFORT: "low" }, () => {
    const header = clientContextHeader();
    const decoded = JSON.parse(Buffer.from(header, "base64").toString("utf8"));
    assert.equal(decoded.session_id, "sess-abc");
    assert.equal(decoded.effort, "low");
  });
});

test("repo detection normalises a git remote to owner/repo", () => {
  // Runs against this repo's own remote when present; the assertion tolerates its absence
  // (a CI checkout without an origin) rather than pinning a value that varies by host.
  resetRepoCache();
  const ctx = clientContext();
  if (ctx.repo) {
    assert.doesNotMatch(ctx.repo, /^https?:|\.git$|^git@/, "repo must be normalised, not raw");
  }
});

test("WIRING: apiCall actually SENDS the header — an unsent payload is no observability", () => {
  // The whole point is a populated `client_*` column. A module that builds a header nothing
  // attaches leaves all eight columns permanently NULL, so the schema's "WHO searches and
  // who fails" query collapses to one all-NULL group.
  const src = readFileSync(join(here, "..", "index.js"), "utf8");
  assert.match(src, /import \{ clientContextHeader \} from "\.\/lib\/client-context\.js";/);
  assert.match(src, /headers\["x-loopctl-client-context"\] = clientCtx;/);
});
