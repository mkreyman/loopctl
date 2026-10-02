/**
 * Refuse a tool call that is missing an argument its schema declares `required`.
 *
 * The MCP client does not enforce `required`, so a call without one reached the handler,
 * which interpolated `undefined` into the request. For a path parameter that is
 * `GET /api/v1/articles/undefined`, a 404 the caller cannot tell from "this article does
 * not exist". All 30 knowledge_get 404s in production for 2026-09-25..30 were exactly that,
 * and agents reported real, published articles as missing. For a query parameter it is
 * worse: the channel reads are oracle-safe, so a missing project_id answers 200 with an
 * empty set, a false negative with no error at all.
 *
 * So the refusal happens here, before any request, and names the missing parameter and the
 * keys that did arrive, so the caller can see its own misspelling.
 */

function isBlank(v) {
  return v === undefined || v === null || (typeof v === "string" && v.trim() === "");
}

function missingRequiredArgs(args, inputSchema) {
  const required = inputSchema?.required ?? [];
  const given = args && typeof args === "object" && !Array.isArray(args) ? args : {};
  return required.filter((key) => isBlank(given[key]));
}

function requiredArgsRefusal(toolName, missing, args) {
  const passed =
    args && typeof args === "object" && !Array.isArray(args) ? Object.keys(args) : [];
  const result = {
    error: true,
    code: "missing_required_argument",
    tool: toolName,
    missing,
    passed,
    message:
      `${toolName} was called without its required argument(s): ${missing.join(", ")}. ` +
      `Arguments received: ${passed.length ? passed.join(", ") : "none"}. ` +
      `No request was sent, so this says nothing about whether the target exists. ` +
      `Retry with ${missing.map((m) => `'${m}'`).join(", ")} set.`,
  };
  return {
    content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    isError: true,
  };
}

export { missingRequiredArgs, requiredArgsRefusal };
