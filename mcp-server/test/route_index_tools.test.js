/**
 * A `GET /api/v1/routes` row that says "MCP tool: <name>" must name a tool that SENDS that row's
 * route (loopctl #878, US-44.7 review round 2).
 *
 * The route index (`LoopctlWeb.RouteDiscoveryController.curated_routes/0`) is what a session
 * reads "before probing blindly", and a row naming a tool is an instruction: call this. A tool
 * that exists but sends something else sends the session to the wrong endpoint with the index's
 * authority behind it. The Elixir test could only check that the named tool was DECLARED; the
 * call sites live here, so the binding does too.
 *
 * Rows are parsed from the controller source rather than fetched, so this runs with no server.
 * "MCP tool: none" rows are the Elixir side's job — it binds them to DECLARED's gaps in
 * `route_coverage.test.js`.
 *
 * Run: node --test test/*.test.js
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

import { PKG_DIR, normalisePath, toolRoutes } from "./tool-surface.js";

const CONTROLLER = path.join(
  PKG_DIR,
  "..",
  "lib",
  "loopctl_web",
  "controllers",
  "route_discovery_controller.ex",
);

const ROW =
  /%\{\s*method:\s*"([A-Z]+)",\s*path:\s*"([^"]+)",\s*description:\s*((?:"(?:[^"\\]|\\.)*"\s*(?:<>\s*)?)+)\}/g;

function indexRows() {
  const src = readFileSync(CONTROLLER, "utf8");
  return [...src.matchAll(ROW)].map(([, method, routePath, literals]) => ({
    method,
    path: routePath,
    description: [...literals.matchAll(/"((?:[^"\\]|\\.)*)"/g)].map((m) => m[1]).join(""),
  }));
}

test("the row parser reads every row of the curated index", () => {
  const src = readFileSync(CONTROLLER, "utf8");
  const heads = src.match(/%\{\s*method:\s*"/g) ?? [];

  assert.ok(heads.length > 0, "no row head found — the controller's shape has drifted");
  assert.equal(indexRows().length, heads.length, "a row this parser cannot read is a row unchecked");
});

test("every route-index row naming an MCP tool names one that sends that route", () => {
  const named = indexRows()
    .map((row) => ({ ...row, tool: /MCP tool: ([a-z_]+)/.exec(row.description)?.[1] }))
    .filter((row) => row.tool && row.tool !== "none");

  assert.ok(named.length > 0, "no row names an MCP tool — the check would be vacuous");

  const wrong = named
    .filter((row) => !toolRoutes(row.tool).has(`${row.method} ${normalisePath(row.path)}`))
    .map((row) => `${row.method} ${row.path} -> ${row.tool}`);

  assert.deepEqual(wrong, [], "rows naming a tool that does not send their route");
});

test("toolRoutes attributes a route to the tool that sends it and not to a sibling", () => {
  assert.ok(toolRoutes("revoke_dispatch").has("POST /api/v1/dispatches/:param/revoke"));
  assert.ok(!toolRoutes("dispatch").has("POST /api/v1/dispatches/:param/revoke"));
  assert.equal(toolRoutes("no_such_tool").size, 0);
});
