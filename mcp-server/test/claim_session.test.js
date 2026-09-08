/**
 * Tests for the #779 claim/lock SESSION discriminator (lib/claim-session.js) and its
 * WIRING in index.js.
 *
 * Two classes of defect are pinned here, and both were live:
 *
 *   1. MECHANISM — the (host, cwd) state file under os.tmpdir() is predictable from
 *      public data, so it needs the same CWE-59 discipline lib/witness-sth.js already
 *      applies to loopctl-mcp-sth-<digest>.json: lstat + symlink/uid refusal on read,
 *      O_EXCL + rename on write, and a shape check so a planted value is never adopted.
 *   2. WIRING — resolution order (the per-session env marker beats the durable file, and
 *      the SPECIFIC marker beats the inherited one), and which call sites in index.js
 *      stamp the CLAIM discriminator rather than the post one. channel_lock /
 *      channel_unlock resolve ownership by session slot, so they belong to the claim
 *      family; a source-scan is what stops one of them silently drifting back.
 *
 * Run: node --test test/*.test.js
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, mkdtempSync, writeFileSync, symlinkSync, rmSync } from "node:fs";
import * as realFs from "node:fs";
import os from "node:os";
import { fileURLToPath } from "node:url";
import path from "node:path";
import crypto from "node:crypto";

import {
  envClaimSessionId,
  durableClaimSessionPath,
  readDurableClaimSessionId,
  durableClaimSessionId,
  resolveClaimSessionId,
} from "../lib/claim-session.js";

const INDEX_SRC = readFileSync(
  path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "index.js"),
  "utf8",
);

const UUID = "11111111-2222-4333-8444-555555555555";

function tmpDir() {
  const dir = mkdtempSync(path.join(os.tmpdir(), "loopctl-claim-session-test-"));
  return dir;
}

function fsDeps(overrides = {}) {
  return {
    fs: realFs,
    getuid: typeof process.getuid === "function" ? () => process.getuid() : undefined,
    randomUUID: () => UUID,
    randomBytes: (n) => crypto.randomBytes(n),
    pid: process.pid,
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// Resolution order — the WIRING that decides which id a session actually stamps
// ---------------------------------------------------------------------------

describe("envClaimSessionId (resolution order)", () => {
  test("prefers the per-session CLAUDE_CODE_SESSION_ID over the INHERITED CLAUDE_SESSION_ID", () => {
    // A headless subsession inherits its launcher's CLAUDE_SESSION_ID and carries its
    // own CLAUDE_CODE_SESSION_ID. Preferring the inherited one merges two concurrent
    // sessions onto one discriminator, which is the silent destructive direction.
    assert.equal(
      envClaimSessionId({
        CLAUDE_SESSION_ID: "inherited-from-launcher",
        CLAUDE_CODE_SESSION_ID: "this-session-only",
      }),
      "this-session-only",
    );
  });

  test("falls back to CLAUDE_SESSION_ID when the specific marker is absent or blank", () => {
    assert.equal(
      envClaimSessionId({ CLAUDE_SESSION_ID: "sess-a", CLAUDE_CODE_SESSION_ID: "   " }),
      "sess-a",
    );
  });

  test("returns null when no session marker is present", () => {
    assert.equal(envClaimSessionId({}), null);
  });
});

describe("resolveClaimSessionId", () => {
  test("an env marker wins outright — the durable file is never consulted", () => {
    const exploded = () => {
      throw new Error("the durable file must not be read when a session marker exists");
    };
    const id = resolveClaimSessionId({
      env: { CLAUDE_CODE_SESSION_ID: "env-session" },
      fs: { readFileSync: exploded, lstatSync: exploded, writeFileSync: exploded, renameSync: exploded },
      randomUUID: () => UUID,
      randomBytes: (n) => crypto.randomBytes(n),
      tmpdir: os.tmpdir(),
      hostname: "h",
      cwd: "/c",
      createHash: (alg) => crypto.createHash(alg),
      join: path.join,
    });
    assert.equal(id, "env-session");
  });

  test("with no env marker it mints and then re-reads the same durable id", () => {
    const dir = tmpDir();
    try {
      const deps = {
        env: {},
        ...fsDeps(),
        tmpdir: dir,
        hostname: "h",
        cwd: "/c",
        createHash: (alg) => crypto.createHash(alg),
        join: path.join,
      };
      assert.equal(resolveClaimSessionId(deps), UUID);
      // A respawned proxy in the same root re-reads it rather than minting a new one.
      assert.equal(
        resolveClaimSessionId({ ...deps, randomUUID: () => "22222222-2222-4333-8444-555555555555" }),
        UUID,
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("durableClaimSessionPath", () => {
  test("separates two directories on one host", () => {
    const base = { tmpdir: "/tmp", hostname: "h", createHash: (a) => crypto.createHash(a), join: path.join };
    assert.notEqual(
      durableClaimSessionPath({ ...base, cwd: "/a" }),
      durableClaimSessionPath({ ...base, cwd: "/b" }),
    );
  });
});

// ---------------------------------------------------------------------------
// CWE-59 — the guards the sibling lib/witness-sth.js already applies
// ---------------------------------------------------------------------------

describe("readDurableClaimSessionId (symlink / ownership / shape guards)", () => {
  test("refuses a symlink instead of reading through it", () => {
    const dir = tmpDir();
    try {
      const victim = path.join(dir, "victim.txt");
      writeFileSync(victim, UUID);
      const planted = path.join(dir, "planted.id");
      symlinkSync(victim, planted);
      assert.equal(readDurableClaimSessionId(planted, fsDeps()), null);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("refuses a file owned by another uid", () => {
    const dir = tmpDir();
    try {
      const file = path.join(dir, "foreign.id");
      writeFileSync(file, UUID);
      const deps = fsDeps({ getuid: () => (process.getuid ? process.getuid() + 1 : 999999) });
      assert.equal(readDurableClaimSessionId(file, deps), null);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("refuses content that is not a minted uuid, so a planted value is never adopted", () => {
    const dir = tmpDir();
    try {
      const file = path.join(dir, "planted.id");
      writeFileSync(file, "sk-ant-api03-" + "a".repeat(300));
      assert.equal(readDurableClaimSessionId(file, fsDeps()), null);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("returns a well-formed minted id", () => {
    const dir = tmpDir();
    try {
      const file = path.join(dir, "good.id");
      writeFileSync(file, `${UUID}\n`);
      assert.equal(readDurableClaimSessionId(file, fsDeps()), UUID);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("durableClaimSessionId (atomic, symlink-safe mint)", () => {
  test("a planted symlink at the destination is REPLACED, never written through", () => {
    const dir = tmpDir();
    try {
      const victim = path.join(dir, "victim.json");
      writeFileSync(victim, "ORIGINAL");
      const file = path.join(dir, "claim.id");
      symlinkSync(victim, file);

      const id = durableClaimSessionId(file, fsDeps());

      assert.equal(id, UUID);
      assert.equal(readFileSync(victim, "utf8"), "ORIGINAL", "the symlink target was clobbered");
      assert.equal(realFs.lstatSync(file).isSymbolicLink(), false, "the symlink was followed, not replaced");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a symlink pre-planted at the TEMP path is refused by O_EXCL, not written through", () => {
    // The temp name carries the pid and 6 random bytes, so this is defence in depth
    // rather than the primary guard (rename is) — but flag \"wx\" is the only thing
    // holding it, and without a test it can be dropped with every assertion still green.
    const dir = tmpDir();
    try {
      const file = path.join(dir, "claim.id");
      const victim = path.join(dir, "victim.json");
      writeFileSync(victim, "ORIGINAL");
      const deps = fsDeps({ randomBytes: () => ({ toString: () => "abcdef" }), pid: 4242 });
      symlinkSync(victim, `${file}.4242.abcdef.tmp`);

      const id = durableClaimSessionId(file, deps);

      assert.equal(id, UUID, "the mint must degrade to an in-memory id, not throw");
      assert.equal(readFileSync(victim, "utf8"), "ORIGINAL", "O_EXCL did not refuse the planted temp path");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("concurrent minters CONVERGE on the value that won the slot", () => {
    const dir = tmpDir();
    try {
      const file = path.join(dir, "claim.id");
      const winner = "99999999-2222-4333-8444-555555555555";
      // The loser's rename lands first, then the winner's file is what a re-read sees.
      const loserDeps = fsDeps({
        randomUUID: () => UUID,
        fs: {
          ...realFs,
          renameSync: (from, to) => {
            realFs.renameSync(from, to);
            // A concurrent proxy wins the slot immediately afterwards.
            realFs.writeFileSync(to, winner);
          },
        },
      });
      assert.equal(durableClaimSessionId(file, loserDeps), winner);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("an unwritable temp dir degrades to an in-memory id rather than throwing", () => {
    const id = durableClaimSessionId("/proc/definitely/not/writable/claim.id", fsDeps());
    assert.equal(id, UUID);
  });
});

// ---------------------------------------------------------------------------
// WIRING in index.js — which call sites stamp the CLAIM discriminator
// ---------------------------------------------------------------------------

describe("index.js wiring", () => {
  test("CLAIM_SESSION_ID is resolved through the shared module, not re-implemented inline", () => {
    assert.match(INDEX_SRC, /import \{ resolveClaimSessionId \} from "\.\/lib\/claim-session\.js";/);
    assert.match(INDEX_SRC, /const CLAIM_SESSION_ID = resolveClaimSessionId\(\{/);
  });

  test("the lock paths stamp the CLAIM discriminator — their ownership is compared again later", () => {
    for (const name of ["channelLock", "channelUnlock"]) {
      const declaration = `async function ${name}(`;
      const start = INDEX_SRC.indexOf(declaration);
      assert.notEqual(start, -1, `index.js must define ${declaration}`);
      const rest = INDEX_SRC.slice(start + declaration.length);
      const next = rest.indexOf("\nasync function ");
      const body = next === -1 ? rest : rest.slice(0, next);
      assert.ok(body.trim().length > 0, `${name} must have a body`);
      assert.match(body, /payload\.session_id = CLAIM_SESSION_ID;/);
      assert.doesNotMatch(body, /payload\.session_id = CHANNEL_SESSION_ID;/);
    }
  });

  test("the post path still uses the process-lifetime id US-454 pins", () => {
    const start = INDEX_SRC.indexOf("async function channelPostRaw(");
    assert.notEqual(start, -1);
    const rest = INDEX_SRC.slice(start);
    const next = rest.indexOf("\nasync function ", 1);
    const body = next === -1 ? rest : rest.slice(0, next);
    assert.match(body, /session_id: CHANNEL_SESSION_ID|payload\.session_id = CHANNEL_SESSION_ID/);
  });
});
