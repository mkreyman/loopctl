/**
 * READING THE TOOL SURFACE AS DATA — shared by the drift guards in this directory
 * (loopctl #846.5, #846.6).
 *
 * WHY IT IS HERE AND NOT IN `lib/`. Nothing in this file runs at runtime: it exists so a test
 * can compare what the package DECLARES against what it DOES. `package.json`'s `files` array
 * lists `index.js`, `lib`, `README.md` and `LICENSE`, so a module under `test/` ships with
 * nothing, and `npm test` is `node --test test/*.test.js` — this filename does not match that
 * glob, so it is imported by tests and never run as one.
 *
 * WHY THE DECLARATIONS ARE PARSED RATHER THAN IMPORTED. `index.js` ends by connecting a
 * `StdioServerTransport` at the top level, so importing it from a test would take over the
 * test runner's stdin and stdout. Every existing guard here reads `index.js` as TEXT for the
 * same reason (`delivery_loop_tools.test.js`, `context_retriever_tools.test.js`). Those match
 * with regexes; the checks these helpers serve need the declarations as STRUCTURE — a schema's
 * property names, a description's prose — so the `const TOOLS = [ … ];` literal is sliced out
 * and evaluated.
 *
 * The sandbox resolves unknown identifiers to `{}` rather than throwing, because the literal
 * references one module-level constant (`CLAIM_SCHEMA`, used as a nested `claim:` property in
 * three declarations). That substitution is safe for a NESTED value and would be silently
 * wrong for a whole `inputSchema`, so `loadTools()` asserts every tool still has an object
 * `inputSchema.properties` — a declaration that moved its schema behind an identifier fails
 * loudly instead of reporting zero parameters.
 */

import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import vm from "node:vm";
import path from "node:path";

const DIR = path.dirname(fileURLToPath(import.meta.url));
export const PKG_DIR = path.join(DIR, "..");
export const REPO_DIR = path.join(PKG_DIR, "..");

/** `index.js` plus every module in `lib/`, concatenated — the package's whole request surface. */
export function packageSource() {
  const libs = readdirSync(path.join(PKG_DIR, "lib"))
    .filter((f) => f.endsWith(".js"))
    .sort()
    .map((f) => readFileSync(path.join(PKG_DIR, "lib", f), "utf8"));

  return [readFileSync(path.join(PKG_DIR, "index.js"), "utf8"), ...libs].join("\n");
}

/** The statically declared tools, as objects. */
export function loadTools() {
  const src = readFileSync(path.join(PKG_DIR, "index.js"), "utf8");
  const start = src.indexOf("\nconst TOOLS = [");
  if (start === -1) throw new Error("index.js no longer declares `const TOOLS = [`");

  const end = src.indexOf("\n];", start);
  if (end === -1) throw new Error("the TOOLS literal has no closing `\\n];`");

  const literal = src.slice(start + "\nconst TOOLS = ".length, end + 2);
  const sandbox = new Proxy(
    {},
    { has: () => true, get: (_t, k) => (k === Symbol.unscopables ? undefined : {}) },
  );
  const tools = vm.runInNewContext(`(${literal})`, sandbox);

  for (const tool of tools) {
    const props = tool?.inputSchema?.properties;
    if (!props || typeof props !== "object" || Array.isArray(props)) {
      throw new Error(
        `tool ${tool?.name} has no object inputSchema.properties — if its schema moved behind ` +
          `an identifier, resolve it here rather than letting it read as zero parameters`,
      );
    }
  }

  return tools;
}

/** A tool's declared parameter names. */
export function declaredParameters(tool) {
  return new Set(Object.keys(tool.inputSchema?.properties ?? {}));
}

// A backticked lowercase snake_case token. Lower case excludes the env vars descriptions name
// constantly (LOOPCTL_USER_KEY), which are not parameters of anything.
const TOKEN_SOURCE = "`([a-z][a-z0-9]*(?:_[a-z0-9]+)*)`";
const TOKEN = new RegExp(TOKEN_SOURCE, "g");

