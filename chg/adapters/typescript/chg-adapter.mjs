#!/usr/bin/env node
// The chg adapter (contract v1, docs/adapter-contract.md) for a pnpm workspace tested
// with Vitest and Playwright. Run from the repo root by `chg adapter exec`:
//
//   node chg-adapter.mjs snapshot [--build <filter>] [--generate <sh>]... [--browsers <names>] [--tsconfig <path>]...
//   node chg-adapter.mjs affected --base <sha> [--ignore <glob>]... [--e2e-dir <dir>] [--e2e-grep <re>] [--apps <glob>]...
//   node chg-adapter.mjs static   --base <sha> [--ignore <glob>]... [--generate <sh>]... [--tsconfig <path>]... [--check <name>=<sh>]...
//   node chg-adapter.mjs run      --tests <list file> [--e2e-dir <dir>]
//   node chg-adapter.mjs shard    --of <n> --index <i> [--e2e] [--e2e-dir <dir>]
//
// Each prints one JSON document as its last stdout line; everything else goes to stderr.
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";
import * as git from "./lib/git.mjs";
import { any } from "./lib/glob.mjs";
import { capture, shell, stream, tail } from "./lib/proc.mjs";
import { cover, fromPlaywright, fromVitest, lastJson } from "./lib/results.mjs";
import { classify, inPackages, CODE } from "./lib/select.mjs";
import { eslintFailures, slug, tscFailures } from "./lib/static.mjs";
import { owner, packages, withDependents } from "./lib/workspace.mjs";

export const VERSION = "1";
const ROOT = process.cwd();
const MARKER = "node_modules/.chg/snapshot.json";
const TSC_CACHE = "node_modules/.cache/chg/tsc";
const PLAYWRIGHT_CONFIGS = ["ts", "mts", "js", "mjs", "cjs"].map((e) => `playwright.config.${e}`);

const OPTIONS = {
  base: { type: "string" },
  ignore: { type: "string", multiple: true, default: [] },
  generate: { type: "string", multiple: true, default: [] },
  tsconfig: { type: "string", multiple: true, default: [] },
  check: { type: "string", multiple: true, default: [] },
  build: { type: "string", default: "./packages/*" },
  browsers: { type: "string" },
  tests: { type: "string" },
  of: { type: "string" },
  index: { type: "string" },
  e2e: { type: "boolean", default: false },
  "e2e-dir": { type: "string", default: "e2e" },
  "e2e-grep": { type: "string" },
  apps: { type: "string", multiple: true, default: ["apps/*"] },
};

const emit = (doc) => process.stdout.write(JSON.stringify(doc) + "\n");
const log = (msg) => process.stderr.write(`chg: ${msg}\n`);
const pnpmExec = (args, opts) => capture("pnpm", ["exec", ...args], { cwd: ROOT, ...opts });

function need(opts, key, command) {
  if (opts[key] === undefined) throw new Error(`${command} needs --${key}`);
  return opts[key];
}

// ---------------------------------------------------------------- snapshot

