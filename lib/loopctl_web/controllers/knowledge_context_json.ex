defmodule LoopctlWeb.KnowledgeContextJSON do
  @moduledoc """
  JSON rendering helpers for the knowledge context endpoint.

  Renders full article bodies with relevance, recency, and combined scores,
  plus one-hop linked article references (lightweight: id, title, category).
  """

  @doc "Renders context results with full bodies and scores."
  def context(%{results: results, meta: meta}) do
    %{
      data: Enum.map(results, &render_result/1),
      meta: render_meta(meta)
    }
  end

  defp render_result(result) do
    base = %{
      id: result.id,
      title: result.title,
      category: to_string(result.category),
      tags: result.tags || [],
      body: result.body,
      updated_at: result.updated_at,
      relevance_score: result.relevance_score,
      recency_score: result.recency_score,
      combined_score: result.combined_score
    }

    Map.put(base, :linked_articles, render_linked(result.linked_articles))
  end

  defp render_linked(nil), do: []

  defp render_linked(linked) do
    Enum.map(linked, fn article ->
      %{
        id: article.id,
        title: article.title,
        category: to_string(article.category)
      }
    end)
  end

  defp render_meta(meta) do
    base = %{
      total_count: meta.total_count,
      limit: meta.limit,
      recency_weight: meta.recency_weight
    }

    base
    |> maybe_put_fallback(meta[:fallback])
    # `fallback_reason` (#297): a stable, non-sensitive tag naming WHY the context's
    # underlying combined search degraded to keyword_only. Present only on fallback.
    |> maybe_put_fallback_reason(meta[:fallback_reason])
  end

  defp maybe_put_fallback(map, true), do: Map.put(map, :fallback, true)
  defp maybe_put_fallback(map, _), do: map

  defp maybe_put_fallback_reason(map, nil), do: map
  defp maybe_put_fallback_reason(map, reason), do: Map.put(map, :fallback_reason, reason)
end