// "pass `x`" / "send the `x`" — an offer verb governing the token directly. `to` is
// deliberately NOT an allowed filler: "the attestation to pass to `dispatch`" names a
// DESTINATION TOOL, not a parameter of the tool being described.
const OFFER_VERB = "(?:pass|passing|send|sending|supply|supplying|provide|providing|set|setting)";
const DIRECT_OFFER = new RegExp(
  `\\b${OFFER_VERB}\\s+(?:an?\\s+|the\\s+|your\\s+|its\\s+|them\\s+as\\s+)?${TOKEN_SOURCE}`,
  "gi",
);

// "Pass any of them to override" — an offer with no token of its own, whose referent is the
// enumeration just made. This is the shape that hid #846.5: `place_dispatch` enumerated `repo`
// in one sentence and offered "any of them" in the next, and no adjacency rule reaches across
// that boundary.
const ANAPHORIC_OFFER = new RegExp(
  `\\b${OFFER_VERB}\\s+(?:any\\s+(?:one\\s+)?(?:of\\s+)?(?:them|these|those)|them|either\\s+of\\s+them)\\b`,
  "i",
);

/**
 * The parameter names a tool description OFFERS the caller as passable.
 *
 * This is deliberately NARROW. Every backticked token in a description is not a parameter —
 * descriptions name response fields, error codes, sibling tools and enum values, and a scan of
 * the whole surface found 111 such tokens against 147 tools. What is claimed here is only the
 * two shapes in which a description tells a caller to SEND something, and the fixtures in
 * `description_schema_drift.test.js` pin both against hand-written declarations so the
 * extractor's own behaviour is falsifiable without reference to any shipped description.
 *
 * The anaphoric window is the cue's sentence plus the one before it, and no further: the
 * referent of "any of them" is the enumeration immediately at hand, and widening the window to
 * a paragraph pulled in response fields two sentences up.
 */
export function offeredParameters(description = "") {
  const offered = new Set();

  for (const m of description.matchAll(DIRECT_OFFER)) offered.add(m[1]);

  const sentences = description.split(/(?<=[.!?])\s+|\n+/);
  for (let i = 0; i < sentences.length; i++) {
    if (!ANAPHORIC_OFFER.test(sentences[i])) continue;
    const window = `${sentences[i - 1] ?? ""} ${sentences[i]}`;
    for (const m of window.matchAll(TOKEN)) offered.add(m[1]);
  }

  return offered;
}


// ---------------------------------------------------------------------------
// Which /api/v1 routes this package actually calls
// ---------------------------------------------------------------------------

/**
 * ONE PATH EXPRESSION CAN NAME SEVERAL ROUTES, so everything here resolves to an ARRAY.
 *
 * That is not defensive generality: `knowledge_index` really does reach two routes from one
 * call site (`project_id ? \`/api/v1/projects/${id}/knowledge/index\` : "/api/v1/knowledge/
 * index"`), and `get_cost_summary` reaches four through an if/else chain. A first draft took
 * the first arm and reported the other three as UNREACHED, which is the failure mode a
 * coverage sweep must not have: an invented gap teaches a reader to ignore the list.
 */

/**
 * Resolve a `${…}` interpolation inside a path template by its POSITION, which is what decides
 * its meaning in this codebase:
 *
 *   - at the very START of the template it is a nested builder, a module constant or a local
 *     the handler assembled a line earlier (`${corpusPath(id)}/index`, `${RUNNERS_PATH}/…`,
 *     `${basePath}?${qs}`), and is resolved recursively — into as many paths as it has;
 *   - immediately after a `/` it is a path SEGMENT — an id — and becomes `:param`;
 *   - anywhere else it is a QUERY STRING or a suffix appended to the last segment
 *     (`/api/v1/runners${query}`, `${buildQuery([…])}`) and contributes nothing to the path.
 *
 * That third rule is why the resolver does not try to evaluate `buildQuery`: a query string is
 * not part of the route Phoenix matches, so it is dropped rather than interpreted.
 */
function resolveTemplate(src, template, offset, depth = 0) {
  if (depth > 5) return [template];

  let out = [""];

  for (const chunk of splitTemplate(template)) {
    if (chunk.literal !== undefined) {
      out = out.map((prefix) => prefix + chunk.literal);
      continue;
    }

    const expr = chunk.expr.trim();
    const expansions = out.map((prefix) => {
      if (prefix === "") return resolveLeading(src, expr, offset, depth);
      if (prefix.endsWith("/")) return [":param"];
      // Query string or suffix — contributes nothing to the route.
      return [""];
    });

    out = out.flatMap((prefix, i) => expansions[i].map((piece) => prefix + piece));
  }

  return out;
}

