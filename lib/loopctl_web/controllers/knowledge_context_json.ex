defmodule LoopctlWeb.KnowledgeContextJSON do
  @moduledoc """
  JSON rendering helpers for the knowledge context endpoint.

  Renders full article bodies with relevance, recency, and combined scores,
  plus one-hop linked article references (lightweight: id, title, category).
  """

  alias Loopctl.Llm.Remediation
  alias LoopctlWeb.Outcome

  @doc """
  Renders context results with full bodies and scores.

  `meta.outcome` (`LoopctlWeb.Outcome`) classifies the response uniformly with every
  other retrieval surface, so an empty context pack is distinguishable from one whose
  underlying search fell back to keyword-only.
  """
  def context(%{results: results, meta: meta}) do
    %{
      data: Enum.map(results, &render_result/1),
      meta: meta |> render_meta() |> Outcome.put_for(results)
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
    # `remediation`: a machine-readable, secret-free next-step when the degradation
    # is a MISSING embedding key, so an agent can enable semantic ranking without a
    # human. Mirrors the /knowledge/search response. Absent otherwise.
    |> maybe_put_remediation(Remediation.for_fallback_reason(meta[:fallback_reason]))
  end

  defp maybe_put_fallback(map, true), do: Map.put(map, :fallback, true)
  defp maybe_put_fallback(map, _), do: map

  defp maybe_put_fallback_reason(map, nil), do: map
  defp maybe_put_fallback_reason(map, reason), do: Map.put(map, :fallback_reason, reason)

  defp maybe_put_remediation(map, nil), do: map
  defp maybe_put_remediation(map, remediation), do: Map.put(map, :remediation, remediation)
end
