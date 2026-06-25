defmodule Loopctl.Knowledge.StreamingExport.ObsidianFormat do
  @moduledoc """
  Obsidian-vault format for the streaming export (US-27.16).

  Renders the same Obsidian-compatible layout the legacy `build_obsidian_zip`
  produced — one `{category}/{slug}.md` per article with YAML frontmatter and a
  `## Related Articles` `[[wikilink]]` section — but one article at a time so the
  streaming core never materializes the whole vault.

  The `_index.md` is built from a CHEAP per-category COUNT aggregate (no bodies),
  so it lists categories with article counts rather than every title. (The legacy
  index linked every title, which required loading all articles; that is exactly
  the materialization US-27.16 removes. The per-category index is the bounded-memory
  replacement.)
  """

  @behaviour Loopctl.Knowledge.StreamingExport.Format

  alias Loopctl.Knowledge

  @impl true
  def index_position, do: :prelude

  @impl true
  def article_entries(article, ctx) do
    category = to_string(article.category)
    path = "#{category}/#{Knowledge.slugify(article.title)}.md"
    [{path, build_markdown(article, Map.get(ctx, :links, []))}]
  end

  @impl true
  def index_entries(aggregate) do
    [{"_index.md", build_index(aggregate)}]
  end

  # --- per-article markdown ---

  defp build_markdown(article, links) do
    frontmatter = build_frontmatter(article)
    body = article.body || ""
    related = build_related_section(links)

    content = "#{frontmatter}\n#{body}"

    if related != "" do
      "#{content}\n\n#{related}\n"
    else
      "#{content}\n"
    end
  end

  defp build_frontmatter(article) do
    tags_yaml =
      case article.tags do
        [] -> ""
        nil -> ""
        tags -> "\ntags:\n" <> Enum.map_join(tags, "\n", &"  - #{&1}")
      end

    source_type_yaml =
      case article.source_type do
        nil -> ""
        st -> "\nsource_type: #{st}"
      end

    """
    ---
    title: "#{escape_yaml_string(article.title)}"
    category: #{article.category}#{tags_yaml}
    status: #{article.status}#{source_type_yaml}
    created_at: "#{DateTime.to_iso8601(article.inserted_at)}"
    updated_at: "#{DateTime.to_iso8601(article.updated_at)}"
    ---
    """
  end

  # Build the `## Related Articles` section from the BOUNDED link list the core
  # preloaded (already capped per article). Only published neighbors are linked.
  defp build_related_section(links) do
    rendered =
      links
      |> Enum.filter(&(&1.status == :published))
      |> Enum.map(fn link -> "- [[#{link.title}]] (#{link.relationship_type})" end)
      |> Enum.uniq()

    case rendered do
      [] -> ""
      items -> "## Related Articles\n\n" <> Enum.join(items, "\n")
    end
  end

  # --- cheap index ---

  defp build_index(aggregate) do
    header = "# Knowledge Base Index\n\n"

    body =
      aggregate
      |> Enum.map(fn %{category: category, count: count} -> {to_string(category), count} end)
      |> Enum.sort_by(fn {category, _} -> category end)
      |> Enum.map_join("\n\n", fn {category, count} ->
        "## #{String.capitalize(category)}\n\n#{count} article(s)"
      end)

    header <> body <> "\n"
  end

  defp escape_yaml_string(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end
