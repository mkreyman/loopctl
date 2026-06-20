defmodule LoopctlWeb.KnowledgeSearchJSON do
  @moduledoc """
  JSON rendering helpers for the knowledge search endpoint.

  Renders search results with a unified `score` field that maps to the
  appropriate score key based on search mode:

  - `keyword` -> `relevance_score`
  - `semantic` -> `similarity_score`
  - `combined` -> `final_score`

  Snippets are truncated to 300 characters maximum.
  Full article body is never included.
  """

  @max_snippet_length 300

  @doc "Renders search results with unified score field and truncated snippets."
  def search(%{results: results, meta: meta}, mode) do
    %{
      data: Enum.map(results, &render_result(&1, mode)),
      meta: render_meta(meta)
    }
  end

  defp render_result(result, mode) do
    base = %{
      id: result[:id] || result.id,
      title: result[:title] || result.title,
      category: to_string(result[:category] || result.category),
      tags: result[:tags] || result.tags || [],
      score: extract_score(result, mode)
    }

    maybe_add_snippet(base, result)
  end

  defp extract_score(result, "keyword") do
    result[:relevance_score] || 0.0
  end

  defp extract_score(result, "semantic") do
    result[:similarity_score] || 0.0
  end

  defp extract_score(result, "combined") do
    # Normal combined results carry :final_score; when combined degrades to a
    # keyword-only fallback the results carry :relevance_score instead, so fall
    # back to it (then similarity) rather than reporting a misleading 0.0.
    result[:final_score] || result[:relevance_score] || result[:similarity_score] || 0.0
  end

  defp maybe_add_snippet(base, result) do
    case result[:snippet] do
      nil -> base
      snippet -> Map.put(base, :snippet, truncate_snippet(snippet))
    end
  end

  defp truncate_snippet(snippet) when is_binary(snippet) do
    if String.length(snippet) > @max_snippet_length do
      snippet
      |> String.slice(0, @max_snippet_length)
      |> Kernel.<>("...")
    else
      snippet
    end
  end

  defp truncate_snippet(_), do: nil

  defp render_meta(meta) do
    %{
      total_count: meta[:total_count] || meta.total_count,
      limit: meta[:limit] || meta.limit,
      offset: meta[:offset] || meta.offset
    }
    # `total_count_scope` documents what `total_count` actually counts for this
    # mode (keyword_matches | ranked_corpus | merged_candidates | filtered_set),
    # so callers don't mistake it for a corpus total. `search_mode` reflects the
    # effective mode (e.g. keyword_only when combined fell back). `fallback` is
    # surfaced only when combined mode degraded to keyword-only.
    |> maybe_put(:total_count_scope, meta[:total_count_scope])
    |> maybe_put(:search_mode, meta[:search_mode])
    |> maybe_put_fallback(meta[:fallback])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_fallback(map, true), do: Map.put(map, :fallback, true)
  defp maybe_put_fallback(map, _), do: map
end
