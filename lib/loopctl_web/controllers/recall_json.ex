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
  - A `:knowledge` merged item carries the `search_combined/3` result map (article
    summary + scores — the same shape the knowledge search endpoints return) and its
    pool-normalized combined `score`.

  Cross-source `score`s are heuristically comparable, not calibrated (see the context
  function's `@doc`).
  """

  alias LoopctlWeb.MemoryJSON

  @doc """
  Renders the merged recall: `data` (merged, re-ranked), `memory` + `knowledge`
  (per-source envelopes), and `meta` (counts + degraded flag).
  """
  def context(%{results: results, memory: memory, knowledge: knowledge, meta: meta}) do
    %{
      data: Enum.map(results, &merged_item/1),
      memory: MemoryJSON.recall(memory),
      knowledge: %{data: knowledge.results, meta: knowledge.meta},
      meta: meta_json(meta)
    }
  end

  defp merged_item(%{source: :memory, score: score, memory: memory}) do
    %{source: "memory", score: score, memory: MemoryJSON.memory_data(memory)}
  end

  defp merged_item(%{source: :knowledge, score: score, article: article}) do
    %{source: "knowledge", score: score, article: article}
  end

  # `degraded?` (atom key with a trailing `?`) is the internal flag; expose it as the
  # clean JSON key `degraded`.
  defp meta_json(meta) do
    %{
      query: meta.query,
      project_id: meta.project_id,
      total_count: meta.total_count,
      memory_count: meta.memory_count,
      knowledge_count: meta.knowledge_count,
      degraded: meta.degraded?
    }
  end
end