function resolveLeading(src, expr, offset, depth) {
  const call = expr.match(/^([A-Za-z0-9_]+)\s*\(/);
  if (call) {
    const nested = builderTemplate(src, call[1]);
    if (nested !== null) return resolveTemplate(src, nested, offset, depth + 1);
  }

  if (/^[A-Z][A-Z0-9_]*$/.test(expr)) {
    const literal = constTemplate(src, expr);
    if (literal !== null) return resolveTemplate(src, literal, offset, depth + 1);
  }

  if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(expr)) {
    const locals = localTemplates(src, expr, offset);
    if (locals.length > 0) {
      return locals.flatMap((t) => resolveTemplate(src, t, offset, depth + 1));
    }
  }

  return [":param"];
}

/** Split a template body into literal chunks and brace-balanced `${…}` interpolations. */
function splitTemplate(template) {
  const out = [];
  let literal = "";
  let i = 0;

  while (i < template.length) {
    if (template[i] === "$" && template[i + 1] === "{") {
      let depth = 1;
      let j = i + 2;
      while (j < template.length && depth > 0) {
        if (template[j] === "{") depth++;
        else if (template[j] === "}") depth--;
        j++;
      }
      out.push({ literal });
      literal = "";
      out.push({ expr: template.slice(i + 2, j - 1) });
      i = j;
    } else {
      literal += template[i];
      i++;
    }
  }

  out.push({ literal });
  return out;
}

function constTemplate(src, name) {
  const m = src.match(new RegExp(`\\bconst\\s+${name}\\s*=\\s*([\`"])([^\`"]*)\\1`));
  return m ? m[2] : null;
}

/** The first string/template a named function returns. Every path builder here is that shape. */
function builderTemplate(src, name) {
  const at = src.search(new RegExp(`\\bfunction\\s+${name}\\s*\\(`));
  if (at === -1) return null;

  const ret = src.indexOf("return ", at);
  if (ret === -1) return null;

  const quote = src[ret + "return ".length];
  if (quote !== "`" && quote !== '"') return null;

  const close = src.indexOf(quote, ret + "return ".length + 1);
  if (close === -1) return null;

  return src.slice(ret + "return ".length + 1, close);
}

/**
 * Every template assigned to `name` INSIDE the function containing `offset`.
 *
 * FUNCTION-SCOPED ON PURPOSE. A first draft searched the whole file backwards for
 * `const path = \`…\``, and `path` is the name half this package's handlers use — so a handler
 * assigning it from a builder call silently inherited a DIFFERENT handler's literal, and the
 * sweep reported `GET /api/v1/memory` as unreached while `memory_list` was calling it. A
 * mis-resolution is worse than an unresolved one in both directions: it invents a gap and
 * hides a real one.
 *
 * EVERY assignment in the region is taken, not the last: `get_cost_summary` declares `let
 * path` and assigns it in four branches, all four of which are routes it reaches. The cost is
 * that a path genuinely OVERWRITTEN before the call would still be counted as reached — a
 * shape that does not occur here, and one whose failure direction (a route counted as covered)
 * is at least visible as a tool that does not do what the sweep says.
 */
function localTemplates(src, name, offset) {
  const fnStart = Math.max(
    src.lastIndexOf("\nasync function ", offset),
    src.lastIndexOf("\nfunction ", offset),
  );
  const region = src.slice(fnStart === -1 ? 0 : fnStart, offset);

  const assignment = new RegExp(`(?:^|[^=!<>])\\b${name}\\s*=(?!=|>)`, "g");
  const out = [];

  for (const m of region.matchAll(assignment)) {
    const start = m.index + m[0].length;
    const semi = region.indexOf(";", start);
    out.push(...expressionTemplates(src, region.slice(start, semi === -1 ? undefined : semi)));
  }

  return out;
}

