/**
 * Refuse a request whose URL path would not reach the route its handler built.
 *
 * A handler builds its path with a template string from raw arguments. A path argument
 * that never arrived becomes the literal segment `undefined`, which the server answers with
 * its ordinary 404, and an agent cannot tell that from "this does not exist". Measured
 * 2026-10-01: all 30 knowledge_get 404s in loopctl's production logs for 2026-09-25..30
 * were `GET /api/v1/articles/undefined`, against 38 of 38 reads carrying a real id that
 * succeeded, and agents reported real, published articles as missing.
 *
 * Other argument values change the route instead of failing: an empty value or a lone '#'
 * makes `/api/v1/articles/` (the article INDEX, a success with unrelated articles), and
 * '..', '%2e%2e' or a backslash resolve to a different endpoint under the same key. Those
 * are judged on the URL AS SENT, because fetch parses and normalizes it (WHATWG URL) before
 * sending: listing raw spellings misses every encoding of the same move. So the check parses
 * the path exactly as fetch will and refuses when parsing changed its shape (a dot segment in
 * any encoding resolves away, so the segment count changes), left an empty or whitespace-only
 * segment, or cut a fragment off (`<id>#x` keeps the count but drops part of the id).
 * Normalization does not depend on the host, so a fixed origin stands in for the server.
 *
 * It lives at the one place every request passes (`apiCall`), so it covers every tool's
 * path without a list to maintain. The query string is not checked: a query value is the
 * server's to validate, and "undefined" can be a real search term. The cost: a caller who
 * genuinely supplies the string "undefined" as a path value is refused too. The refusal
 * carries `status: 0` (no request was sent).
 */

function refusal(route) {
  return {
    error: true,
    status: 0,
    body:
      `A path argument was missing, blank or not a plain value, so ${route} was never ` +
      "requested. This says nothing about whether the target exists. Check the argument " +
      "names and values in your call against the tool's schema and retry.",
  };
}

function isBlankSegment(segment) {
  let decoded = segment;
  try {
    decoded = decodeURIComponent(segment);
  } catch {
    // A malformed escape is the server's to reject; judge the raw text.
  }
  return decoded.trim() === "";
}

function unfilledPathRefusal(path) {
  if (typeof path !== "string") return null;
  const rawPath = path.split("?", 1)[0];
  const rawSegments = rawPath.split("/").slice(1);

  const unfilled = rawSegments.findIndex((s) => s === "undefined");
  if (unfilled !== -1) {
    return refusal("/" + rawSegments.map((s, i) => (i === unfilled ? "<missing>" : s)).join("/"));
  }

  let sent;
  try {
    sent = new URL(path, "http://origin.invalid");
  } catch {
    return null; // fetch will report an unparseable URL itself
  }
  const sentSegments = sent.pathname.split("/").slice(1);

  if (
    sent.hash !== "" ||
    sentSegments.length !== rawSegments.length ||
    sentSegments.some(isBlankSegment)
  ) {
    return refusal(rawPath.replace(/\/[^/]*$/, "/<missing>"));
  }
  return null;
}

export { unfilledPathRefusal };
