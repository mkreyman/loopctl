// Drives every adapter command against a git copy of fixtures/sample, as a product repo
// would, and through `chg adapter exec` when CHG_BIN names a built chg. Needs node and
// pnpm (the fixture's lockfile installs from the registry, or the local store).
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { appendFileSync, cpSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, beforeEach, test } from "node:test";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ADAPTER = join(HERE, "..", "chg-adapter.mjs");
const FIXTURE = join(HERE, "..", "fixtures", "sample");
const CHG_BIN = process.env.CHG_BIN;
// The machine's git config stays out of the fixture repos, for this test's git calls and
// every git the adapter and chg run: a global core.hooksPath would run the developer's own
// hooks on the fixture's commits.
Object.assign(process.env, { GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" });
const roots = [];
let dir;

function git(...args) {
  return execFileSync("git", ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", ...args], {
    cwd: dir,
    encoding: "utf8",
  }).trim();
}

// Runs an adapter command; returns {doc, status}, the document being the last stdout line.
function adapter(...args) {
  const r = spawnSync("node", [ADAPTER, ...args], { cwd: dir, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  const line = r.stdout.trim().split("\n").at(-1);
  assert.ok(line, `no document from ${args.join(" ")}:\n${r.stderr}`);
  return { doc: JSON.parse(line), status: r.status };
}

const write = (path, text) => writeFileSync(join(dir, path), text);
const append = (path, text) => appendFileSync(join(dir, path), text);

beforeEach(() => {
  const root = mkdtempSync(join(tmpdir(), "chg-ts-it-"));
  roots.push(root);
  dir = join(root, "ws");
  cpSync(FIXTURE, dir, { recursive: true, filter: (src) => !src.includes("node_modules") });
  cpSync(join(HERE, "..", ".tool-versions"), join(dir, ".tool-versions"));
  git("init", "-q");
  git("add", ".chg", ".gitignore", ".tool-versions", "apps", "packages", "e2e", "package.json", "pnpm-lock.yaml",
    "pnpm-workspace.yaml", "tsconfig.json", "vitest.config.ts", "playwright.config.ts", "eslint.config.js");
  git("commit", "-qm", "fixture");
});

after(() => {
  for (const r of roots) rmSync(r, { recursive: true, force: true });
});

function snapshot() {
  const { doc, status } = adapter("snapshot");
  assert.equal(status, 0);
  return doc.work;
}

test("snapshot builds once, then does no work in under 10 s, and redoes it for a new commit", () => {
  assert.equal(snapshot(), "full");
  const started = Date.now();
  assert.equal(snapshot(), "none");
  assert.ok(Date.now() - started < 10_000);
  append("packages/core/src/money.ts", "\n");
  git("commit", "-qam", "money");
  assert.equal(snapshot(), "incremental");
  assert.equal(snapshot(), "none");
});

test("a module edit selects the tests importing it, in its package and its dependents', and their e2e", () => {
  snapshot();
  append("packages/core/src/money.ts", "export const x = 1;\n");
  const { doc } = adapter("affected", "--base", "HEAD", "--e2e-grep", "@smoke");
  assert.equal(doc.mode, "subset");
  assert.deepEqual(doc.tests, [
    "apps/app/src/total.test.ts",
    "e2e/smoke.spec.ts",
    "e2e/total.spec.ts",
    "packages/core/src/money.test.ts",
  ]);
});

test("a path the graph cannot see selects its package's and its dependents' tests", () => {
  snapshot();
  write("packages/core/src/rates.txt", "3\n");
  assert.deepEqual(adapter("affected", "--base", "HEAD").doc.tests, [
    "apps/app/src/banner.test.ts",
    "apps/app/src/total.test.ts",
    "packages/core/src/money.test.ts",
    "packages/core/src/rates.test.ts",
  ]);
  git("checkout", "-q", "packages/core/src/rates.txt");
  git("rm", "-q", "packages/util/src/strings.ts");
  assert.deepEqual(adapter("affected", "--base", "HEAD").doc.tests, ["packages/util/src/strings.test.ts"]);
});

test("a path chg names as read at run time selects everything", () => {
  snapshot();
  process.env.CHG_READ = "docs/a.md\ndocs/b.md";
  try {
    const { doc } = adapter("affected", "--base", "HEAD");
    assert.equal(doc.mode, "all");
    assert.match(doc.reason, /docs\/a\.md is read at run time/);
  } finally {
    delete process.env.CHG_READ;
  }
  assert.deepEqual(adapter("affected", "--base", "HEAD").doc.tests, []);
});

test("an unpackaged path, code included, selects everything unless ignored", () => {
  snapshot();
  write("notes.txt", "x\n");
  assert.equal(adapter("affected", "--base", "HEAD").doc.mode, "all");
  const { doc } = adapter("affected", "--base", "HEAD", "--ignore", "*.txt");
  assert.deepEqual([doc.mode, doc.tests], ["subset", []]);
  rmSync(join(dir, "notes.txt"));
  write("tool.mjs", "export const t = 1;\n");
  assert.match(adapter("affected", "--base", "HEAD").doc.reason, /tool\.mjs is outside every workspace package/);
});

test("an unknown option still answers with each command's document", () => {
  let r = adapter("affected", "--base", "HEAD", "--e2e-dirs", "x");
  assert.deepEqual([r.doc.mode, r.status], ["all", 0]);
  assert.match(r.doc.reason, /failed closed: .*e2e-dirs/);
  r = adapter("static", "--base", "HEAD", "--nope");
  assert.equal(r.status, 1);
  assert.deepEqual([r.doc.ok, r.doc.failures[0].check], [false, "adapter"]);
  r = adapter("run", "--nope");
  assert.deepEqual([r.doc.results, r.status], [[{ id: "adapter", status: "error", ms: 0 }], 1]);
});

test("an unknown base fails closed", () => {
  const { doc, status } = adapter("affected", "--base", "nope");
  assert.equal(status, 0);
  assert.equal(doc.mode, "all");
  assert.match(doc.reason, /failed closed: `nope` is not a commit/);
});

test("run reports each test, and exits 1 exactly when one failed or a path is missing", () => {
  snapshot();
  const list = join(dir, "..", "tests.txt");
  writeFileSync(list, "packages/util/src/strings.test.ts\ne2e/smoke.spec.ts\n");
  let r = adapter("run", "--tests", list);
  assert.equal(r.status, 0);
  assert.deepEqual(
    r.doc.results.map((x) => [x.id, x.status]).sort(),
    [
      ["e2e/smoke.spec.ts > the app answers @smoke", "pass"],
      ["packages/util/src/strings.test.ts > a skipped test", "skip"],
      ["packages/util/src/strings.test.ts > shout upper-cases", "pass"],
    ],
  );
  write("packages/util/src/strings.ts", "export function shout(s: string): string {\n  return s;\n}\n");
  r = adapter("run", "--tests", list);
  assert.equal(r.status, 1);
  assert.ok(r.doc.results.some((x) => x.id.endsWith("shout upper-cases") && x.status === "fail"));
  writeFileSync(list, "packages/nope.test.ts\n");
  r = adapter("run", "--tests", list);
  assert.equal(r.status, 1);
  assert.deepEqual(r.doc.results, [{ id: "packages/nope.test.ts", status: "error", ms: 0 }]);
  // Every test passes, then an unhandled rejection makes Vitest exit 1. The rejection is
  // created inside the test, so it is unhandled before the worker reports: a timer would
  // race the worker's teardown, and Vitest exits 0 when teardown wins (#66).
  write("packages/util/src/late.test.ts", 'import { test } from "vitest";\ntest("passes", () => { Promise.reject(new Error("late")); });\n');
  writeFileSync(list, "packages/util/src/late.test.ts\n");
  r = adapter("run", "--tests", list);
  assert.equal(r.status, 1);
  assert.ok(r.doc.results.some((x) => x.id === "vitest" && x.status === "error"), JSON.stringify(r.doc));
});

test("shards are disjoint and together cover the suite, e2e included", () => {
  snapshot();
  const ids = [1, 2, 3].flatMap((i) => {
    const { doc, status } = adapter("shard", "--of", "3", "--index", String(i), "--e2e");
    assert.equal(status, 0);
    return doc.results.map((r) => r.id);
  });
  assert.equal(new Set(ids).size, ids.length);
  assert.equal(ids.length, 8);
});

test("static passes a clean change and reports eslint, tsc and repo check failures", () => {
  snapshot();
  let r = adapter("static", "--base", "HEAD");
  assert.deepEqual([r.doc, r.status], [{ ok: true, failures: [] }, 0]);
  append("packages/util/src/strings.ts", 'export const y: number = "s";\nconst unused = 1;\n');
  r = adapter("static", "--base", "HEAD", "--check", 'base=echo "base $CHG_BASE" >&2; exit 3');
  assert.equal(r.status, 1);
  assert.ok(r.doc.failures.some((f) => f.check === "base" && f.message === `base ${git("rev-parse", "HEAD")}`));
  const checks = r.doc.failures.map((f) => [f.check, f.file ?? null]);
  assert.deepEqual(checks.sort(), [
    ["base", null],
    ["eslint", "packages/util/src/strings.ts"],
    ["tsc", "packages/util/src/strings.ts"],
  ]);
});

test("through chg: always_all paths select everything, a module edit a subset", { skip: !CHG_BIN && !process.env.CI }, () => {
  assert.ok(CHG_BIN, "CHG_BIN is unset in CI; build chg and point CHG_BIN at it");
  const chg = (...args) =>
    execFileSync(CHG_BIN, ["adapter", "exec", ...args, "--repo", dir], {
      encoding: "utf8",
      env: { ...process.env, CHG_TS_ADAPTER: ADAPTER },
      stdio: ["ignore", "pipe", "pipe"],
    });
  chg("snapshot");
  append("packages/core/src/money.ts", "\n");
  assert.equal(JSON.parse(chg("affected", "--base", "HEAD")).mode, "subset");
  append("apps/app/vitest.config.ts", "export default {};\n");
  assert.deepEqual(JSON.parse(chg("affected", "--base", "HEAD")), {
    mode: "all",
    reason: "apps/app/vitest.config.ts matches always_all `**/vitest*.config.ts`",
  });
  git("checkout", "-q", ".");
  rmSync(join(dir, "apps/app/vitest.config.ts"));
  append("pnpm-lock.yaml", "\n");
  assert.equal(JSON.parse(chg("affected", "--base", "HEAD")).reason, "pnpm-lock.yaml matches always_all `pnpm-lock.yaml`");
});
