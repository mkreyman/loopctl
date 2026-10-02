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
 * The refusal uses the house shape, `{ error: true, status: 0, body }` (see `refuse()` in
 * lib/delivery-loop.js): `status: 0` means no request was sent. It carries each missing
 * parameter's own schema description, because this check runs before handlers whose
 * lib-level refusals used to explain the parameter (handoff's `anchor`, a runner's
 * `token_file`), and a bare "set X" lost that guidance.
 */

// The ONE blankness rule for argument presence, shared with lib/arg-aliases.js so the alias
// layer and this check can never disagree about whether an argument arrived. A
// whitespace-only string is blank: it cannot name anything.
function isBlank(v) {
  return v === undefined || v === null || (typeof v === "string" && v.trim() === "");
}

function missingRequiredArgs(args, inputSchema) {
  const required = inputSchema?.required ?? [];
  const given = args && typeof args === "object" && !Array.isArray(args) ? args : {};
  return required.filter((key) => isBlank(given[key]));
}

function requiredArgsRefusal(toolName, missing, args, inputSchema) {
  const passed =
    args && typeof args === "object" && !Array.isArray(args) ? Object.keys(args) : [];
  const guidance = Object.fromEntries(
    missing.map((key) => [key, inputSchema?.properties?.[key]?.description ?? null]),
  );
  return {
    error: true,
    status: 0,
    body: {
      code: "missing_required_argument",
      tool: toolName,
      missing,
      passed,
      guidance,
      message:
        `${toolName} was called without its required argument(s): ${missing.join(", ")}. ` +
        `Arguments received: ${passed.length ? passed.join(", ") : "none"}. ` +
        `No request was sent, so this says nothing about whether the target exists. ` +
        `See guidance for what each missing argument must hold.`,
    },
  };
}

export { isBlank, missingRequiredArgs, requiredArgsRefusal };
