defmodule LoopctlWeb.ArticleLinkJSON do
  @moduledoc """
  JSON rendering helpers for article link API responses.

  Provides consistent serialization for article links across
  all article link controller actions.
  """

  @doc "Renders a newly created article link."
  def create(%{link: link}), do: %{data: link_data(link)}

  @doc "Renders a list of article links with preloaded articles."
  def index(%{links: links}), do: %{data: Enum.map(links, &link_data_with_article/1)}

  defp link_data(link) do
    %{
      id: link.id,
      source_article_id: link.source_article_id,
      target_article_id: link.target_article_id,
      relationship_type: link.relationship_type,
      metadata: link.metadata,
      inserted_at: link.inserted_at
    }
  end

  defp link_data_with_article(link) do
    link_data(link)
    |> Map.put(:source_article, article_ref(link.source_article))
    |> Map.put(:target_article, article_ref(link.target_article))
  end

  defp article_ref(%Ecto.Association.NotLoaded{}), do: nil
  defp article_ref(%{id: id, title: title}), do: %{id: id, title: title}
  defp article_ref(_), do: nil
end
