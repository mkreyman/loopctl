/**
 * An `article_id` bound for a URL path or query: trimmed (an id pasted with a trailing newline
 * is the id), then held to the shared `uuid()` check in lib/delivery-loop.js. Returns `{ id }`
 * to send, or `{ refusal }` (status 0, value never echoed).
 *
 * The reads whose server path resolves an id prefix (#652: knowledge_get,
 * knowledge_progressive_drill, knowledge_article_stats) pass `{ prefix: true }`; every other
 * article verb takes a full UUID. A missing id used to go out as `/undefined` and come back as
 * a 404 that agents read as "the article does not exist".
 */
import { uuid } from "./delivery-loop.js";

export function articleId(value, { prefix = false } = {}) {
  const trimmed = typeof value === "string" ? value.trim() : value;
  const refusal = uuid(trimmed, "article_id", { prefix });
  return refusal ? { refusal } : { id: trimmed };
}
