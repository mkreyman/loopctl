import { test } from "node:test";
import assert from "node:assert/strict";
import {
  compareSemver,
  movedRuntimeFields,
  shippedChanges
} from "../scripts/check-version-bump.mjs";

test("compareSemver orders by semver precedence, not by the base's segments", () => {
  assert.ok(compareSemver("2.115.0", "2.114.9") > 0);
  assert.ok(compareSemver("2.114.0", "2.114.0") === 0);
  assert.ok(compareSemver("2.10.0", "2.9.0") > 0);
  // A release outranks its own prerelease.
  assert.ok(compareSemver("2.115.0", "2.115.0-rc.1") > 0);
  assert.ok(compareSemver("2.115.0-rc.2", "2.115.0-rc.1") > 0);
  assert.ok(compareSemver("2.115.0-rc.10", "2.115.0-rc.9") > 0);
  assert.ok(compareSemver("2.115.0-rc", "2.115.0-rc.1") < 0);
  assert.ok(compareSemver("2.115.0-1", "2.115.0-alpha") < 0);
  assert.ok(compareSemver("2.115.0+build.7", "2.115.0") === 0);
  assert.throws(() => compareSemver("2.114", "2.114.1"), /not a semver version/);
});

test("movedRuntimeFields ignores key order and non-runtime fields", () => {
  const base = { dependencies: { a: "1", b: "2" }, scripts: { test: "x" }, version: "1.0.0" };
  const reordered = { dependencies: { b: "2", a: "1" }, scripts: { test: "y" }, version: "1.0.1" };
  assert.deepEqual(movedRuntimeFields(base, reordered), []);

  const peer = { ...base, peerDependencies: { c: "3" }, publishConfig: { tag: "next" } };
  assert.deepEqual(movedRuntimeFields(base, peer), ["peerDependencies", "publishConfig"]);
});

test("shippedChanges counts content edits, additions and deletions of shipped paths", () => {
  const base = new Set(["index.js", "lib/a.js", "lib/gone.js", "package.json"]);
  const head = new Set(["index.js", "lib/a.js", "lib/new.js", "package.json"]);
  const changed = ["index.js", "lib/gone.js", "lib/new.js", "test/x.test.js", "package.json"];

  assert.deepEqual(shippedChanges(base, head, changed), [
    "index.js",
    "lib/gone.js",
    "lib/gone.js (no longer shipped)",
    "lib/new.js",
    "lib/new.js (now shipped)"
  ]);
});

test("shippedChanges sees a file that starts shipping with no content change", () => {
  const base = new Set(["index.js", "package.json"]);
  const head = new Set(["index.js", "package.json", "smoke_test.mjs"]);
  assert.deepEqual(shippedChanges(base, head, []), ["smoke_test.mjs (now shipped)"]);
});

test("shippedChanges is empty for test-only edits", () => {
  const shipped = new Set(["index.js", "package.json"]);
  assert.deepEqual(shippedChanges(shipped, shipped, ["test/x.test.js", "package.json"]), []);
});
