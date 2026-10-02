/**
 * Refuse a request whose URL path carries an unfilled argument.
 *
 * A handler builds its path with a template string, so a path argument that never arrived
 * becomes the literal segment `undefined` (or `null`). The server answers that with its
 * ordinary 404, which an agent cannot tell from "this does not exist". Measured 2026-10-01:
 * all 30 knowledge_get 404s in loopctl's production logs for 2026-09-25..30 were
 * `GET /api/v1/articles/undefined`, against 38 of 38 reads carrying a real id that
 * succeeded, and agents reported real, published articles as missing. Two more were
 * `GET /api/v1/channel/posts/undefined`.
 *
 * The check lives at the one place every request passes (`apiCall`), so it covers every
 * tool and every future one without a list to maintain. It only refuses a request that
 * could never have meant anything, so it changes no answer a well-formed call gets. The
 * refusal carries `status: 0` (no request was sent), the house shape for a local refusal.
 */

const UNFILLED = new Set(["undefined", "null"]);

function unfilledPathRefusal(path) {
  if (typeof path !== "string") return null;
  const pathOnly = path.split("?", 1)[0];
  const segments = pathOnly.split("/");
  const at = segments.findIndex((s) => UNFILLED.has(s));
  if (at === -1) return null;

  const route = segments.map((s, i) => (i === at ? "<missing>" : s)).join("/");
  return {
    error: true,
    status: 0,
    body:
      `A required path argument was not supplied, so ${route} was never requested. ` +
      "This says nothing about whether the target exists. Check the argument NAMES in your " +
      "call against the tool's schema (for example article_id, not id) and retry.",
  };
}

export { unfilledPathRefusal };
