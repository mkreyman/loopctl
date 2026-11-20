// Pure parts of the adapter: globs, path classification, package closure, report parsing.
import assert from "node:assert/strict";
import { test } from "node:test";
import { matches, segment } from "../lib/glob.mjs";
import { cover, fromPlaywright, fromVitest, lastJson } from "../lib/results.mjs";
import { classify, inPackages } from "../lib/select.mjs";
import { eslintFailures, slug, tscFailures } from "../lib/static.mjs";
import { owner, withDependents } from "../lib/workspace.mjs";

// core <- app <- web; util stands alone.
const pkgs = [
  { name: "@s/core", dir: "packages/core", deps: [] },
  { name: "@s/util", dir: "packages/util", deps: [] },
  { name: "@s/app", dir: "apps/app", deps: ["@s/core"] },
  { name: "@s/web", dir: "apps/web", deps: ["@s/app"] },
];

test("globs are anchored, ** spans segments, * and ? stay within one", () => {
  assert.ok(matches("pnpm-lock.yaml", "pnpm-lock.yaml"));
  assert.ok(!matches("pnpm-lock.yaml", "apps/x/pnpm-lock.yaml"));
  assert.ok(matches("**/vitest*.config.ts", "vitest.config.ts"));
  assert.ok(matches("**/vitest*.config.ts", "apps/web/vitest.remote.config.ts"));
  assert.ok(matches("docs/**", "docs/a/b.md"));
  assert.ok(!matches("apps/*/x", "apps/a/b/x"));
  assert.ok(segment("*.ex", "*x.ex"));
  assert.ok(segment("a?c", "abc"));
  assert.ok(!segment("a.c", "abc"));
});

test("the deepest package owns a path; none owns a root path", () => {
  assert.equal(owner(pkgs, "apps/app/src/x.ts").name, "@s/app");
  assert.equal(owner(pkgs, "apps/application/x.ts"), undefined);
  assert.equal(owner(pkgs, "scripts/x.ts"), undefined);
});

test("dependents are followed transitively, like pnpm --filter ...pkg", () => {
  const names = (ps) => ps.map((p) => p.name).sort();
  assert.deepEqual(names(withDependents(pkgs, [pkgs[0]])), ["@s/app", "@s/core", "@s/web"]);
  assert.deepEqual(names(withDependents(pkgs, [pkgs[1]])), ["@s/util"]);
  assert.deepEqual(withDependents(pkgs, []), []);
});

test("code goes to the module graph; deleted and non-code paths to their package", () => {
  const c = classify({
    paths: [
      "packages/core/src/a.ts",
      "packages/core/src/b.ts",
      "packages/util/data.sql",
      "README.md",
      "scripts/x.sh",
      "scripts/y.mjs",
      "tests-e2e/a.spec.ts",
    ],
    deleted: ["packages/core/src/b.ts"],
    ignore: ["**/*.md"],
    pkgs,
    e2eDir: "tests-e2e/",
  });
  assert.deepEqual(c.code, ["packages/core/src/a.ts", "tests-e2e/a.spec.ts"]);
  assert.deepEqual(c.blind, ["packages/core/src/b.ts", "packages/util/data.sql"]);
  assert.deepEqual(
    c.seeds.map((p) => p.name),
    ["@s/core", "@s/util"],
  );
  assert.deepEqual(c.ignored, ["README.md"]);
  assert.deepEqual(c.outside, ["scripts/x.sh", "scripts/y.mjs"]);
});

test("package test files are those under a package directory", () => {
  const files = ["packages/core/src/a.test.ts", "apps/app/x.test.ts", "apps/application/y.test.ts", "scripts/z.test.ts"];
  assert.deepEqual(inPackages(files, [pkgs[0], pkgs[2]]), ["packages/core/src/a.test.ts", "apps/app/x.test.ts"]);
});

test("a Vitest report becomes one result per test, and a file that failed to load an error", () => {
  const report = {
    testResults: [
      {
        name: "/r/packages/core/src/a.test.ts",
        status: "failed",
        assertionResults: [
          { fullName: "a adds", status: "passed", duration: 1.6 },
          { fullName: "a adds", status: "failed", duration: 2 },
          { fullName: "a later", status: "skipped" },
          { fullName: "a someday", status: "todo" },
        ],
      },
      { name: "/r/apps/app/b.test.ts", status: "failed", assertionResults: [], startTime: 10, endTime: 15 },
    ],
  };
  assert.deepEqual(fromVitest(report, "/r"), [
    { id: "packages/core/src/a.test.ts > a adds", status: "pass", ms: 2 },
    { id: "packages/core/src/a.test.ts > a adds #2", status: "fail", ms: 2 },
    { id: "packages/core/src/a.test.ts > a later", status: "skip", ms: 0 },
    { id: "packages/core/src/a.test.ts > a someday", status: "skip", ms: 0 },
    { id: "apps/app/b.test.ts", status: "error", ms: 5 },
  ]);
});

