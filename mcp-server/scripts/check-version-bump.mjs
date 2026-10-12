// Fails when a PR changes what npm ships for loopctl-mcp-server without a version that
// mcp-autopublish.yml would publish. Run by mcp-server-ci.yml's version-bump job.
//
//   node mcp-server/scripts/check-version-bump.mjs [BASE] [HEAD]
//
// BASE defaults to HEAD^1 and HEAD to HEAD. On `pull_request`, actions/checkout puts
// GitHub's merge commit at HEAD, and its first parent is master as GitHub merged against it.
// That pair's diff is exactly what this PR adds to master. The event's
// `pull_request.base.sha` is NOT that parent: it is recorded when the PR is opened or its base
// edited, so it lags master, and a master bump between the two made an unbumped branch read
// as "bumped" (#969).
//
// "What npm ships" is npm's own answer (`npm pack --dry-run`) for each side, never a model of
// `files`: globs, negations, a missing `files` field and npm's always-included files are all
// npm's to decide.

import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const PKG_DIR = "mcp-server";

// package.json fields that change what an install gets or resolves. Scripts, devDependencies
// and descriptive fields do not. `files` is absent on purpose: its effect is the shipped set,
// which is compared directly.
export const RUNTIME_FIELDS = [
  "name",
  "main",
  "bin",
  "exports",
  "imports",
  "type",
  "engines",
  "os",
  "cpu",
  "dependencies",
  "peerDependencies",
  "peerDependenciesMeta",
  "optionalDependencies",
  "bundleDependencies",
  "bundledDependencies",
  "publishConfig"
];

const SEMVER = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/;

function parseSemver(version) {
  const m = SEMVER.exec(version ?? "");
  if (!m) throw new Error(`not a semver version: ${JSON.stringify(version)}`);
  return { core: m.slice(1, 4).map(Number), pre: m[4] ? m[4].split(".") : [] };
}

// Semver 2.0.0 precedence: negative when a < b, 0 when equal, positive when a > b.
export function compareSemver(a, b) {
  const [x, y] = [parseSemver(a), parseSemver(b)];
  for (let i = 0; i < 3; i++) if (x.core[i] !== y.core[i]) return x.core[i] - y.core[i];
  // A release outranks any prerelease of the same core.
  if (x.pre.length === 0 || y.pre.length === 0) return y.pre.length - x.pre.length;
  for (let i = 0; i < Math.max(x.pre.length, y.pre.length); i++) {
    const [p, q] = [x.pre[i], y.pre[i]];
    if (p === undefined) return -1;
    if (q === undefined) return 1;
    if (p === q) continue;
    const [np, nq] = [/^\d+$/.test(p), /^\d+$/.test(q)];
    if (np && nq) return Number(p) - Number(q);
    if (np !== nq) return np ? -1 : 1;
    return p < q ? -1 : 1;
  }
  return 0;
}

// Key order is not meaning: `npm install` re-sorts dependencies.
function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") {
    const keys = Object.keys(value).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(",")}}`;
  }
  return JSON.stringify(value ?? null);
}

export function movedRuntimeFields(basePkg, headPkg) {
  return RUNTIME_FIELDS.filter((k) => canonical(basePkg[k]) !== canonical(headPkg[k]));
}

// Shipped paths whose presence or content differs. `changed` is the diff's path list relative
// to the package dir; package.json is judged by its runtime fields instead.
export function shippedChanges(baseShipped, headShipped, changed) {
  const out = new Set();
  for (const p of headShipped) if (!baseShipped.has(p)) out.add(`${p} (now shipped)`);
  for (const p of baseShipped) if (!headShipped.has(p)) out.add(`${p} (no longer shipped)`);
  for (const p of changed) {
    if (p !== "package.json" && (baseShipped.has(p) || headShipped.has(p))) out.add(p);
  }
  return [...out].sort();
}

const git = (...args) => execFileSync("git", args, { encoding: "utf8" });

function shippedAt(ref, scratch) {
  const dir = mkdtempSync(join(scratch, "side-"));
  const tar = join(dir, "tree.tar");
  git("archive", "--output", tar, ref, PKG_DIR);
  execFileSync("tar", ["-xf", tar, "-C", dir]);
  const out = execFileSync("npm", ["pack", "--dry-run", "--json", "--ignore-scripts"], {
    cwd: join(dir, PKG_DIR),
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"]
  });
  return new Set(JSON.parse(out)[0].files.map((f) => f.path));
}

// Mirrors mcp-autopublish.yml's gate: a version npm already has is never published again.
function onNpm(name, version) {
  try {
    execFileSync("npm", ["view", `${name}@${version}`, "version"], { stdio: "pipe" });
    return true;
  } catch (err) {
    if (String(err.stderr).includes("E404")) return false;
    throw new Error(`npm view ${name}@${version} failed for a reason other than 404:\n${err.stderr}`);
  }
}

function main([base = "HEAD^1", head = "HEAD"]) {
  const pkgAt = (ref) => JSON.parse(git("show", `${ref}:${PKG_DIR}/package.json`));
  const [basePkg, headPkg] = [pkgAt(base), pkgAt(head)];

  const scratch = mkdtempSync(join(tmpdir(), "mcp-bump-"));
  let shipped;
  try {
    shipped = [shippedAt(base, scratch), shippedAt(head, scratch)];
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }

  const changed = git("diff", "--no-renames", "--name-only", "-z", base, head, "--", PKG_DIR)
    .split("\0")
    .filter(Boolean)
    .map((p) => p.slice(PKG_DIR.length + 1));

  const moved = movedRuntimeFields(basePkg, headPkg);
  const changes = shippedChanges(shipped[0], shipped[1], changed);
  if (moved.length) changes.push(`package.json (${moved.join(", ")})`);

  console.log(`Comparing ${git("rev-parse", "--short", base).trim()} -> ${git("rev-parse", "--short", head).trim()}`);
  if (changes.length === 0) {
    console.log("No published mcp-server file changed; no bump required.");
    return 0;
  }

  console.log(`Published files changed in this PR:\n  ${changes.join("\n  ")}`);
  console.log(`version: base=${basePkg.version} head=${headPkg.version}`);

  // HIGHER than master's: a lower version that npm lacks WOULD publish, and would move the
  // `latest` dist-tag backwards.
  if (compareSemver(headPkg.version, basePkg.version) <= 0) {
    console.log(
      `::error::mcp-server published files changed but the version did not rise above master's ${basePkg.version} (head: ${headPkg.version}). Nothing publishes to npm without a new version, so agents keep the OLD tool descriptions while the server serves the new payload. Bump mcp-server/package.json above ${basePkg.version}.`
    );
    return 1;
  }

  // NOT already on npm: autopublish skips a version npm has, e.g. one pushed by hand through
  // npm-publish.yml's tag path, and the change would never ship.
  if (onNpm(headPkg.name, headPkg.version)) {
    console.log(
      `::error::${headPkg.name}@${headPkg.version} is already on npm, so mcp-autopublish.yml will skip it and this change never ships. Bump to a version npm does not have.`
    );
    return 1;
  }

  console.log(`Version bumped ${basePkg.version} -> ${headPkg.version}.`);
  return 0;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = main(process.argv.slice(2));
}
