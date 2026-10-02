/**
 * Refuse a request whose URL path carries an unfilled or unsafe segment.
 *
 * A handler builds its path with a template string, so a path argument that never arrived
 * becomes the literal segment `undefined`, and a blank one becomes an empty segment. The
 * server answers the first with its ordinary 404, which an agent cannot tell from "this does
 * not exist". The second can route somewhere else entirely: `/api/v1/articles/` reaches the
 * article INDEX and returns a page of unrelated articles as a success. Measured 2026-10-01:
 * all 30 knowledge_get 404s in loopctl's production logs for 2026-09-25..30 were
 * `GET /api/v1/articles/undefined`, against 38 of 38 reads carrying a real id that
 * succeeded, and agents reported real, published articles as missing.
 *
 * A `.` or `..` segment is refused too: an argument carrying one would move the request to a
 * different route under the same key, and no endpoint here has such a segment.
 *
 * The check lives at the one place every request passes (`apiCall`), so it covers every
 * tool without a list to maintain. The cost: a caller who genuinely supplies the string
 * "undefined" as a path value is refused as well. `null` is not checked, because "null" is
 * a plausible free-text value (an egress host, a custody subject) and an unfilled argument
 * arrives as undefined, not null. The refusal carries `status: 0` (no request was sent).
 */

const REFUSED = new Set(["undefined", "", ".", ".."]);

function unfilledPathRefusal(path) {
  if (typeof path !== "string") return null;
  // Segments after the leading "/" of the path proper; the query string is not a path.
  const segments = path.split("?", 1)[0].split("/").slice(1);
  const at = segments.findIndex((s) => REFUSED.has(s));
  if (at === -1) return null;

  const route = "/" + segments.map((s, i) => (i === at ? "<missing>" : s)).join("/");
  return {
    error: true,
    status: 0,
    body:
      `A path argument was missing, blank or not a plain value, so ${route} was never ` +
      "requested. This says nothing about whether the target exists. Check the argument " +
      "names and values in your call against the tool's schema and retry.",
  };
}

export { unfilledPathRefusal };
