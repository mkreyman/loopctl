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

  alias Loopctl.Llm.Remediation
  alias LoopctlWeb.Outcome

  # One constant, shared with the backfill that PRODUCES snippets, so the produced length
  # and the enforced length cannot drift.
  @max_snippet_length Loopctl.Knowledge.max_snippet_length()

  @doc """
  Renders search results with unified score field and truncated snippets.

  `meta.outcome` classifies the whole response (`LoopctlWeb.Outcome`), so a caller
  can tell a healthy empty result set from a keyword-only fallback or a shed read
  without reading five different degradation keys.
  """
  def search(%{results: results, meta: meta}, mode) do
    %{
      data: Enum.map(results, &render_result(&1, mode)),
      # `outcome` is derived from the WHITELISTED meta, not the raw context meta, so the
      # classification can only read keys the caller also receives — no verdict an agent
      # cannot re-derive from what it was sent.
      meta: meta |> render_meta() |> Outcome.put_for(results)
    }
  end

  @doc """
  Renders a KEYSET (cursor) list page (US-27.9a, US-27.10).

  Unlike `search/2`, the keyset list path carries no relevance score/snippet, and
  its `meta` fully documents the cursor contract (US-27.10) so an agent can drive
  pagination purely from the response:

  - `next_cursor` — the opaque, already-encoded cursor for the next page, or
    `null` when the walk is exhausted (the only exhaustion signal — there is no
    total_count to drift).
  - `has_more` — boolean, derived from the keyset peek (exactly `next_cursor != null`),
    never a COUNT.
  - `limit` — the effective per-page limit that actually ran.
  - `count` — the number of rows in THIS page (`length(data)`).
  - `include_body` — whether each row carries the article `body` (US-27.10).
  - `byte_truncated` — whether the page was shortened by the serialized-body byte
    budget (US-27.10). Only ever `true` when `include_body` is `true`.
  - `outcome` — the uniform tool-outcome envelope (`LoopctlWeb.Outcome`). A keyset
    page discloses no degradation, so it is only ever `"empty"` or `"success"` —
    which is exactly the value of having the key here: an empty page on this path
    is ALWAYS a real exhaustion, and the caller learns that without a special case.

  When `include_body: true`, the CONTEXT (`Loopctl.Knowledge.list_keyset/2`) has
  already trimmed the page to `full_content_byte_budget/0` and recomputed
  `next_cursor`/`has_more` from the LAST KEPT row, so the walk resumes over the
  dropped rows with no gap. This view does NOT trim — it renders exactly what the
  context returns and surfaces `byte_truncated` from the context.

  `next_cursor` is encoded by the controller (it needs the tenant key), so this
  view receives it as a ready string or `nil`.
  """
  def keyset(%{
        results: results,
        next_cursor: next_cursor,
        has_more: has_more,
        limit: limit,
        include_body: include_body,
        byte_truncated: byte_truncated
      }) do
    %{
      data: Enum.map(results, &render_list_row(&1, include_body)),
      meta:
        %{
          # The cursor walk is drift-free precisely BECAUSE it carries no
          # total_count to drift; `next_cursor: null` is the exhaustion signal.
          next_cursor: next_cursor,
          has_more: has_more,
          limit: limit,
          count: length(results),
          include_body: include_body,
          byte_truncated: byte_truncated,
          search_mode: "list_keyset"
        }
        |> Outcome.put_for(results)
    }
  end

  # Keyset rows always arrive as plain atom-keyed maps from `Knowledge.keyset_query/2`'s
  # `select` (every field present; `tags` is a non-null `{:array}` default `[]`), so
  # direct field access is correct — and a missing field SHOULD crash loudly rather than
  # silently degrade. (`render_result/1` keeps the dual accessor because search results
  # may be structs.) `body` is present ONLY when the query was run with
  # `include_body: true` (US-27.10); body-less (the default) carries no `body` key.
  defp render_list_row(result, include_body) do
    base = %{
      id: result.id,
      title: result.title,
      category: to_string(result.category),
      tags: result.tags
    }

    if include_body, do: Map.put(base, :body, result.body), else: base
  end

  @doc """
  Projects a single search result map into the canonical whitelisted summary shape
  (`{id, title, category, tags, score}` plus a truncated `snippet` when present) for
  the given `mode` (`"keyword" | "semantic" | "combined"`).

  Shared with `LoopctlWeb.RecallJSON` so the merged `/recall` endpoint emits the same
  shape as the knowledge search endpoints and never leaks raw internal result fields.
  """
  def render_result(result, mode) do
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
    #
    # SCORE MAGNITUDE (post-#470): combined :final_score is now a Reciprocal Rank Fusion
    # value — `Σ weight/(k+rank)`, so the top hit is ~0.008-0.016 (with k=60), NOT a
    # normalized 0..1 similarity. Result ORDER is unchanged (still a pure sort by this
    # score, higher = more relevant), so ranking/sort-by-score clients are unaffected; but
    # any client that THRESHOLDS on or displays the absolute magnitude must treat `score`
    # as an un-normalized relative rank weight, not a 0..1 confidence. Use
    # knowledge_hybrid_search's `meta.confidence` (absolute) when a 0..1 signal is needed.
    result[:final_score] || result[:relevance_score] || result[:similarity_score] || 0.0
  end

  # Every result that can carry a snippet now does: a `ts_headline` highlight when the
  # KEYWORD lane matched, and a lead extract of the body when it did not. Before the
  # backfill the key was simply absent on semantic-only hits — so the rows the query did
  # NOT lexically match, which is exactly what the semantic lane exists to find, were the
  # ones with nothing to explain them.
  #
  # `snippet_source` is reported because the two read very differently and a consumer may
  # want to render them differently: a highlight carries `**term**` markers and can open
  # mid-sentence, while a lead is the article's own opening prose. Absent when there is no
  # snippet at all, so it never implies one.
  defp maybe_add_snippet(base, result) do
    case result[:snippet] do
      nil ->
        base

      snippet ->
        base
        |> Map.put(:snippet, truncate_snippet(snippet))
        |> Map.put(:snippet_source, result[:snippet_source] || "highlight")
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

  @doc """
  Projects a `search_combined/3` / `search/3` result `meta` through the canonical
  whitelist used by the knowledge search endpoints.

  Shared with `LoopctlWeb.RecallJSON` (the merged `/recall` endpoint) so its knowledge
  envelope emits the SAME whitelisted meta shape — never the raw context meta with any
  internal reason atom. Requires `:total_count`, `:limit`, and `:offset` on `meta` (both
  the healthy `search_combined/3` meta and the merged endpoint's degraded stub carry
  them); the remaining keys are optional and emitted only when present.
  """
  def render_meta(meta) do
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
    # `pool_capped` (semantic relevance mode, US-27.7a): true when the ranked corpus
    # exceeds the relevance pool cap, so the tail is unreachable by deeper `offset` —
    # the consumer should switch to list mode for full enumeration.
    |> maybe_put(:pool_capped, meta[:pool_capped])
    # `ann_iterative_scan` (relevance modes): whether the vector read ran with
    # `hnsw.iterative_scan`. `"unavailable"` means the operator enabled it but the read ran
    # without it, so the cross-tenant residual filter may have under-returned — disclosed
    # rather than left as a short result set the caller reads as an empty corpus. It covers
    # TWO causes with DIFFERENT operator actions (an inconclusive probe, which self-heals,
    # vs a pgvector that conclusively lacks the GUC, which stands until the extension is
    # upgraded); `ann_iterative_scan_reason` accompanies that state only and names which.
    |> maybe_put(:ann_iterative_scan, meta[:ann_iterative_scan])
    |> maybe_put(:ann_iterative_scan_reason, meta[:ann_iterative_scan_reason])
    # `fallback_reason` (#297): a stable, non-sensitive tag naming WHY combined/semantic
    # degraded to keyword_only (present only alongside `fallback: true`).
    |> maybe_put(:fallback_reason, meta[:fallback_reason])
    # `remediation`: when the degradation is a MISSING embedding key
    # (`fallback_reason == "no_embedding_key"`), attach a machine-readable,
    # secret-free next-step so the agent can enable semantic ranking WITHOUT a
    # human — naming the `set_llm_config` MCP tool + the REST endpoint. Absent for
    # transient/provider fallbacks (a key IS configured there, so "configure a key"
    # would be wrong).
    |> maybe_put(:remediation, Remediation.for_fallback_reason(meta[:fallback_reason]))
    # The curated-vs-retrieved decision (#670). It is made on the DEFAULT path now, not
    # only inside hybrid search, so it has to reach the caller here or it is computed and
    # thrown away: the server recorded `combined_curated` while the response said nothing,
    # and an agent cannot branch on a verdict it never receives.
    #
    # Same three keys, same meanings, as `knowledge_hybrid_search` — `:curated` means a
    # governed article answered and is FIRST in `results` (and named by
    # `curated_article_id`); `:retrieved` means nothing curated cleared the bar and this is
    # the best semantic/keyword match. Deliberately NOT rendered as a bare pass-through of
    # the internal meta: this whitelist exists so an internal atom can never leak, and
    # these are three explicitly-chosen keys, not an exception to it.
    |> maybe_put(:provenance, meta[:provenance])
    |> maybe_put(:confidence, meta[:confidence])
    |> maybe_put(:curated_article_id, meta[:curated_article_id])
    # `semantic_result_count` (#297): rows the semantic half contributed in combined
    # mode. `0` with no `fallback` = "embed worked but recall is broken" — distinct
    # from a keyword_only fallback.
    |> maybe_put(:semantic_result_count, meta[:semantic_result_count])
    # US-41.4 (AC-41.4.7): the degraded response is EXPLICITLY LABELLED and never a
    # bare empty list. `degraded` says the semantic tier was unavailable,
    # `offending_endpoint` NAMES the endpoint the refusal/failure was about (an agent
    # cannot act on "egress_blocked" alone), and `excluded_tiers` is the reserved,
    # extensible field — present and EMPTY today, populated by US-41.6 when encrypted
    # bodies leave the FTS index. Shipping it now keeps the response contract stable
    # across that change instead of silently redefining an empty result set later.
    |> maybe_put(:degraded, meta[:degraded])
    |> maybe_put(:offending_endpoint, meta[:offending_endpoint])
    |> maybe_put(:excluded_tiers, meta[:excluded_tiers])
    |> maybe_put_fallback(meta[:fallback])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_fallback(map, true), do: Map.put(map, :fallback, true)
  defp maybe_put_fallback(map, _), do: map
end
