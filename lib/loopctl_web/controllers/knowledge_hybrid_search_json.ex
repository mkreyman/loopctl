defmodule LoopctlWeb.KnowledgeHybridSearchJSON do
  @moduledoc """
  JSON rendering for the hybrid knowledge retrieval endpoint (US-31.4).

  Hybrid results come from the same combined keyword+semantic pool as
  `GET /knowledge/search` (combined mode), so result rows carry the same fields
  (`:final_score`/`:relevance_score`/`:similarity_score`, `:snippet`) and are
  rendered identically — a unified `score` plus a truncated (<= 300 char)
  snippet, never the full body.

  The DISTINGUISHING payload is `meta`: provenance MUST survive to the wire
  (AC-31.4.3). The atom `:curated`/`:retrieved` is stringified so a curated
  answer is flagged `"curated"` and a retrieved answer `"retrieved"` at the
  transport boundary, alongside `confidence` and `curated_article_id`. All the
  underlying combined-search meta (search_mode, fallback, fallback_reason,
  total_count, etc.) is preserved.
  """

  alias Loopctl.Llm.Remediation

  @max_snippet_length 300

  @doc "Renders hybrid results (unified score + snippet) with provenance-bearing meta."
  def hybrid_search(%{results: results, meta: meta}) do
    %{
      data: Enum.map(results, &render_result/1),
      meta: render_meta(meta)
    }
  end

  defp render_result(result) do
    base = %{
      id: result[:id] || result.id,
      title: result[:title] || result.title,
      category: to_string(result[:category] || result.category),
      tags: result[:tags] || result.tags || [],
      score: extract_score(result)
    }

    maybe_add_snippet(base, result)
  end

  # Hybrid runs the combined pool, so results carry :final_score; a keyword-only
  # fallback carries :relevance_score instead — fall back rather than report a
  # misleading 0.0.
  #
  # Post-#470 :final_score is a Reciprocal Rank Fusion weight (`Σ weight/(k+rank)`, top
  # ~0.008-0.016), NOT a 0..1 similarity — this per-result `score` reflects RANK only.
  # The ABSOLUTE 0..1 confidence a caller should threshold on is `meta.confidence` (the
  # provenance decision's `absolute_score/1`), not this field.
  defp extract_score(result) do
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

  # Provenance is the load-bearing field (AC-31.4.3): the atom is stringified so
  # `curated` stays curated and `retrieved` stays retrieved at the MCP/HTTP
  # boundary. `curated_article_id` is always present (null for :retrieved).
  defp render_meta(meta) do
    %{
      provenance: to_string(meta.provenance),
      confidence: meta.confidence,
      curated_article_id: meta[:curated_article_id],
      limit: meta[:limit],
      offset: meta[:offset]
    }
    |> maybe_put(:total_count, meta[:total_count])
    |> maybe_put(:total_count_scope, meta[:total_count_scope])
    |> maybe_put(:search_mode, meta[:search_mode])
    |> maybe_put(:fallback_reason, meta[:fallback_reason])
    # `remediation`: mirror knowledge_search — when the degradation is a MISSING
    # embedding key (`fallback_reason == "no_embedding_key"`), attach the
    # machine-readable, secret-free next-step (names the `set_llm_config` MCP tool
    # + REST endpoint) so the MCP wrapper's `withRemediationNotice` surfaces the
    # same "ACTION REQUIRED — configure LLM key" banner it does for knowledge_search.
    # Render-time computation: `search_combined` never puts it on pool_meta.
    # Absent for transient/provider fallbacks (a key IS configured there).
    |> maybe_put(:remediation, Remediation.for_fallback_reason(meta[:fallback_reason]))
    |> maybe_put(:semantic_result_count, meta[:semantic_result_count])
    |> maybe_put_fallback(meta[:fallback])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_fallback(map, true), do: Map.put(map, :fallback, true)
  defp maybe_put_fallback(map, _), do: map
end
