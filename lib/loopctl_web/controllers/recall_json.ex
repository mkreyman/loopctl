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

  The knowledge envelope's `meta` is ALSO projected — through
  `KnowledgeSearchJSON.render_meta/1`, the same whitelist the standalone knowledge
  endpoints use — so both results AND meta match that shape. The raw context meta's
  internal `error` reason atom is never passed through; only the bounded `fallback_reason`
  tag survives (plus the merged-recall `degraded` flag). The top-level `meta` adds
  `degraded_reason`, a bounded tag naming why a half degraded (or `null`).
  """

  alias LoopctlWeb.{KnowledgeSearchJSON, MemoryJSON, Outcome}

  @doc """
  Renders the merged recall: `data` (merged, re-ranked), `memory` + `knowledge`
  (per-source envelopes), and `meta` (counts + degraded flag).
  """
  def context(%{results: results, memory: memory, knowledge: knowledge, meta: meta}) do
    %{
      data: Enum.map(results, &merged_item/1),
      memory: MemoryJSON.recall(memory),
      knowledge: %{
        data: Enum.map(knowledge.results, &knowledge_summary/1),
        meta: knowledge_meta(knowledge.meta)
      },
      meta: meta_json(meta)
    }
  end

  # Project the knowledge envelope meta through the SAME `KnowledgeSearchJSON.render_meta`
  # whitelist the standalone knowledge search endpoints use, then re-attach the merged-
  # recall `degraded` flag. This keeps the moduledoc's promise (the knowledge side is the
  # EXACT shape the knowledge search endpoints serialize) for META as well as results:
  # the raw context meta's internal `error` reason atom (an internal capacity/validation
  # signal `/knowledge/search` would strip) is NEVER passed through — only the bounded
  # `fallback_reason` tag survives, exactly as on `/knowledge/search`.
  defp knowledge_meta(meta) do
    meta
    |> KnowledgeSearchJSON.render_meta()
    |> Map.put(:degraded, Map.get(meta, :degraded?, false))
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
      # A bounded, non-sensitive tag naming WHY the merged recall degraded (or `null`),
      # so a caller can distinguish a scope-empty half from a fault-empty one.
      degraded_reason: meta.degraded_reason,
      # The lane the REPORTED half served in place of the ranking asked for
      # (`"keyword_only"`), or `null` when it served nothing. Without it a knowledge shed
      # that DID answer keyword-only was indistinguishable from a memory shed that
      # answered nothing — same tag, opposite remedies — and `Outcome` prescribed a wait
      # for a lane that had already run.
      search_mode: meta.search_mode,
      # Stable tag warning that the merged `data` order is a cross-source heuristic
      # (memory absolute cosine vs knowledge pool-normalized), NOT calibrated relevance.
      results_ranking: meta.results_ranking
    }
    # The uniform tool-outcome classification (`LoopctlWeb.Outcome`), derived from the
    # keys immediately above and the MERGED `total_count` — so it describes the whole
    # endpoint, which is what a caller reading the top-level meta is asking about. It is
    # deliberately the only place `outcome` is added on this response: the per-source
    # `memory` envelope carries its own via `MemoryJSON.recall/1`, while the `knowledge`
    # envelope's meta goes through the shared `KnowledgeSearchJSON.render_meta/1`
    # whitelist, which is a meta-only projection with no result count to classify from.
    |> Outcome.put(meta.total_count)
  end
end
