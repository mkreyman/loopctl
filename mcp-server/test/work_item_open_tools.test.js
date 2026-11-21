/**
 * US-52.18 on the MCP side: work_item_open, and the heartbeat's branch open.
 *
 * TC-52.18.6: two heartbeats on fix/x open it once, the default branch opens nothing, and a
 * 409 on a new branch is sent once and not retried. The last block source-pins index.js.
 *
 * Run: node --test test/*.test.js
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { createBranchItemOpener, openWorkItem, WORK_ITEMS_PATH } from "../lib/branch-item.js";
import { createHolderSession } from "../lib/holder.js";
import { stripComments } from "./tool-surface.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");
const README = readFileSync(path.join(DIR, "..", "README.md"), "utf8");

const REPO = "git@github.com:mkreyman/chg.git";

function stubGit(state) {
  return async (args) => {
    const cmd = args.slice(2).join(" ");
    if (cmd === "rev-parse --abbrev-ref HEAD") return state.branch;
    if (cmd === "symbolic-ref refs/remotes/origin/HEAD") return state.originHead;
    if (cmd === "remote get-url origin") return REPO;
    return null;
  };
}

describe("work_item_open", () => {
  test("POSTs repo_url and branch, plus title and epic_id when given", async () => {
    const calls = [];
    const apiCall = async (method, p, body) => {
      calls.push({ method, path: p, body });
      return { ok: true };
    };

    await openWorkItem({ repo_url: REPO, branch: "fix/x" }, { apiCall });
    await openWorkItem({ repo_url: REPO, branch: "fix/x", title: "T", epic_id: "e" }, { apiCall });

    assert.equal(WORK_ITEMS_PATH, "/api/v1/work_items");
    assert.deepEqual(calls[0], {
      method: "POST",
      path: WORK_ITEMS_PATH,
      body: { repo_url: REPO, branch: "fix/x" },
    });
    assert.deepEqual(calls[1].body, { repo_url: REPO, branch: "fix/x", title: "T", epic_id: "e" });
  });

  test("refuses locally, sending nothing, without a repo_url or branch", async () => {
    for (const args of [{ branch: "fix/x" }, { repo_url: REPO }, { repo_url: REPO, branch: " " }]) {
      const calls = [];
      const result = await openWorkItem(args, { apiCall: async () => calls.push(1) });
      assert.equal(result.error, true);
      assert.equal(calls.length, 0);
    }
  });
});

describe("the heartbeat's branch open (TC-52.18.6)", () => {
  function session(state, respond) {
    const posts = [];
    const logs = [];

    const apiCall = async (method, p, body, key, opts) => {
      if (p === "/api/v1/holders") {
        return { holder: { id: "h-1" }, credential: { raw_key: "hk" }, heartbeat_seconds: 60 };
      }
      if (p.endsWith("/heartbeat")) return { lease_until: "later" };
      if (p === WORK_ITEMS_PATH) {
        posts.push({ body, key, opts });
        return respond(body);
      }
      return { error: true, status: 404, body: "no" };
    };

    const opener = createBranchItemOpener({
      apiCall,
      git: stubGit(state),
      worktree: () => "/wt",
      log: (line) => logs.push(line),
    });

    const holder = createHolderSession({
      apiCall,
      env: { LOOPCTL_AGENT_KEY: "plain", CLAUDE_CODE_SESSION_ID: "s-1" },
      hostname: () => "minis",
      worktree: () => "/wt",
      randomUUID: () => "u",
      setInterval: () => null,
      clearInterval: () => {},
      afterBeat: (h, c) => opener.tick(h, c),
    });

    return { holder, posts, logs };
  }

  test("opens a non-default branch once, on the holder credential", async () => {
    const state = { branch: "fix/x", originHead: "refs/remotes/origin/master" };
    const { holder, posts } = session(state, () => ({ outcome: "created" }));

    await holder.register();
    await holder.heartbeat();
    await holder.heartbeat();

    assert.equal(posts.length, 1);
    assert.deepEqual(posts[0].body, { repo_url: REPO, branch: "fix/x" });
    assert.equal(posts[0].key, "hk");
    assert.deepEqual(posts[0].opts, { exactKey: true });
  });

  test("the default branch and a detached HEAD open nothing", async () => {
    const state = { branch: "master", originHead: "refs/remotes/origin/master" };
    const { holder, posts } = session(state, () => ({ outcome: "created" }));

    await holder.register();
    await holder.heartbeat();
    state.branch = "HEAD";
    await holder.heartbeat();
    state.branch = "main";
    state.originHead = null; // no origin/HEAD: main and master count as default
    await holder.heartbeat();

    assert.equal(posts.length, 0);
  });

  test("a 409 is logged and not retried for that branch", async () => {
    const state = { branch: "fix/y", originHead: "refs/remotes/origin/master" };
    const { holder, posts, logs } = session(state, () => ({
      error: true,
      status: 409,
      body: { error: { code: "branch_held" } },
    }));

    await holder.register();
    await holder.heartbeat();
    await holder.heartbeat();

    assert.equal(posts.length, 1);
    assert.equal(logs.length, 1);
    assert.match(logs[0], /fix\/y.*branch_held/);
  });

  test("a new holder (after a lapse) opens its branch again, to take the item back", async () => {
    const posts = [];
    let holderId = "h-1";
    let gone = false;

    const apiCall = async (method, p, body) => {
      if (p === "/api/v1/holders") {
        return { holder: { id: holderId }, credential: { raw_key: "k-" + holderId }, heartbeat_seconds: 60 };
      }
      if (p.endsWith("/heartbeat")) return gone ? { error: true, status: 401 } : { lease_until: "l" };
      posts.push(body);
      return { outcome: "created" };
    };

    const opener = createBranchItemOpener({
      apiCall,
      git: stubGit({ branch: "fix/x", originHead: "refs/remotes/origin/master" }),
      worktree: () => "/wt",
      log: () => {},
    });

    const holder = createHolderSession({
      apiCall,
      env: { LOOPCTL_AGENT_KEY: "plain", CLAUDE_CODE_SESSION_ID: "s-1" },
      hostname: () => "minis",
      worktree: () => "/wt",
      randomUUID: () => "u",
      setInterval: () => null,
      clearInterval: () => {},
      afterBeat: (h, c) => opener.tick(h, c),
    });

    await holder.register();
    await holder.heartbeat();
    gone = true;
    holderId = "h-2";
    await holder.heartbeat();

    assert.equal(posts.length, 2);
  });

  test("a network error or a 5xx is retried on the next heartbeat", async () => {
    const state = { branch: "fix/z", originHead: "refs/remotes/origin/master" };
    let answers = [{ error: true, status: 0, body: "down" }, { error: true, status: 503 }, { ok: 1 }];
    const { holder, posts } = session(state, () => answers.shift());

    await holder.register();
    await holder.heartbeat();
    await holder.heartbeat();
    await holder.heartbeat();

    assert.equal(posts.length, 3);
    answers = [];
  });
});

describe("the wiring in index.js", () => {
  test("work_item_open is declared, dispatched to its handler, and has a README row", () => {
    assert.ok(INDEX_SRC.includes('name: "work_item_open"'));
    assert.match(INDEX_SRC, /case "work_item_open":\s*return await workItemOpenTool\(/);
    assert.ok(README.split("\n").some((line) => line.startsWith("| `work_item_open` |")));
  });

  test("the handler sends the session's own key", () => {
    const start = INDEX_SRC.indexOf("async function workItemOpenTool(");
    const end = INDEX_SRC.indexOf("\nasync function ", start + 1);
    const body = stripComments(INDEX_SRC.slice(start, end));

    assert.match(body, /openWorkItem\(/);
    assert.match(body, /agentKey\(\)/);
    assert.doesNotMatch(body, /LOOPCTL_(ORCH|USER)_KEY/);
  });

  test("the holder session runs the branch open after each beat", () => {
    assert.match(INDEX_SRC, /afterBeat: \(holder, credential\) => branchItemOpener\.tick\(holder, credential\)/);
  });
});