/** Every path template an expression can evaluate to: literals, builder calls, a constant. */
function expressionTemplates(src, expr) {
  const trimmed = expr.trim();
  const out = [];

  // Every string/template literal written in the expression. A ternary contributes both arms,
  // which is correct: `project_id ? \`/a/${id}/x\` : "/x"` really does reach two routes.
  for (const m of trimmed.matchAll(/`([^`]*)`|"((?:[^"\\]|\\.)*)"/g)) {
    out.push(m[1] ?? m[2]);
  }

  // Builder calls, resolved to their own return template.
  for (const m of trimmed.matchAll(/\b([A-Za-z0-9_]+)\s*\(/g)) {
    const template = builderTemplate(src, m[1]);
    if (template !== null) out.push(template);
  }

  // A bare module constant (`RUNNERS_PATH`).
  if (/^[A-Z][A-Z0-9_]*$/.test(trimmed)) {
    const literal = constTemplate(src, trimmed);
    if (literal !== null) out.push(literal);
  }

  return out;
}

// `apiCall("GET", …` — the VERB and the offset just past the comma. The path argument itself is
// read with a balanced scan rather than a regex: it routinely contains commas and parentheses
// (`encodeURIComponent(x)`, `buildQuery([…])`), and a `[^,)]+` capture truncated those to
// fragments that then resolved to nothing.
const CALL_HEAD = /\b(?:apiCall|publicApiCall)\(\s*"(GET|POST|PUT|PATCH|DELETE)"\s*,\s*/g;

/** The single argument beginning at `start`, up to the top-level `,` or `)` that ends it. */
function argumentAt(src, start) {
  let depth = 0;
  let quote = null;

  for (let i = start; i < src.length; i++) {
    const c = src[i];

    if (quote) {
      if (c === "\\") i++;
      else if (c === quote) quote = null;
      continue;
    }

    if (c === '"' || c === "'" || c === "`") {
      quote = c;
      continue;
    }

    if (c === "(" || c === "[" || c === "{") depth++;
    else if (c === ")" || c === "]" || c === "}") {
      if (depth === 0) return src.slice(start, i);
      depth--;
    } else if (c === "," && depth === 0) return src.slice(start, i);
  }

  return src.slice(start);
}

/**
 * Every `(method, path)` this package sends, with ids normalised to `:param`.
 *
 * FIVE EXPRESSION SHAPES reach `apiCall`, and all five are resolved rather than skipped — a
 * skipped call site reads as an UNREACHED route, which is exactly the verdict the sweep in
 * `route_coverage.test.js` is trying to make trustworthy. A literal; a path-builder call; a
 * bare identifier assigned either of those earlier in the SAME function; a ternary, whose arms
 * are both counted; and a `let` assigned in several branches, all of which are counted.
 * `unresolved` is returned rather than swallowed so the sweep fails on a shape this does not
 * understand instead of miscounting it.
 */
export function apiCallSites() {
  const src = packageSource();
  const resolved = [];
  const unresolved = [];

  for (const m of src.matchAll(CALL_HEAD)) {
    const verb = m[1];
    const expr = argumentAt(src, m.index + m[0].length).trim();
    const templates = /^[A-Za-z_][A-Za-z0-9_]*$/.test(expr)
      ? localTemplates(src, expr, m.index).concat(expressionTemplates(src, expr))
      : expressionTemplates(src, expr);

    const paths = new Set();
    for (const template of templates) {
      for (const candidate of resolveTemplate(src, template, m.index)) {
        const route = candidate.split("?")[0].replace(/\/+$/, "") || "/";
        // A template that does not resolve to an absolute path is not a path: an expression
        // can carry an unrelated string. A site that leaves NO path at all is reported
        // unresolved below rather than dropped.
        if (route.startsWith("/")) paths.add(route);
      }
    }

    if (paths.size === 0) {
      unresolved.push({ verb, expr });
      continue;
    }

    for (const route of paths) resolved.push({ verb, path: route, expr });
  }

  return { resolved, unresolved };
}

/** The set of `"VERB /path"` strings this package calls. */
export function reachedRoutes() {
  const { resolved } = apiCallSites();
  return new Set(resolved.map((c) => `${c.verb} ${c.path}`));
}

// ---------------------------------------------------------------------------
// Which /api/v1 routes loopctl serves
// ---------------------------------------------------------------------------

const ROUTE_LINE =
  /^(get|post|put|patch|delete)\s+"([^"]+)",\s*([A-Za-z0-9_.]+),\s*:([a-z_0-9]+)/;

