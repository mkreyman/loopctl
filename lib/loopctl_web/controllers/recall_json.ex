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

  ## The selection ledger

  Every merged `data` item additionally carries `rank` (1-based, POST-merge),
  `selection_reason` (a bounded tag naming which lane put the row here) and
  `tokens_estimate`, and the top-level `meta` carries the call-level accounting
  (`recall_id`, `candidates_considered`, `selected_count`, `tokens_selected`,
  `tokens_candidates`, `tokens_saved_vs_candidates`). All of it is built by
  `Loopctl.Memory.recall_context/2` — see that function's `@doc` for what each field
  means and why `tokens_estimate` is an estimate. This module only renders it.

  The ledger lives in its OWN builder (`ledger_meta/1`, merged into `meta` by `context/1`)
  rather than inside `meta_json/1`, so two independent additions to this payload do not
  collide in one function body.

  The knowledge envelope's `meta` is ALSO projected — through
  `KnowledgeSearchJSON.render_meta/1`, the same whitelist the standalone knowledge
  endpoints use — so both results AND meta match that shape. The raw context meta's
  internal `error` reason atom is never passed through; only the bounded `fallback_reason`
  tag survives (plus the merged-recall `degraded` flag). The top-level `meta` adds
  `degraded_reason`, a bounded tag naming why a half degraded (or `null`).
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
      knowledge: %{
        data: Enum.map(knowledge.results, &knowledge_summary/1),
        meta: knowledge_meta(knowledge.meta)
      },
      # `meta_json/1` renders the ORIGINAL merged-recall meta; `ledger_meta/1` renders the
      # selection ledger. Kept as two builders merged here on purpose — see the moduledoc.
      meta: Map.merge(meta_json(meta), ledger_meta(meta))
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

  defp merged_item(%{source: :memory, score: score, memory: memory} = item) do
    %{source: "memory", score: score, memory: MemoryJSON.memory_data(memory)}
    |> Map.merge(ledger_item(item))
  end

  defp merged_item(%{source: :knowledge, score: score, article: article} = item) do
    %{source: "knowledge", score: score, article: knowledge_summary(article)}
    |> Map.merge(ledger_item(item))
  end

  # The per-item half of the selection ledger. `rank` is the position in THIS merged list
  # (not the per-source rank), `selection_reason` names the lane that put the row here, and
  # `tokens_estimate` is bytes/4 of the text a client would paste — an estimate by
  # construction, never a tokenizer count.
  defp ledger_item(item) do
    %{
      rank: item.rank,
      selection_reason: item.selection_reason,
      tokens_estimate: item.tokens_estimate
    }
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
      # Stable tag warning that the merged `data` order is a cross-source heuristic
      # (memory absolute cosine vs knowledge pool-normalized), NOT calibrated relevance.
      results_ranking: meta.results_ranking
    }
  end

  # The call-level half of the selection ledger, merged into `meta` by `context/1`.
  #
  # `recall_id` is the id of this recall AND the `search_id` stamped on the knowledge half's
  # surfacing rows in `article_access_events` — one value, not two that have to be joined —
  # so a client can hand it straight back to `POST /api/v1/recall/:recall_id/referenced` to
  # record which of the surfaced articles it actually used.
  #
  # The token figures are ESTIMATES (bytes/4 of the rendered text), published so a caller can
  # see what the merged cap did NOT hand it: `tokens_saved_vs_candidates` is zero when the cap
  # bound nothing.
  defp ledger_meta(meta) do
    %{
      recall_id: meta.recall_id,
      candidates_considered: meta.candidates_considered,
      selected_count: meta.selected_count,
      tokens_selected: meta.tokens_selected,
      tokens_candidates: meta.tokens_candidates,
      tokens_saved_vs_candidates: meta.tokens_saved_vs_candidates
    }
  end
end
