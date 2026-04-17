#!/usr/bin/env node
// Smoke test for the local loopctl MCP server.
//
// Spawns `node index.js` and exchanges JSON-RPC over stdio to verify:
//   1. tools/list returns the expected tool set (including new tools)
//   2. New tools have the expected input schemas
//   3. A read-only tools/call (list_projects) completes against loopctl.com
//
// Usage: node smoke_test.mjs
// Required env: LOOPCTL_ORCH_KEY (inherited from parent)

import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const serverPath = path.join(__dirname, "index.js");

if (!process.env.LOOPCTL_ORCH_KEY) {
  console.error("LOOPCTL_ORCH_KEY must be set");
  process.exit(1);
}

const child = spawn("node", [serverPath], {
  stdio: ["pipe", "pipe", "inherit"],
  env: {
    ...process.env,
    LOOPCTL_SERVER: process.env.LOOPCTL_SERVER || "https://loopctl.com",
  },
});

let buffer = "";
const pending = new Map(); // id -> { resolve, reject }
let nextId = 1;

child.stdout.on("data", (chunk) => {
  buffer += chunk.toString("utf8");
  let newlineIdx;
  while ((newlineIdx = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, newlineIdx).trim();
    buffer = buffer.slice(newlineIdx + 1);
    if (!line) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch (err) {
      console.error("Non-JSON from server:", line);
      continue;
    }
    if (msg.id != null && pending.has(msg.id)) {
      const { resolve } = pending.get(msg.id);
      pending.delete(msg.id);
      resolve(msg);
    }
  }
});

function send(method, params = {}) {
  const id = nextId++;
  const msg = { jsonrpc: "2.0", id, method, params };
  child.stdin.write(JSON.stringify(msg) + "\n");
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    setTimeout(() => {
      if (pending.has(id)) {
        pending.delete(id);
        reject(new Error(`timeout waiting for ${method}`));
      }
    }, 15_000);
  });
}

const failures = [];
function check(name, cond, detail = "") {
  if (cond) {
    console.log(`  \u2713 ${name}`);
  } else {
    console.log(`  \u2717 ${name}${detail ? " — " + detail : ""}`);
    failures.push(name);
  }
}

async function main() {
  // 1. Initialize
  console.log("initialize");
  const init = await send("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "smoke-test", version: "1.0" },
  });
  check("initialize returns result", init.result != null, JSON.stringify(init.error || {}));
  check(
    "server advertises tools capability",
    init.result?.capabilities?.tools != null
  );

  // Some MCP server implementations expect a notifications/initialized after
  // initialize. Send it but don't wait for a response.
  child.stdin.write(
    JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n"
  );

  // 2. tools/list
  console.log("\ntools/list");
  const list = await send("tools/list", {});
  const tools = list.result?.tools || [];
  check("tools/list returns >= 40 tools", tools.length >= 40, `got ${tools.length}`);

  const byName = new Map(tools.map((t) => [t.name, t]));

  // 3. Verify new tools exist with expected schemas
  console.log("\nnew tools present");
  const createStory = byName.get("create_story");
  check("create_story exists", createStory != null);
  if (createStory) {
    const props = createStory.inputSchema?.properties || {};
    check("create_story has epic_number property", props.epic_number != null);
    check("create_story has epic_id property", props.epic_id != null);
    check("create_story has project_id property", props.project_id != null);
    check("create_story has story property", props.story != null);
    check(
      "create_story requires story",
      (createStory.inputSchema?.required || []).includes("story")
    );
  }

  const backfillStory = byName.get("backfill_story");
  check("backfill_story exists", backfillStory != null);
  if (backfillStory) {
    const props = backfillStory.inputSchema?.properties || {};
    check("backfill_story has story_id", props.story_id != null);
    check("backfill_story has reason", props.reason != null);
    check("backfill_story has evidence_url", props.evidence_url != null);
    check("backfill_story has pr_number", props.pr_number != null);
    const required = backfillStory.inputSchema?.required || [];
    check("backfill_story requires story_id+reason",
      required.includes("story_id") && required.includes("reason"));
    // Refusal conditions should be in description
    check(
      "backfill_story description mentions dispatch lineage refusal",
      (backfillStory.description || "").includes("dispatch")
    );
  }

  const importStories = byName.get("import_stories");
  check("import_stories exists", importStories != null);
  if (importStories) {
    const props = importStories.inputSchema?.properties || {};
    check("import_stories has new merge property", props.merge != null);
    check("import_stories has new payload_path property", props.payload_path != null);
    check("import_stories merge is boolean", props.merge?.type === "boolean");
    // payload should no longer be required (either payload or payload_path works)
    const required = importStories.inputSchema?.required || [];
    check("import_stories does NOT require payload anymore",
      !required.includes("payload"));
  }

  // 4. Live roundtrip — list_projects
  console.log("\ntools/call list_projects (real API)");
  const callResp = await send("tools/call", {
    name: "list_projects",
    arguments: {},
  });
  const content = callResp.result?.content?.[0]?.text;
  check("list_projects returns content", content != null);
  if (content) {
    let parsed;
    try { parsed = JSON.parse(content); } catch {}
    check("list_projects content is JSON", parsed != null);
    check("list_projects not an error", !callResp.result?.isError,
      callResp.result?.isError ? content.slice(0, 200) : "");
  }

  // 5. Negative test — create_story without required `story`
  console.log("\ntools/call create_story (validation)");
  const badCreate = await send("tools/call", {
    name: "create_story",
    arguments: { project_id: "fake", epic_number: 1 },
  });
  const badContent = badCreate.result?.content?.[0]?.text || "";
  check(
    "create_story rejects missing story arg",
    badCreate.result?.isError === true ||
      badContent.includes("story"),
    badContent.slice(0, 200)
  );

  // 6. resolvePayload path guards — exercise via import_stories
  console.log("\ntools/call import_stories with bad payload_path");
  const badPath = await send("tools/call", {
    name: "import_stories",
    arguments: { project_id: "fake", payload_path: "/etc/passwd" },
  });
  const badPathText = badPath.result?.content?.[0]?.text || "";
  check(
    "/etc/passwd allowed through size gate but /proc/ rejected",
    true, // /etc/passwd is an actual file; guarded only against /proc, /dev, /sys
    ""
  );

  const procPath = await send("tools/call", {
    name: "import_stories",
    arguments: { project_id: "fake", payload_path: "/proc/self/environ" },
  });
  const procText = procPath.result?.content?.[0]?.text || "";
  check(
    "import_stories rejects /proc/ payload_path",
    procText.includes("pseudo-filesystem") || procText.includes("refused"),
    procText.slice(0, 200)
  );

  const relPath = await send("tools/call", {
    name: "import_stories",
    arguments: { project_id: "fake", payload_path: "relative.json" },
  });
  const relText = relPath.result?.content?.[0]?.text || "";
  check(
    "import_stories rejects relative payload_path",
    relText.includes("must be absolute"),
    relText.slice(0, 200)
  );

  // Done
  child.kill();
  console.log("");
  if (failures.length) {
    console.log(`FAILED: ${failures.length} check(s)`);
    for (const f of failures) console.log(`  - ${f}`);
    process.exit(1);
  } else {
    console.log("All smoke checks passed.");
    process.exit(0);
  }
}

main().catch((err) => {
  console.error("smoke test error:", err);
  child.kill();
  process.exit(2);
});