async function snapshot(opts) {
  const started = Date.now();
  const key = {
    adapter: VERSION,
    // A snapshot build runs in a plain tree with no .git; chg names its commit.
    head: process.env.CHG_SHA || git.head(),
    lockfile: sha256(readFileSync(join(ROOT, "pnpm-lock.yaml"))),
    node: process.version,
    pnpm: (await capture("pnpm", ["--version"], { echo: false })).out.trim(),
    options: [opts.build, opts.browsers ?? "", ...opts.generate, ...opts.tsconfig],
  };
  const marker = join(ROOT, MARKER);
  if (existsSync(marker) && JSON.stringify(JSON.parse(readFileSync(marker, "utf8"))) === JSON.stringify(key)) {
    return emit({ work: "none", ms: Date.now() - started });
  }
  const work = existsSync(join(ROOT, "node_modules")) ? "incremental" : "full";

  // The product's own pnpm settings, never an override: pnpm checks an install against
  // the settings of whatever command runs next, and a bare `pnpm exec` reinstalls a
  // workspace installed under different ones (design §3.5).
  await step("pnpm", ["install", "--frozen-lockfile"]);
  if (opts.build !== "none") await step("pnpm", ["--filter", opts.build, "run", "--if-present", "build"]);
  for (const line of opts.generate) await step("sh", ["-c", line]);
  if (opts.browsers) await step("pnpm", ["exec", "playwright", "install", ...opts.browsers.split(/[\s,]+/)]);

  // Warm every project's .tsbuildinfo so `static` typechecks incrementally. A type error
  // at this revision is reported, not fatal: the cache is what the snapshot is for.
  const failures = await typecheck(opts);
  if (failures.length) log(`${failures.length} type error(s) at ${key.head.slice(0, 9)}; the cache is warm regardless`);

  mkdirSync(join(ROOT, "node_modules/.chg"), { recursive: true });
  writeFileSync(`${marker}.tmp`, JSON.stringify(key));
  renameSync(`${marker}.tmp`, marker);
  emit({ work, ms: Date.now() - started });
}

async function step(cmd, args) {
  log([cmd, ...args].join(" "));
  const status = await stream(cmd, args, { cwd: ROOT });
  if (status !== 0) throw new Error(`${cmd} ${args.join(" ")} exited ${status}`);
}

const sha256 = (data) => createHash("sha256").update(data).digest("hex");

// ---------------------------------------------------------------- affected

async function affected(opts) {
  const base = need(opts, "base", "affected");
  const { sha, paths, deleted } = git.changed(base);
  const pkgs = await packages(ROOT);
  const c = classify({ paths, deleted, ignore: opts.ignore, pkgs, e2eDir: opts["e2e-dir"] });

  if (c.outside.length) {
    return emit({
      mode: "all",
      reason: `${c.outside[0]} is outside every workspace package and the e2e directory`,
    });
  }

  const tests = new Set();
  let graph = 0;
  if (c.code.length) {
    // Vitest follows imports transitively from every test file to the changed modules.
    for (const f of await vitestList(["--changed", sha])) tests.add(f);
    graph = tests.size;
  }
  const closure = withDependents(pkgs, c.seeds);
  if (closure.length) for (const f of inPackages(await vitestList([]), closure)) tests.add(f);

  let e2e = 0;
  if (playwrightConfig()) {
    const specs = new Set();
    if (c.code.length) for (const f of await playwrightList([`--only-changed=${sha}`])) specs.add(f);
    // An app that changed, or depends on a package that did, runs its e2e subset.
    const touched = withDependents(pkgs, [...new Set([...c.code, ...c.blind].map((p) => owner(pkgs, p)).filter(Boolean))]);
    if (opts["e2e-grep"] && touched.some((p) => any(opts.apps, p.dir))) {
      for (const f of await playwrightList(["--grep", opts["e2e-grep"]])) specs.add(f);
    }
    for (const f of specs) tests.add(f);
    e2e = specs.size;
  }

  const list = [...tests].sort();
  emit({
    mode: "subset",
    reason:
      `${paths.length} changed path(s), ${c.ignored.length} ignored: ` +
      `${c.code.length} module(s) selecting ${graph} test file(s) through the import graph, ` +
      `${c.blind.length} path(s) the graph cannot see selecting ${closure.length} package(s) with dependents, ` +
      `${e2e} e2e spec(s)`,
    tests: list,
  });
}

async function vitestList(args) {
  const { status, out } = await pnpmExec(["vitest", "list", ...args, "--filesOnly", "--json"], { echo: false });
  if (status !== 0) throw new Error(`vitest list exited ${status}: ${tail(out, 5)}`);
  return lastJson(out).map((t) => rel(t.file));
}

function playwrightConfig() {
  return PLAYWRIGHT_CONFIGS.find((f) => existsSync(join(ROOT, f)));
}

