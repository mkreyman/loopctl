defmodule LoopctlWeb.KnowledgeIndexJSON do
  @moduledoc """
  JSON rendering helpers for the knowledge index endpoint.

  Renders articles grouped by category with lightweight metadata
  (no body, embedding, or full metadata).
  """

  @doc "Renders the knowledge index with articles grouped by category."
  def index(%{articles: grouped, meta: meta}) do
    %{
      data:
        Map.new(grouped, fn {category, articles} ->
          {category, Enum.map(articles, &article_summary/1)}
        end),
      meta: %{
        total_count: meta.total_count,
        categories: meta.categories,
        truncated: meta.truncated
      }
    }
  end

  defp article_summary(article) do
    %{
      id: article.id,
      title: article.title,
      category: to_string(article.category),
      tags: article.tags,
      status: to_string(article.status),
      updated_at: article.updated_at
    }
  end
end
