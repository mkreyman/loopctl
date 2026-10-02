/**
 * The shape check for an `article_id` that goes into a URL PATH.
 *
 * A value that is not an id (a slug, a title, a number, "[object Object]") was interpolated
 * unchecked and came back as the server's generic 404, which agents read as "this article
 * does not exist". A '/' or '..' in it would also have changed which route was hit.
 *
 * Three endpoints resolve a unique 8-hex-digit id PREFIX server-side (#652:
 * `Knowledge.get_article/3`, reached by knowledge_get, knowledge_progressive_drill and
 * knowledge_article_stats), so those pass `{ prefix: true }` and accept a full UUID or at
 * least 8 hex digits with optional dashes. Every other article verb takes a full UUID only,
 * through the shared `uuid()` check. Both refuse with `status: 0` (no request was sent) and
 * never echo the value.
 */
import { uuid } from "./delivery-loop.js";

const PREFIX_RE = /^[0-9a-f-]+$/i;

function articleIdRefusal(value, { prefix = false } = {}) {
  if (!prefix) return uuid(value, "article_id");

  const strict = uuid(value, "article_id");
  if (strict === null) return null;
  if (typeof value === "string" && PREFIX_RE.test(value) && value.replace(/-/g, "").length >= 8) {
    return null;
  }
  return {
    error: true,
    status: 0,
    body:
      "`article_id` must be an article UUID, or a unique prefix of at least 8 hex digits. " +
      `Got a ${typeof value === "string" ? `${value.length}-character string` : typeof value} ` +
      "that is neither. Copy the id from the search result's `id` field. The value is not " +
      "repeated here.",
  };
}

export { articleIdRefusal };
