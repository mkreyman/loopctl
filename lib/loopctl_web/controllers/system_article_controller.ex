defmodule LoopctlWeb.SystemArticleController do
  @moduledoc """
  US-26.0.3 — Public JSON API for system-scoped articles.

  No authentication required. System articles are globally visible
  canonical documentation for the loopctl protocol.
  """

  use LoopctlWeb, :controller

  alias Loopctl.Knowledge

  @doc """
  GET /api/v1/articles/system

  Lists all published system articles. Optionally filter by slug
  (returns a single article) or category.
  """
  def index(conn, params) do
    case Map.get(params, "slug") do
      slug when is_binary(slug) and slug != "" ->
        case Knowledge.get_system_article_by_slug(slug) do
          {:ok, article} ->
            json(conn, %{data: serialize_article(article)})

          {:error, :not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: %{message: "System article not found", status: 404}})
        end

      _ ->
        category = Map.get(params, "category")

        opts =
          if category do
            [category: String.to_existing_atom(category)]
          else
            []
          end

        articles = Knowledge.list_system_articles(opts)
        json(conn, %{data: Enum.map(articles, &serialize_article/1)})
    end
  rescue
    ArgumentError ->
      conn
      |> put_status(:bad_request)
      |> json(%{error: %{message: "Invalid category", status: 400}})
  end

  defp serialize_article(article) do
    %{
      id: article.id,
      title: article.title,
      slug: article.slug,
      body: article.body,
      category: article.category,
      scope: article.scope,
      status: article.status,
      tags: article.tags,
      inserted_at: article.inserted_at,
      updated_at: article.updated_at
    }
  end
end
