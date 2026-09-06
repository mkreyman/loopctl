defmodule LoopctlWeb.KnowledgeIndexJSON do
  @moduledoc """
  JSON rendering helpers for the knowledge index endpoint.

  Renders articles grouped by category with a caller-controlled lightweight
  projection (never body, embedding, or full metadata). The `fields` list is
  produced and validated by `LoopctlWeb.KnowledgeIndexController`; only those
  fields are emitted per article, which keeps the payload small for large
  catalogs.

  Both pages carry `meta.outcome` (`LoopctlWeb.Outcome`). A catalog discloses no
  degradation of its own, so the value here is only ever `success` or `empty` — but
  it is PRESENT, and that is the point: a client that has to remember which reads
  publish `outcome` cannot tell an endpoint that deliberately omits it from a server
  too old to send it, and reads both as "no classification available".
  """

  alias LoopctlWeb.Outcome

  @doc """
  Renders the knowledge index with articles grouped by category.

  `fields` is the list of projected field names (strings) to include for each
  article object.
  """
  def index(%{articles: grouped, meta: meta}, fields) do
    %{
      data:
        Map.new(grouped, fn {category, articles} ->
          {category, Enum.map(articles, &project(&1, fields))}
        end),
      meta:
        Outcome.put(
          %{
            total_count: meta.total_count,
            categories: meta.categories,
            offset: meta.offset,
            limit: meta.limit,
            truncated: meta.truncated,
            # `has_more` is a synonym for `truncated` (more rows beyond this page).
            has_more: meta.truncated,
            # Echo the applied projection so a consumer can tell a projected-out
            # field from a genuinely absent value.
            fields: fields
          },
          page_count(grouped)
        )
    }
  end

  @doc """
  Renders a KEYSET (cursor) index page (US-27.9b).

  Like `index/2`, articles are grouped by category and projected to `fields`. But
  the `meta` documents the cursor contract instead of offset/total_count, so an
  agent walking a tag or a source can drive pagination purely from the response:

  - `next_cursor` — the opaque, already-encoded cursor for the next page, or `null`
    when the walk is exhausted (the only exhaustion signal — there is no
    total_count to drift).
  - `has_more` — boolean, derived from the keyset peek (exactly `next_cursor != null`),
    never a COUNT.
  - `limit` — the effective per-page limit that actually ran.
  - `count` — the number of rows in THIS page (across all categories).

  `next_cursor` is encoded by the controller (it needs the tenant key), so this
  view receives it as a ready string or `nil`.
  """
  def keyset(
        %{results: results, next_cursor: next_cursor, has_more: has_more, limit: limit},
        fields
      ) do
    grouped =
      Enum.group_by(results, fn article -> to_string(article.category) end)

    %{
      data:
        Map.new(grouped, fn {category, articles} ->
          {category, Enum.map(articles, &project(&1, fields))}
        end),
      meta:
        Outcome.put(
          %{
            # The cursor walk is drift-free precisely BECAUSE it carries no total_count
            # to drift; `next_cursor: null` is the exhaustion signal.
            next_cursor: next_cursor,
            has_more: has_more,
            limit: limit,
            count: length(results),
            fields: fields,
            search_mode: "index_keyset"
          },
          length(results)
        )
    }
  end

  # `data` is a map of category => articles, so the page's row count is the sum across
  # groups rather than `map_size/1`, which would count CATEGORIES. No test can tell the
  # two apart through `outcome`: it reads only zero vs non-zero, and the grouping is built
  # from the rows themselves so a group is never empty. Written as the sum anyway because
  # this is the ROW count by name, and the next reader of it will not have that context.
  defp page_count(grouped) do
    Enum.reduce(grouped, 0, fn {_category, articles}, acc -> acc + length(articles) end)
  end

  defp project(article, fields) do
    Map.new(fields, fn field -> {field, field_value(article, field)} end)
  end

  defp field_value(article, "id"), do: article.id
  defp field_value(article, "title"), do: article.title
  defp field_value(article, "category"), do: to_string(article.category)
  defp field_value(article, "tags"), do: article.tags
  defp field_value(article, "status"), do: to_string(article.status)
  defp field_value(article, "updated_at"), do: article.updated_at
  defp field_value(article, "suppressed_at"), do: article.suppressed_at
  defp field_value(article, "suppressed_by"), do: article.suppressed_by
  defp field_value(article, "suppression_reason"), do: article.suppression_reason
end
