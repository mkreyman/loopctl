/**
 * Everything the CallTool dispatch does to a call before routing it: alias the argument
 * names, refuse a call still missing a declared-required argument, and check the shape of an
 * article id that goes into a URL path.
 *
 * It lives here rather than inline in index.js so a test can drive it with the real tool
 * schemas and assert the outcome. index.js connects a stdio transport at import time, so
 * its dispatch can only be checked as text, and a text check passed with the guard
 * commented out.
 *
 * `schemas` maps a STATIC tool's name to its inputSchema. A generated `cr_*` tool is absent:
 * its arguments are aliased with every fill reported, and no local check runs, so the
 * server's own validation answers for it.
 */
import { applyArgAliases } from "./arg-aliases.js";
import { missingRequiredArgs, requiredArgsRefusal } from "./required-args.js";
import { ARTICLE_PATH_ID_TOOLS, checkArticleId } from "./article-id.js";

// One Set of declared parameter names per schema object, built on first use and reused for
// every later call to that tool.
const declaredCache = new WeakMap();

function declaredFor(schema) {
  if (!schema) return undefined;
  let declared = declaredCache.get(schema);
  if (!declared) {
    declared = new Set(Object.keys(schema.properties ?? {}));
    declaredCache.set(schema, declared);
  }
  return declared;
}

function prepareToolCall(name, rawArgs, schemas, onAliasUsed) {
  // MCP makes `arguments` optional. Handlers destructure it, so a missing or non-object value
  // becomes {} here rather than a TypeError inside the handler.
  const given =
    rawArgs && typeof rawArgs === "object" && !Array.isArray(rawArgs) ? rawArgs : {};
  const schema = schemas.get(name);
  const args = applyArgAliases(given, onAliasUsed, declaredFor(schema), name);

  const missing = missingRequiredArgs(args, schema);
  if (missing.length > 0) {
    return { refusal: requiredArgsRefusal(name, missing, args, schema) };
  }

  const idMode = Object.hasOwn(ARTICLE_PATH_ID_TOOLS, name) ? ARTICLE_PATH_ID_TOOLS[name] : null;
  if (idMode && args.article_id !== undefined) {
    const checked = checkArticleId(args.article_id, idMode);
    if (checked.refusal) return { refusal: checked.refusal };
    args.article_id = checked.value;
  }

  return { args };
}

export { prepareToolCall };
