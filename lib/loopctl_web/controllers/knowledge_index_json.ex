defmodule LoopctlWeb.KnowledgeIndexJSON do
  @moduledoc """
  JSON rendering helpers for the knowledge index endpoint.

  Renders articles grouped by category with a caller-controlled lightweight
  projection (never body, embedding, or full metadata). The `fields` list is
  produced and validated by `LoopctlWeb.KnowledgeIndexController`; only those
  fields are emitted per article, which keeps the payload small for large
  catalogs.
  """

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
      meta: %{
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
      }
    }
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
end