test("a Playwright report names tests by file, project and titles", () => {
  const report = {
    config: { rootDir: "/r/e2e" },
    suites: [
      {
        title: "a.spec.ts",
        file: "a.spec.ts",
        specs: [
          { title: "top", file: "a.spec.ts", tests: [{ projectName: "", status: "expected", results: [{ status: "passed", duration: 4 }] }] },
        ],
        suites: [
          {
            title: "group",
            specs: [
              {
                title: "inner",
                file: "a.spec.ts",
                tests: [
                  { projectName: "chromium", status: "unexpected", results: [{ status: "failed", duration: 3 }] },
                  { projectName: "webkit", status: "flaky", results: [{ status: "failed" }, { status: "passed", duration: 2 }] },
                  { projectName: "firefox", status: "skipped", results: [] },
                ],
              },
            ],
          },
        ],
      },
    ],
    errors: [{ location: { file: "/r/e2e/broken.spec.ts" } }],
  };
  assert.deepEqual(fromPlaywright(report, "/r"), [
    { id: "e2e/a.spec.ts > top", status: "pass", ms: 4 },
    { id: "e2e/a.spec.ts > [chromium] group inner", status: "fail", ms: 3 },
    { id: "e2e/a.spec.ts > [webkit] group inner", status: "pass", ms: 2 },
    { id: "e2e/a.spec.ts > [firefox] group inner", status: "skip", ms: 0 },
    { id: "e2e/broken.spec.ts", status: "error", ms: 0 },
  ]);
});

test("a listed path no runner reported is an error if its runner failed, else a skip", () => {
  const results = [{ id: "a.test.ts > x", status: "pass", ms: 1 }];
  const paths = [
    { path: "a.test.ts:3", runner: "vitest" },
    { path: "b.test.ts", runner: "vitest" },
    { path: "e2e/c.spec.ts", runner: "playwright" },
  ];
  assert.deepEqual(cover(results, paths, new Set(["playwright"])), [
    ...results,
    { id: "b.test.ts", status: "skip", ms: 0 },
    { id: "e2e/c.spec.ts", status: "error", ms: 0 },
  ]);
});

test("eslint errors fail, warnings do not, and unparsable output is one failure", () => {
  const out = JSON.stringify([
    {
      filePath: "/r/src/a.ts",
      messages: [
        { ruleId: "no-unused-vars", severity: 2, message: "x unused", line: 3 },
        { ruleId: "prefer-const", severity: 1, message: "warn", line: 4 },
        { fatal: true, severity: 2, message: "Parsing error", line: 9 },
      ],
    },
  ]);
  assert.deepEqual(eslintFailures(out, 1, "/r"), [
    { check: "eslint", file: "src/a.ts", line: 3, message: "no-unused-vars: x unused" },
    { check: "eslint", file: "src/a.ts", line: 9, message: "Parsing error" },
  ]);
  assert.deepEqual(eslintFailures("[]", 0, "/r"), []);
  assert.deepEqual(eslintFailures("Oops", 2, "/r"), [{ check: "eslint", message: "Oops" }]);
});

test("tsc diagnostics carry file, line and continuation lines", () => {
  const out = [
    "apps/app/src/x.ts(4,7): error TS2322: Type 'string' is not assignable to type 'number'.",
    "  The expected type comes from here.",
    "error TS5083: Cannot read file 'tsconfig.base.json'.",
  ].join("\n");
  assert.deepEqual(tscFailures(out, 2, "apps/app"), [
    {
      check: "tsc",
      file: "apps/app/src/x.ts",
      line: 4,
      message: "TS2322: Type 'string' is not assignable to type 'number'.\nThe expected type comes from here.",
    },
    { check: "tsc", message: "apps/app: TS5083: Cannot read file 'tsconfig.base.json'." },
  ]);
  assert.deepEqual(tscFailures("", 0, "x"), []);
  assert.deepEqual(tscFailures("killed", 137, "x"), [{ check: "tsc", message: "x: killed" }]);
  assert.equal(slug("apps/web"), "apps_web");
  assert.equal(slug("."), "root");
});

test("the last JSON document is found past log lines, bracketed ones included", () => {
  assert.deepEqual(lastJson('[vite] ready\n{"a":1}\n'), { a: 1 });
  assert.deepEqual(lastJson('[TanStack Router] Generated\n[\n  {\n    "file": "x"\n  }\n]\n'), [{ file: "x" }]);
  assert.throws(() => lastJson("[vite] ready\nno document"), /no JSON in/);
});