async function playwrightList(args) {
  const { status, out } = await pnpmExec(["playwright", "test", "--list", "--reporter=json", ...args], { echo: false });
  if (status !== 0) throw new Error(`playwright test --list exited ${status}: ${tail(out, 5)}`);
  return [...new Set(fromPlaywright(lastJson(out), ROOT).map((r) => r.id.split(" > ")[0]))];
}

const rel = (abs) => (abs.startsWith(ROOT + "/") ? abs.slice(ROOT.length + 1) : abs);

// ---------------------------------------------------------------- static

async function staticChecks(opts) {
  const base = need(opts, "base", "static");
  const { sha, paths, deleted } = git.changed(base);
  const gone = new Set(deleted);
  const lintable = paths.filter((p) => !gone.has(p) && !any(opts.ignore, p) && CODE.has(extOf(p)));

  for (const line of opts.generate) {
    const { status, out } = await shell(line, { cwd: ROOT });
    if (status !== 0) return finishStatic([{ check: "generate", message: `${line}: ${tail(out) || `exited ${status}`}` }]);
  }

  const results = await Promise.all([
    eslint(lintable),
    typecheck(opts),
    ...opts.check.map((spec) => check(spec, sha)),
  ]);
  finishStatic(results.flat());
}

function finishStatic(failures) {
  emit({ ok: failures.length === 0, failures });
  process.exitCode = failures.length ? 1 : 0;
}

const extOf = (p) => (p.lastIndexOf(".") > p.lastIndexOf("/") ? p.slice(p.lastIndexOf(".")) : "");

async function eslint(files) {
  if (files.length === 0) return [];
  const { status, out } = await pnpmExec(["eslint", "--format", "json", "--no-warn-ignored", ...files], { echo: false });
  return eslintFailures(out, status, ROOT);
}

// Every workspace package with a tsconfig.json, plus each --tsconfig, typechecked with
// --incremental against a .tsbuildinfo kept under node_modules (cloned with it). The repo
// need not use project references, so this is per project rather than `tsc -b`.
async function typecheck(opts) {
  const pkgs = await packages(ROOT);
  const projects = [
    ...pkgs.filter((p) => existsSync(join(ROOT, p.dir, "tsconfig.json"))).map((p) => p.dir),
    ...opts.tsconfig,
  ];
  mkdirSync(join(ROOT, TSC_CACHE), { recursive: true });
  const run = async (project) => {
    const info = join(TSC_CACHE, `${slug(project)}.tsbuildinfo`);
    const { status, out } = await pnpmExec(
      ["tsc", "--noEmit", "--incremental", "--tsBuildInfoFile", info, "--pretty", "false", "-p", project],
      { echo: false },
    );
    return tscFailures(out, status, project);
  };
  return (await pool(projects, run, 4)).flat();
}

async function pool(items, fn, width) {
  const out = new Array(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const i = next++;
      out[i] = await fn(items[i]);
    }
  };
  await Promise.all(Array.from({ length: Math.min(width, items.length) }, worker));
  return out;
}

// --check name=<sh>: a repo's own check, run with CHG_BASE and CHG_HEAD in its
// environment; a non-zero exit is one failure carrying the tail of its stdout and stderr.
async function check(spec, base) {
  const at = spec.indexOf("=");
  if (at < 1) return [{ check: "adapter", message: `--check must be name=<command>, got ${spec}` }];
  const [name, line] = [spec.slice(0, at), spec.slice(at + 1)];
  const { status, out } = await shell(line, { cwd: ROOT, env: { CHG_BASE: base, CHG_HEAD: git.head() } });
  return status === 0 ? [] : [{ check: name, message: tail(out) || `exited ${status}` }];
}

// ---------------------------------------------------------------- run, shard

