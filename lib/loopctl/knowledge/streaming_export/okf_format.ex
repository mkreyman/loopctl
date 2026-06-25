defmodule Loopctl.Knowledge.StreamingExport.OKFFormat do
  @moduledoc """
  OKF (Open Knowledge Format) v0.1 format for the streaming export (US-27.16).

  Renders the same per-article concept files the legacy `OKF.build_bundle/2`
  produced — `{type}/{slug}.md` with `loopctl_*` producer-key frontmatter, the
  article body, and a marked `# Related` section encoding the `relates_to`/
  `derived_from` graph — but one article at a time so the streaming core never
  materializes the whole bundle.

  ## Differences from the legacy bundle (bounded-memory)

  The legacy exporter assigned globally-deduped bundle paths (`assign_paths/1`)
  across ALL articles in memory, then linked related concepts by that exact path.
  Streaming can't hold a global path map, so each `# Related` link points to the
  neighbor's DETERMINISTIC `{category}/{slug}.md` path (the un-deduped form). On a
  rare slug collision the path may not match a deduped sibling; the importer
  already treats an unresolved related-path as a best-effort skip
  (`is_nil(target_id) -> acc`), so this degrades a few links at most, never the
  content. The dominant matcher on re-import is `loopctl_id`/title, not the related
  path.

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
    path = "#{article.category}/#{Knowledge.slugify(article.title)}.md"
    [{path, render_concept(article, Map.get(ctx, :links, []))}]
  end

  @impl true
  def index_entries(aggregate) do
    [{"index.md", render_root_index(aggregate)}]
  end

  # --- per-article concept ---

  defp render_concept(article, links) do
    frontmatter = OKF.encode_frontmatter(concept_frontmatter(article))
    body = concept_body(article, links)
    "---\n#{frontmatter}---\n\n#{body}"
  end

  defp concept_frontmatter(article) do
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
    |> reject_empty()
  end

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
      path = "#{link.category}/#{Knowledge.slugify(link.title)}.md"
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
