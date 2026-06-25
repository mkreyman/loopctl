defmodule Loopctl.Knowledge.StreamingExport.OKFFormat do
  @moduledoc """
  OKF (Open Knowledge Format) v0.1 format for the streaming export (US-27.16).

  Renders the same per-article concept files the legacy `OKF.build_bundle/2`
  produced — `{type}/{slug}.md`-style concept files with `loopctl_*` producer-key
  frontmatter, the article body, and a marked `# Related` section encoding the
  `relates_to`/`derived_from` graph — but one article at a time so the streaming
  core never materializes the whole bundle.

  ## Collision-free paths (no data loss)

  The legacy exporter held a global path map (`assign_paths/1`) and DEDUPED
  same-slug articles (`foo`, `foo-2`, …). Streaming can't hold a global map, so
  instead each concept is written to an ID-SUFFIXED path
  `{category}/{slug}-{short_id}.md` (the first 8 hex of the article UUID). This
  guarantees EVERY article gets a distinct path with zero global state — two
  published articles sharing a category+slug can no longer map to the same tar
  entry and overwrite each other (that would be silent whole-article data loss on a
  backup). Each `# Related` link is built with the SAME function applied to the
  neighbor's id, so inter-article links still resolve after suffixing.

  The root `index.md` is built from a CHEAP per-category COUNT aggregate (no
  bodies). The legacy `log.md` and per-category `index.md` listings required
  loading every article, so they are omitted from the streamed bundle — the
  per-category root index is the bounded-memory replacement, and a re-import never
  depended on them (they are reserved/skipped on import).
  """

  @behaviour Loopctl.Knowledge.StreamingExport.Format

  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.OKF

  @okf_version "0.1"
  @related_marker "<!-- okf:related -->"

  @impl true
  def index_position, do: :prelude

  @impl true
  def article_entries(article, ctx) do
    path = concept_path(article.category, article.title, article.id)
    links = Map.get(ctx, :links, [])
    truncated? = Map.get(ctx, :links_truncated, false)
    [{path, render_concept(article, links, truncated?)}]
  end

  # Deterministic, COLLISION-FREE concept path: `{category}/{slug}-{short_id}.md`.
  # The id suffix (first 8 hex chars of the article's UUID) guarantees two articles
  # with the same category+slug get DISTINCT paths — without it, the second would
  # overwrite the first on tar extraction (whole-article data loss). The same
  # function builds the `# Related` link target (via the neighbor's id), so links
  # still resolve after the suffixing.
  defp concept_path(category, title, id) do
    "#{category}/#{Knowledge.slugify(title)}-#{short_id(id)}.md"
  end

  # First 8 hex chars of the canonical UUID (the chars before the first `-`),
  # lowercased — stable, URL-safe, and collision-resistant enough at the per-
  # category+slug granularity (a 32-bit suffix). A bundle is never rejected for a
  # suffix collision; it would just (astronomically rarely) reuse a path, which is
  # the SAME failure mode as today's slug-only path but ~4-billion× less likely.
  defp short_id(id) when is_binary(id) do
    id |> String.downcase() |> String.replace("-", "") |> String.slice(0, 8)
  end

  @impl true
  def index_entries(aggregate) do
    [{"index.md", render_root_index(aggregate)}]
  end

  # --- per-article concept ---

  defp render_concept(article, links, truncated?) do
    frontmatter = OKF.encode_frontmatter(concept_frontmatter(article, truncated?))
    body = concept_body(article, links)
    "---\n#{frontmatter}---\n\n#{body}"
  end

  defp concept_frontmatter(article, truncated?) do
    okf = Map.get(article.metadata || %{}, "okf", %{})
    extra = Map.get(okf, "extra", %{})

    base = %{
      "type" => Map.get(okf, "type") || to_string(article.category),
      "title" => article.title,
      "description" => Map.get(okf, "description"),
      "resource" => Map.get(okf, "resource"),
      "tags" => Map.get(okf, "tags") || article.tags,
      "timestamp" => Map.get(okf, "timestamp") || DateTime.to_iso8601(article.updated_at),
      "loopctl_id" => article.id,
      "loopctl_category" => to_string(article.category),
      "loopctl_status" => to_string(article.status)
    }

    extra
    |> Map.merge(base)
    |> maybe_mark_truncated(truncated?)
    |> reject_empty()
  end

  # #7: when the per-article link list was capped, mark it so a consumer can tell
  # the relationship graph in this bundle is INCOMPLETE for this concept (not a
  # genuine leaf). Fail-closed-consistent: truncation is detectable, not silent.
  defp maybe_mark_truncated(map, true), do: Map.put(map, "loopctl_links_truncated", true)
  defp maybe_mark_truncated(map, false), do: map

  defp concept_body(article, links) do
    body = String.trim_trailing(article.body || "")

    case related_links(links) do
      [] ->
        body <> "\n"

      rendered ->
        section = "# Related\n#{@related_marker}\n\n" <> Enum.join(rendered, "\n") <> "\n"
        prefix = if body == "", do: "", else: body <> "\n\n"
        prefix <> section
    end
  end

  # Only `relates_to`/`derived_from` outgoing edges round-trip (the importer never
  # reconstructs `:supersedes`/`:contradicts`); rendering only those keeps the
  # bundle faithful and avoids advertising destructive edges. Incoming links are
  # NOT rendered (the legacy exporter rendered only outgoing `relates_to`).
  defp related_links(links) do
    links
    |> Enum.filter(fn link ->
      link.direction == :outgoing and link.status == :published and
        link.relationship_type in [:relates_to, :derived_from]
    end)
    |> Enum.map(fn link ->
      # Resolve to the neighbor's id-suffixed concept path (same scheme as
      # article_entries/2) so the link points at the right file even when two
      # articles share a category+slug.
      path = concept_path(link.category, link.title, link.neighbor_id)
      "- [#{escape_link_text(link.title)}](/#{path}) — #{link.relationship_type}"
    end)
  end

  defp escape_link_text(text), do: String.replace(text, "]", "\\]")

  # --- cheap root index ---

  defp render_root_index(aggregate) do
    front = "---\nokf_version: \"#{@okf_version}\"\n---\n\n"
    heading = "# Knowledge Bundle\n\n"

    items =
      aggregate
      |> Enum.map(fn %{category: category, count: count} -> {to_string(category), count} end)
      |> Enum.sort_by(fn {category, _} -> category end)
      |> Enum.map_join("\n", fn {category, count} ->
        "* [#{String.capitalize(category)}](#{category}/index.md) - #{count} #{category} article(s)"
      end)

    front <> heading <> items <> "\n"
  end

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_k, v} -> v in [nil, "", []] end)
    |> Map.new()
  end
end