async function run(opts) {
  const listFile = need(opts, "tests", "run");
  const entries = readFileSync(listFile, "utf8")
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean);
  const e2eDir = opts["e2e-dir"].replace(/\/$/, "") + "/";
  const missing = entries.filter((e) => !existsSync(join(ROOT, e.replace(/:\d+$/, ""))));
  const present = entries.filter((e) => !missing.includes(e));
  const wanted = present.map((path) => ({ path, runner: path.startsWith(e2eDir) ? "playwright" : "vitest" }));

  const failed = new Set();
  let results = [];
  const unit = wanted.filter((w) => w.runner === "vitest").map((w) => w.path);
  const e2e = wanted.filter((w) => w.runner === "playwright").map((w) => w.path);
  if (unit.length) results.push(...(await vitestRun(unit, failed)));
  if (e2e.length) results.push(...(await playwrightRun(e2e, failed)));

  results = cover(results, wanted, failed);
  results.push(...missing.map((id) => ({ id, status: "error", ms: 0 })));
  if (results.length === 0) results.push({ id: "(no tests)", status: "skip", ms: 0 });
  finishRun(results, failed);
}

async function shard(opts) {
  const n = Number(need(opts, "of", "shard"));
  const i = Number(need(opts, "index", "shard"));
  if (!(Number.isInteger(n) && Number.isInteger(i) && i >= 1 && i <= n)) throw new Error(`bad shard ${i}/${n}`);
  const failed = new Set();
  const results = await vitestRun([`--shard=${i}/${n}`], failed);
  if (opts.e2e && playwrightConfig()) results.push(...(await playwrightRun([`--shard=${i}/${n}`], failed)));
  finishRun(results, failed);
}

// A runner that exited non-zero while every test it reported passed (an unhandled error
// after a test, a config error, a teardown failure) is one error result, never a pass.
function finishRun(results, failed) {
  if (failed.size && !results.some(bad)) for (const r of failed) results.push({ id: r, status: "error", ms: 0 });
  emit({ results });
  process.exitCode = results.some(bad) ? 1 : 0;
}

const bad = (r) => r.status === "fail" || r.status === "error";

async function withReport(fn) {
  const dir = mkdtempSync(join(tmpdir(), "chg-ts-"));
  try {
    return await fn(join(dir, "report.json"));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function vitestRun(args, failed) {
  return withReport(async (file) => {
    const status = await stream(
      "pnpm",
      ["exec", "vitest", "run", "--reporter=dot", "--reporter=json", `--outputFile.json=${file}`, "--passWithNoTests", ...args],
      { cwd: ROOT },
    );
    if (status !== 0) failed.add("vitest");
    return existsSync(file) ? fromVitest(JSON.parse(readFileSync(file, "utf8")), ROOT) : [];
  });
}

function playwrightRun(args, failed) {
  return withReport(async (file) => {
    const status = await stream("pnpm", ["exec", "playwright", "test", "--reporter=list,json", ...args], {
      cwd: ROOT,
      env: { PLAYWRIGHT_JSON_OUTPUT_FILE: file, PLAYWRIGHT_JSON_OUTPUT_NAME: file },
    });
    if (status !== 0) failed.add("playwright");
    return existsSync(file) ? fromPlaywright(JSON.parse(readFileSync(file, "utf8")), ROOT) : [];
  });
}

// ---------------------------------------------------------------- main

const COMMANDS = { snapshot, affected, static: staticChecks, run, shard };

async function main() {
  const [command, ...rest] = process.argv.slice(2);
  const fn = COMMANDS[command];
  if (!fn) {
    process.stderr.write(`usage: chg-adapter.mjs ${Object.keys(COMMANDS).join("|")} [options]\n`);
    process.exit(2);
  }
  try {
    const { values } = parseArgs({ args: rest, options: OPTIONS, strict: true, allowPositionals: false });
    await fn(values);
  } catch (e) {
    log(e.message);
    failure(command, e.message);
  }
}

// The document for a command that threw, so chg reads a failure rather than a broken
// contract. `affected` fails closed and exits 0; snapshot has no failure document.
function failure(command, message) {
  if (command === "affected") return emit({ mode: "all", reason: `failed closed: ${message}` });
  if (command === "static") emit({ ok: false, failures: [{ check: "adapter", message }] });
  if (command === "run" || command === "shard") emit({ results: [{ id: "adapter", status: "error", ms: 0 }] });
  process.exitCode = 1;
}

await main();
