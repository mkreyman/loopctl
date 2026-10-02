/**
 * The shape check for an `article_id` that goes into a URL PATH, run once at dispatch
 * (lib/dispatch-prep.js) for every tool in ARTICLE_PATH_ID_TOOLS.
 *
 * A value that is not an id (a slug, a title, a number, "[object Object]") was interpolated
 * unchecked and came back as the server's generic 404, which agents read as "this article
 * does not exist". A '/' or '..' in it would also have changed which route was hit.
 *
 * Three endpoints resolve a unique 8-hex-digit id PREFIX server-side (#652:
 * `Knowledge.get_article/3`, reached by knowledge_get, knowledge_progressive_drill and
 * knowledge_article_stats), so those are `prefix` and accept a full UUID or at least 8 hex
 * digits with optional dashes. Every other article verb takes a full UUID. Surrounding
 * whitespace is trimmed, matching the blankness rule in lib/required-args.js, so a pasted
 * id with a trailing newline is used rather than refused. A refusal carries `status: 0` and
 * never echoes the value: a malformed id is often something pasted into the wrong argument,
 * and a tool result lands in the transcript.
 *
 * `knowledge_graph` also declares `article_id` but sends it as a query parameter, which the
 * server validates with its own error, so it is not listed.
 */

const ARTICLE_PATH_ID_TOOLS = {
  knowledge_get: "prefix",
  knowledge_progressive_drill: "prefix",
  knowledge_article_stats: "prefix",
  knowledge_suggest_links: "uuid",
  knowledge_update: "uuid",
  knowledge_publish: "uuid",
  knowledge_unpublish: "uuid",
  knowledge_archive: "uuid",
  knowledge_suppress: "uuid",
  knowledge_unsuppress: "uuid",
  knowledge_delete: "uuid",
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PREFIX_RE = /^[0-9a-f-]+$/i;

function refusal(body) {
  return { error: true, status: 0, body };
}

// Returns { value } with the trimmed id, or { refusal }.
function checkArticleId(value, mode) {
  if (typeof value !== "string") {
    return {
      refusal: refusal(
        `\`article_id\` must be a string id; got a ${Array.isArray(value) ? "array" : typeof value}. ` +
          "Copy the id from the search result's `id` field.",
      ),
    };
  }

  const id = value.trim();
  if (UUID_RE.test(id)) return { value: id };
  if (mode === "prefix" && PREFIX_RE.test(id) && id.replace(/-/g, "").length >= 8) {
    return { value: id };
  }

  const wanted =
    mode === "prefix"
      ? "an article UUID, or a unique prefix of at least 8 hex digits"
      : "a full article UUID (8-4-4-4-12 hex digits)";
  return {
    refusal: refusal(
      `\`article_id\` must be ${wanted}. Got a ${id.length}-character string that is not one. ` +
        "Copy the id from the search result's `id` field. The value is not repeated here.",
    ),
  };
}

export { ARTICLE_PATH_ID_TOOLS, checkArticleId };
