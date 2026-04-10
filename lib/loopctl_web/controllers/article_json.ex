defmodule LoopctlWeb.ArticleJSON do
  @moduledoc """
  JSON rendering helpers for article API responses.

  Provides consistent serialization for articles and article links
  across all article controller actions.
  """

  @doc "Renders a list of articles with pagination meta."
  def index(%{articles: articles, meta: meta}) do
    %{data: Enum.map(articles, &article_data/1), meta: meta}
  end

  @doc "Renders a single article with preloaded links."
  def show(%{article: article}) do
    %{data: article_data_with_links(article)}
  end

  @doc "Renders a newly created article."
  def create(%{article: article}), do: %{data: article_data(article)}

  @doc "Renders an updated article."
  def update(%{article: article}), do: %{data: article_data(article)}

  @doc "Renders an archived article."
  def delete(%{article: article}), do: %{data: article_data(article)}

  @doc "Serializes core article fields (no links)."
  def article_data(article) do
    %{
      id: article.id,
      tenant_id: article.tenant_id,
      project_id: article.project_id,
      title: article.title,
      body: article.body,
      category: article.category,
      status: article.status,
      tags: article.tags,
      source_type: article.source_type,
      source_id: article.source_id,
      metadata: article.metadata,
      inserted_at: article.inserted_at,
      updated_at: article.updated_at
    }
  end

  @doc "Serializes article with outgoing and incoming links."
  def article_data_with_links(article) do
    article_data(article)
    |> Map.put(:outgoing_links, Enum.map(loaded_links(article.outgoing_links), &link_data/1))
    |> Map.put(:incoming_links, Enum.map(loaded_links(article.incoming_links), &link_data/1))
  end

  defp link_data(link) do
    %{
      id: link.id,
      relationship_type: link.relationship_type,
      source_article: %{
        id: link.source_article_id,
        title: loaded_title(link.source_article)
      },
      target_article: %{
        id: link.target_article_id,
        title: loaded_title(link.target_article)
      }
    }
  end

  defp loaded_links(%Ecto.Association.NotLoaded{}), do: []
  defp loaded_links(nil), do: []
  defp loaded_links(links) when is_list(links), do: links

  defp loaded_title(%Ecto.Association.NotLoaded{}), do: nil
  defp loaded_title(nil), do: nil
  defp loaded_title(article), do: article.title
end
