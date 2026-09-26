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

/**
 * Line and block comments out — the ONE copy, shared by every guard here that reads source as
 * text (`custody_key_pinning`, `delivery_loop_tools`, `mcp_version_tool`, `story_update_tool`,
 * `route_coverage`).
 *
 * WHY EVERY SUCH GUARD NEEDS IT. Each of them asserts that some wiring is PRESENT by matching
 * it in the source, and a disabling edit's natural shape is to comment the wiring out — which
 * leaves the text in the file and the assertion green. #861 round 1 closed that on two of them
 * by hand, each with its own inline pair of `replace` calls; `route_coverage`'s dispatch-case
 * scan was written afterwards, excluded line comments (by anchoring `case` to the start of a
 * line) and not BLOCK comments, and so counted a block-commented `case` as dispatched. Four
 * hand-kept copies is how the fifth site gets written without one.
 *
 * ITS ONE LIMIT, stated because a caller that hands it a WHOLE FILE is exposed to it and the
 * handler-slice callers were not: it does not parse strings, so a block-comment OPENER inside a
 * string literal would swallow source up to the next closer. Measured on `index.js`
 * (2026-09-16): 6 such openers, all of them real comments, and the dispatch-case count is identical
 * before and after stripping. The failure direction is loud rather than silent — swallowed
 * source means a declared tool reads as having no `case`, which fails the assertion that
 * follows with the tool named.
 */
export function stripComments(source) {
  return source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/[^\n]*/g, "");
}

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

    for (const route of paths) resolved.push({ verb, path: route, expr, offset: m.index });
  }

  return { resolved, unresolved };
}

/** The set of `"VERB /path"` strings this package calls. */
export function reachedRoutes() {
  const { resolved } = apiCallSites();
  return new Set(resolved.map((c) => `${c.verb} ${c.path}`));
}

