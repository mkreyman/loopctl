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
      meta: %{
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
    # `pool_capped` (semantic relevance mode, US-27.7a): true when the ranked corpus
    # exceeds the relevance pool cap, so the tail is unreachable by deeper `offset` —
    # the consumer should switch to list mode for full enumeration.
    |> maybe_put(:pool_capped, meta[:pool_capped])
    # `fallback_reason` (#297): a stable, non-sensitive tag naming WHY combined/semantic
    # degraded to keyword_only (present only alongside `fallback: true`).
    |> maybe_put(:fallback_reason, meta[:fallback_reason])
    # `semantic_result_count` (#297): rows the semantic half contributed in combined
    # mode. `0` with no `fallback` = "embed worked but recall is broken" — distinct
    # from a keyword_only fallback.
    |> maybe_put(:semantic_result_count, meta[:semantic_result_count])
    |> maybe_put_fallback(meta[:fallback])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_fallback(map, true), do: Map.put(map, :fallback, true)
  defp maybe_put_fallback(map, _), do: map
end
