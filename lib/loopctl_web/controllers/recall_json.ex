defmodule LoopctlWeb.RecallJSON do
  @moduledoc """
  JSON rendering for the merged recall endpoint (`POST /api/v1/recall`, #411 Gap 2).

  Serializes `Loopctl.Memory.recall_context/2`'s envelope: the merged, re-ranked
  `results` (each tagged `source: "memory" | "knowledge"`) PLUS the untouched
  per-source `memory` and `knowledge` envelopes so a caller can re-rank without a
  second round-trip.

  - A `:memory` merged item pairs its long-term `%Memory{}` (rendered via
    `MemoryJSON.memory_data/1`, so the raw embedding is never leaked) with its cosine
    similarity `score` (`null` on the memory ILIKE fallback path).
  - A `:knowledge` merged item carries the article SUMMARY — projected through
    `KnowledgeSearchJSON.render_result/2` (the canonical combined-search view:
    `{id, title, category, tags, score, snippet}` truncated), the EXACT shape the
    knowledge search endpoints serialize — plus its pool-normalized combined `score`.
    Internal scoring fields (`relevance_score`/`normalized_score`/`final_score`),
    `status`, `tenant_id`, `project_id`, and timestamps are intentionally NOT exposed
    here, matching those endpoints.

  Cross-source `score`s are heuristically comparable, not calibrated (see the context
  function's `@doc`); `meta.results_ranking` carries the `"heuristic_cross_source"`
  tag so consumers can detect this programmatically.
  """

  alias LoopctlWeb.{KnowledgeSearchJSON, MemoryJSON}

  @doc """
  Renders the merged recall: `data` (merged, re-ranked), `memory` + `knowledge`
  (per-source envelopes), and `meta` (counts + degraded flag).
  """
  def context(%{results: results, memory: memory, knowledge: knowledge, meta: meta}) do
    %{
      data: Enum.map(results, &merged_item/1),
      memory: MemoryJSON.recall(memory),
      knowledge: %{data: Enum.map(knowledge.results, &knowledge_summary/1), meta: knowledge.meta},
      meta: meta_json(meta)
    }
  end

  defp merged_item(%{source: :memory, score: score, memory: memory}) do
    %{source: "memory", score: score, memory: MemoryJSON.memory_data(memory)}
  end

  defp merged_item(%{source: :knowledge, score: score, article: article}) do
    %{source: "knowledge", score: score, article: knowledge_summary(article)}
  end

  # Project a raw `search_combined/3` result map through the canonical combined-search
  # summary view so /recall emits the SAME whitelisted shape ({id, title, category,
  # tags, score, snippet}) the knowledge search endpoints do — never the raw map with
  # its internal scoring fields, status, tenant_id, project_id, and timestamps.
  defp knowledge_summary(result), do: KnowledgeSearchJSON.render_result(result, "combined")

  # `degraded?` (atom key with a trailing `?`) is the internal flag; expose it as the
  # clean JSON key `degraded`.
  defp meta_json(meta) do
    %{
      query: meta.query,
      project_id: meta.project_id,
      total_count: meta.total_count,
      memory_count: meta.memory_count,
      knowledge_count: meta.knowledge_count,
      degraded: meta.degraded?,
      # Stable tag warning that the merged `data` order is a cross-source heuristic
      # (memory absolute cosine vs knowledge pool-normalized), NOT calibrated relevance.
      results_ranking: meta.results_ranking
    }
  end
end