const FUNCTION_HEAD = /\b(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)\s*\(/g;
const CALLED_NAME = /\b([A-Za-z_$][\w$]*)\s*\(/g;

/**
 * The `"VERB /path"` strings ONE tool sends: `reachedRoutes()` narrowed to the call sites
 * inside the functions its `case "<tool>":` reaches.
 *
 * A function is the text from its `function NAME(` head to the next such head, and every
 * same-named function in the package (index.js and lib/ share names) is one node; an
 * `import { a as b }` alias is an edge from b to a. Reaching is by NAME — a declared
 * function named anywhere in a reached body is reached — so it errs toward crediting a tool
 * with a route. The one way it errs the other way is a handler that is not a `function`
 * declaration (an arrow or a method): its call sites are invisible and the route reads as
 * NOT sent, which fails a caller's assertion loudly. An unknown tool, or a case whose
 * handler resolves to nothing, returns an empty set rather than throwing.
 */
export function toolRoutes(tool) {
  const src = packageSource();
  const caseAt = src.indexOf(`case "${tool}":`);
  if (caseAt === -1) return new Set();

  const heads = [...src.matchAll(FUNCTION_HEAD)];
  const spans = new Map();
  heads.forEach((m, i) => {
    const end = i + 1 < heads.length ? heads[i + 1].index : src.length;
    spans.set(m[1], [...(spans.get(m[1]) ?? []), [m.index, end]]);
  });

  const aliases = new Map();
  for (const block of src.matchAll(/import\s*\{([^}]*)\}\s*from/g)) {
    for (const [, original, local] of block[1].matchAll(/([A-Za-z_$][\w$]*)\s+as\s+([A-Za-z_$][\w$]*)/g)) {
      aliases.set(local, [...(aliases.get(local) ?? []), original]);
    }
  }

  const callees = (text) =>
    [...text.matchAll(CALLED_NAME)].flatMap(([, name]) => [name, ...(aliases.get(name) ?? [])]);

  const caseEnd = src.indexOf("case \"", caseAt + 1);
  const queue = callees(src.slice(caseAt, caseEnd === -1 ? src.length : caseEnd));
  const seen = new Set();

  while (queue.length > 0) {
    const name = queue.shift();
    if (seen.has(name) || !spans.has(name)) continue;
    seen.add(name);
    for (const [start, end] of spans.get(name)) queue.push(...callees(src.slice(start, end)));
  }

  const inside = (offset) =>
    [...seen].some((name) => spans.get(name).some(([start, end]) => offset >= start && offset < end));

  const { resolved } = apiCallSites();
  return new Set(resolved.filter((c) => inside(c.offset)).map((c) => `${c.verb} ${c.path}`));
}

// ---------------------------------------------------------------------------
// Which routes loopctl serves — read from the router's own output, never parsed
// ---------------------------------------------------------------------------

/** The generated route table. Written by `mix loopctl.routes_snapshot` at the repo root. */
export const ROUTER_SNAPSHOT = path.join(DIR, "router-routes.json");

/**
 * Every route `LoopctlWeb.Router` serves, as `{ verb, path, plug, plugOpts }`.
 *
 * ## THIS USED TO BE A REGEX PARSER, AND THAT WAS THE DEFECT
 *
 * It read `lib/loopctl_web/router.ex` as text and the suite treated its output as the
 * complete route table. Over two review rounds it was silently wrong FOUR times:
 *
 *   1. `resources` was never expanded — eleven lines, 34 routes, invisible;
 *   2. a multi-line declaration was joined for `resources` and not for the verb macros —
 *      nine more, one of them (`GET /api/v1/knowledge/analytics/projects/:id/usage`) live
 *      and reached by nothing, so it was absent from the parse, from the UNREACHED list and
 *      from the declared inventory at once;
 *   3. a `#` comment or a blank line INSIDE a wrapped declaration was absorbed into the
 *      join, producing a statement the line matcher did not match, and the route vanished
 *      (292 routes became 291 with all twelve tests still green; re-measured on this branch
 *      at the `/api/v1` subset the sweep reads, one `#` comment took it 283 -> 282 and the
 *      route it interrupted was the one that disappeared);
 *   4. a plug mounted with no action atom — `get "/openapi", OpenApiSpex.Plug.RenderSpec,
 *      []` (`router.ex:124`) — could never match a matcher that required a trailing
 *      `:action`.
 *
 * Each round patched the regex that had just been caught and each time this comment claimed
 * the class was closed. It was not, because the defect is not in any of the four patterns:
 * it is a parser ASSERTING ITS OWN COMPLETENESS with nothing to check it against. A fifth
 * pattern would have gone the same way.
 *
 * ## SO THE ROUTER ANSWERS FOR ITSELF
 *
 * `mix loopctl.routes_snapshot` writes `Phoenix.Router.routes(LoopctlWeb.Router)` to
 * `router-routes.json`, and this function reads it. There is no second opinion left to
 * disagree with the router, and layout — a wrap, a comment, a blank line, a macro nobody
 * taught a regex — cannot change the answer, because the answer is taken after the router
 * is compiled rather than before.
 *
 * WHAT KEEPS IT CURRENT is `test/loopctl_web/router_snapshot_test.exs`, which asserts the
 * checked-in file is byte-identical to what the router renders NOW. It runs in
 * `mix precommit` and in the CI Test job, both on every change to the Elixir project — so a
 * router edit that skips the regeneration is red there, and regenerating touches
 * `mcp-server/**`, which is what makes the node workflow re-run the coverage sweep against
 * the surface that just changed.
 *
 * The one exposure that remains, stated rather than papered over: if BOTH that test and
 * this file's reader are removed, nothing notices. That is true of any guard, and it is a
 * different thing from the silent disagreement between two live sources that this replaces.
 */
export function routerRoutes() {
  let snapshot;

  try {
    snapshot = JSON.parse(readFileSync(ROUTER_SNAPSHOT, "utf8"));
  } catch (cause) {
    throw new Error(
      `${ROUTER_SNAPSHOT} could not be read as JSON. It is generated — run ` +
        `\`mix loopctl.routes_snapshot\` at the repo root and commit the result. ` +
        `(${cause.message})`,
      { cause },
    );
  }

  if (!Array.isArray(snapshot.routes) || snapshot.routes.length === 0) {
    throw new Error(
      `${ROUTER_SNAPSHOT} carries no routes. An empty inventory makes every sweep that ` +
        `reads it vacuously green — regenerate it with \`mix loopctl.routes_snapshot\`.`,
    );
  }

  return snapshot.routes.map((row) => {
    // CHECKED BEFORE IT IS DESTRUCTURED. A row shape this does not understand is thrown on
    // rather than coerced: a `[verb, path]` pair read as a route with an undefined controller
    // is the same "answer for something you did not read" failure the parser was retired for,
    // and destructuring first would make a non-array row a bare TypeError naming nothing.
    const shaped =
      Array.isArray(row) && row.length === 4 && row.slice(0, 2).every((c) => typeof c === "string");

    if (!shaped) {
      throw new Error(
        `${ROUTER_SNAPSHOT} has a row this reader does not understand: ${JSON.stringify(row)}. ` +
          `Its columns are ${JSON.stringify(snapshot.columns)}.`,
      );
    }

    const [verb, routePath, plug, plugOpts] = row;
    return { verb, path: routePath, plug, plugOpts };
  });
}

/** Router path ids normalised the way `reachedRoutes()` normalises them. */
export function normalisePath(routePath) {
  return routePath.replace(/:[A-Za-z0-9_]+/g, ":param");
}