// Phoenix's `resources` macro, expanded. The default action set and the paths each one
// generates are `Phoenix.Router.Resource`'s: `update` really does generate BOTH a PATCH and a
// PUT, and both are served, so both are counted.
const RESOURCE_ACTIONS = ["index", "edit", "new", "show", "create", "update", "delete"];

const RESOURCE_ROUTES = {
  index: [["GET", ""]],
  new: [["GET", "/new"]],
  create: [["POST", ""]],
  show: [["GET", "/:id"]],
  edit: [["GET", "/:id/edit"]],
  update: [
    ["PATCH", "/:id"],
    ["PUT", "/:id"],
  ],
  delete: [["DELETE", "/:id"]],
};

/**
 * Every route declared in `lib/loopctl_web/router.ex`, with its `scope` prefixes applied.
 *
 * The router is read as text rather than asked at runtime because this suite is `node --test`
 * with no BEAM anywhere near it. `mix phx.routes` would be the authority; a parse of the file
 * that DECLARES the routes is the next thing to it, and it cannot silently answer for a
 * different deployment than the tree it sits in.
 *
 * `resources` IS EXPANDED, and the first version of this parser did not do it — it matched
 * only the seven verb macros, so eleven `resources` lines covering projects, api_keys,
 * runners, webhooks, skills and articles were invisible. That direction is the safe one (a
 * route nobody knows about is never reported as an invented gap) and it is still wrong: the
 * coverage sweep in `route_coverage.test.js` would have answered for a surface with a hole in
 * it, which is the one thing a sweep must not do.
 */
export function routerRoutes() {
  const src = readFileSync(path.join(REPO_DIR, "lib", "loopctl_web", "router.ex"), "utf8");
  const routes = [];
  const scopes = [];
  let depth = 0;

  // A `resources` declaration wraps onto a second line when its `only:` list is long. Joined
  // here rather than handled below, so the scope/depth bookkeeping sees one statement.
  let pending = null;

  for (const raw of src.split("\n")) {
    let line = raw.trim();

    if (pending !== null) {
      pending = `${pending} ${line}`;
      if (line.endsWith(",")) continue;
      line = pending;
      pending = null;
    } else if (/^resources\s/.test(line) && line.endsWith(",")) {
      pending = line;
      continue;
    }

    const scope = line.match(/^scope\s+"([^"]*)"/);
    if (scope) {
      scopes.push({ depth, prefix: scope[1] });
      depth++;
      continue;
    }

    if (/^(if|else|unless|case|cond|defmodule|def |defp |pipeline |live_session|live |forward)/.test(line)) {
      if (/\bdo\b\s*$/.test(line)) depth++;
      continue;
    }

    if (line === "end") {
      depth--;
      if (scopes.length && scopes[scopes.length - 1].depth === depth) scopes.pop();
      continue;
    }

    const prefix = scopes.map((s) => s.prefix).join("");
    const push = (verb, routePath, controller, action) =>
      routes.push({
        verb,
        path: `${prefix}${routePath}`.replace(/\/{2,}/g, "/").replace(/(.)\/$/, "$1"),
        controller,
        action,
      });

    const resource = line.match(/^resources\s+"([^"]+)",\s*([A-Za-z0-9_.]+)(?:,\s*(.*))?$/);
    if (resource) {
      const [, base, controller, opts = ""] = resource;
      const only = opts.match(/\bonly:\s*\[([^\]]*)\]/);
      const except = opts.match(/\bexcept:\s*\[([^\]]*)\]/);
      const names = (m) =>
        m[1]
          .split(",")
          .map((a) => a.trim().replace(/^:/, ""))
          .filter(Boolean);

      const actions = only
        ? names(only)
        : except
          ? RESOURCE_ACTIONS.filter((a) => !names(except).includes(a))
          : RESOURCE_ACTIONS;

      for (const action of actions) {
        for (const [verb, suffix] of RESOURCE_ROUTES[action] ?? []) {
          push(verb, `${base}${suffix}`, controller, action);
        }
      }
      continue;
    }

    const m = line.match(ROUTE_LINE);
    if (!m) continue;

    push(m[1].toUpperCase(), m[2], m[3], m[4]);
  }

  return routes;
}

/** Router path ids normalised the way `reachedRoutes()` normalises them. */
export function normalisePath(routePath) {
  return routePath.replace(/:[A-Za-z0-9_]+/g, ":param");
}
