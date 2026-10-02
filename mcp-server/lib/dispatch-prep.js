/**
 * Everything the CallTool dispatch does to a call before routing it: alias the argument
 * names, then refuse a call still missing a declared-required argument.
 *
 * It lives here rather than inline in index.js so a test can drive it with the real tool
 * schemas and assert the outcome. index.js connects a stdio transport at import time, so
 * its dispatch can only be checked as text, and a text check passed with the guard
 * commented out.
 *
 * `schemas` maps a STATIC tool's name to its inputSchema. A generated `cr_*` tool is absent:
 * its arguments are aliased with every fill reported, and no required check runs, so the
 * server's own validation answers for it.
 */
import { applyArgAliases } from "./arg-aliases.js";
import { missingRequiredArgs, requiredArgsRefusal } from "./required-args.js";

function prepareToolCall(name, rawArgs, schemas, onAliasUsed) {
  const schema = schemas.get(name);
  const declared = schema ? Object.keys(schema.properties ?? {}) : undefined;
  const args = applyArgAliases(rawArgs, onAliasUsed, declared, name);

  const missing = missingRequiredArgs(args, schema);
  if (missing.length > 0) {
    return { refusal: requiredArgsRefusal(name, missing, args, schema) };
  }
  return { args };
}

export { prepareToolCall };
