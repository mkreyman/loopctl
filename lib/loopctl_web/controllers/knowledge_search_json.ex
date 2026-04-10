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
    result[:final_score] || 0.0
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
    base = %{
      total_count: meta[:total_count] || meta.total_count,
      limit: meta[:limit] || meta.limit,
      offset: meta[:offset] || meta.offset
    }

    # Include fallback flag when present (combined mode falling back to keyword)
    case meta[:fallback] do
      true -> Map.put(base, :fallback, true)
      _ -> base
    end
  end
end
