defmodule LoopctlWeb.Outcome do
  @moduledoc """
  ONE derivation of `meta.outcome` — the uniform tool-outcome envelope EVERY read on the
  knowledge, memory and corpus surfaces carries: the retrieval responses, the enumeration
  paths (`knowledge_list`, `knowledge_index`, `memory_list`, `corpus_list`), the review
  queues (drafts, conflicts) and the link-suggestion read.

  The catalog and queue endpoints were once excluded on the ground that they disclose no
  degradation of their own, so their `outcome` can only ever be `"empty"` or `"success"`.
  That is still true of the VALUE and it was the wrong call about the KEY. A client cannot
  read a per-endpoint opt-out: an absent `outcome` means "this endpoint declined to
  classify" and "this server predates the envelope" at the same time, and the client has
  no way to tell them apart — `mcp-server`'s `outcomeOf` collapses both to `null` and
  falls back to the pre-envelope flag heuristics. Uniformity is the whole product here, so
  the key is present on every read and absence has exactly one meaning: an old server.

  The idea is borrowed from MemoRizz v0.8.0 (RichmondAlake), whose every tool
  execution returns a content-free outcome so an agent never has to parse prose to
  tell a healthy result from a broken one. loopctl already did this for ONE surface
  and ONE failure (`meta.fallback` / `meta.fallback_reason` on knowledge search);
  this module generalises it to every retrieval response.

  ## The failure it closes

  A zero-result response is ambiguous, and the ambiguity is expensive. An empty
  `data: []` from a healthy query means "the corpus does not hold this"; the same
  `data: []` from a shed heavy read or a dead embedding lane means "ask again".
  Agents read both as the first one — measured on real session transcripts, every
  degraded response that came back empty was treated by the receiving agent as "the
  knowledge base has nothing". The signals that told them otherwise were already in
  `meta`, spread across `fallback`, `fallback_reason`, `degraded`, `reason`,
  `semantic_unavailable_reason` and `semantic_under_filled`, with different key names
  per surface. `outcome` is the ONE key that means the same thing everywhere.

  ## The vocabulary

  | outcome | what happened | what the caller should do |
  |---|---|---|
  | `"success"` | ran fully; this page carries rows, or an earlier one did | use them |
  | `"empty"` | ran fully and the whole matched set is empty | a real miss — re-route or accept it |
  | `"degraded"` | a half was shed, capacity-limited or scan-starved | this set may be SHORT; wait, then retry — except a STANDING gap (`ann_iterative_scan_unavailable`, `embedding_dimension_mismatch`), which only an operator clears |
  | `"fallback"` | the semantic lane was unavailable, keyword-only was served | retry the SAME query, never reword |
  | `"error"` | the retrieval could not run; an empty envelope was served in its place | fix the request, then retry |

  ## Precedence

  `error > fallback > degraded > empty > success`. Several causes can be present at
  once (a degraded response usually also has zero results), and the strongest wins.
  `"error"` additionally requires ZERO rows, because it claims an empty envelope was
  served in the retrieval's place: on `/recall` the tag names one HALF, and beside rows
  the other half returned it is a partial read (`"degraded"`), not a dead request.

  There is exactly ONE deviation from that order, and it is deliberate: a CAPACITY
  SHED (reason `heavy_read_overloaded`) that served NO SUBSTITUTE LANE is classified
  `"degraded"` BEFORE the `fallback` flag is consulted. It has to be, because the memory
  tier's shed envelope sets `fallback: true` while serving nothing at all. The flag names
  the transport; the REASON names the remedy, and capacity's remedy is to WAIT, which is
  not the remedy for a broken embedding lane. An agent that reads a shed as `"fallback"`
  retries immediately into the same closed gate.

  The "served no substitute lane" half is load-bearing: the KNOWLEDGE tier sheds under the
  same tag and DOES serve keyword-only (`search_mode: "keyword_only"`), whose remedy is the
  fallback one — retry the same query, never reword, because the keyword lane ANDs its
  terms. The merged `/recall` meta republishes that `search_mode` for the half whose tag it
  reports (`nil` when that half served nothing), so the same event classifies the same way
  there. Every other signal is consulted AFTER `fallback`, exactly as the order says.

  ## Write paths get nothing

  `outcome` answers "can I trust this empty result set", which is a question only a
  read has. A create/update/delete already answers with its status code and its body.
  """

  # The FULL bounded tag set `Loopctl.Memory`'s degraded knowledge envelope emits when
  # `Knowledge.search_combined/3` returns a hard `{:error, _}` — the request could not
  # run and `/recall` served an empty knowledge half in its place. Read from the module
  # that PRODUCES the tags so the two cannot drift.
  @request_error_reasons Loopctl.Memory.knowledge_degraded_reason_tags()

  # The per-tenant in-flight HeavyRead cap shedding a read. A string literal because the
  # producers are string literals too (`Loopctl.Memory.overloaded_memory_env/2`,
  # `Knowledge.reason_to_tag/1`); there is no shared constant to read it from.
  @capacity_reason "heavy_read_overloaded"

  # The memory tier's "the read did not run and nothing was served in its place" tags, read
  # from the module that PRODUCES them. They arrive under `:reason` (and, on the merged
  # `/recall` meta, `:degraded_reason`), never the knowledge tier's `:fallback_reason`.
  @memory_unavailable_reasons Loopctl.Memory.memory_unavailable_reason_tags()

  @outcomes ~w(success empty degraded fallback error)

  @doc "Every value `derive/2` can return, for OpenAPI enums and for tests."
  @spec values() :: [String.t()]
  def values, do: @outcomes

  @doc """
  The OpenAPI schema for the `meta.outcome` property.

  Published from the SAME `@outcomes` list `derive/2` can return, so the documented
  enum and the rendered values cannot drift. Every retrieval `operation/2` that
  documents a `meta` object embeds this rather than restating the enum.
  """
  @spec schema() :: OpenApiSpex.Schema.t()
  def schema do
    %OpenApiSpex.Schema{
      type: :string,
      enum: @outcomes,
      description:
        "Uniform tool outcome. success = ran fully with rows; empty = ran fully, a " <>
          "genuine miss; degraded = a half was shed or capacity-limited, so this set " <>
          "may be short; fallback = semantic ranking was unavailable and keyword-only " <>
          "was served, so retry the SAME query rather than rewording; error = the " <>
          "retrieval could not run and an empty envelope was served in its place."
    }
  end

  @doc """
  Classifies one response from its `meta` and its RESULT COUNT.

  `meta` is the response meta as the view is about to render it (atom keys, the same
  map the endpoint returns); `count` is the number of rows in `data`. Any key this
  module reads may be absent — a surface that discloses nothing about degradation
  simply resolves to `"empty"` or `"success"`.
  """
  @spec derive(map(), non_neg_integer()) :: String.t()
  def derive(meta, count) when is_map(meta) and is_integer(count) and count >= 0 do
    cond do
      unrunnable?(meta) -> unrunnable_outcome(count)
      capacity_shed?(meta) -> "degraded"
      lane_fallback?(meta) -> "fallback"
      short_lane?(meta) -> "degraded"
      matched_nothing?(meta, count) -> "empty"
      true -> "success"
    end
  end

  @doc """
  `derive/2`, written into `meta` under `:outcome`.

  The one call a view makes. Returns the meta map unchanged apart from the added key,
  so it composes onto whatever whitelist the view already built.
  """
  @spec put(map(), non_neg_integer()) :: map()
  def put(meta, count) when is_map(meta), do: Map.put(meta, :outcome, derive(meta, count))

  @doc """
  `put/2` over a list, for the common `%{data: rows, meta: meta}` shape.

  Saves every call site from writing `length(rows)` twice.
  """
  @spec put_for(map(), list()) :: map()
  def put_for(meta, results) when is_map(meta) and is_list(results),
    do: put(meta, length(results))

  # The request itself could not run. These are `search_combined/3`'s complete
  # hard-error contract, and an endpoint that hits one serves an empty envelope rather
  # than a partial answer.
  #
  # Read from only the TWO keys that carry that contract — the knowledge envelope's
  # `fallback_reason` (written by `Memory.degraded_knowledge_env/3`) and the merged
  # `/recall` meta's `degraded_reason` (which copies it). The corpus and memory lanes
  # publish their own tags into `reason`/`semantic_unavailable_reason`, drawn from an
  # embedding/capacity vocabulary that does not overlap this one today; matching
  # against them anyway would make a future tag collision silently reclassify a served
  # half as a request that never ran.
  #
  # The MEMORY tier's own unrunnable envelope is matched here too, on ITS keys: it sets
  # `fallback: true` with zero rows and no text-match lane, so reading the flag alone
  # classified a persistent configuration fault as `"fallback"` and told the agent to
  # retry the identical query forever.
  defp unrunnable?(meta) do
    Enum.any?([meta[:fallback_reason], meta[:degraded_reason]], &(&1 in @request_error_reasons)) or
      Enum.any?([meta[:reason], meta[:degraded_reason]], &(&1 in @memory_unavailable_reasons))
  end

  # `"error"` says an EMPTY envelope was served in place of the retrieval. On the merged
  # `/recall` the tag names ONE HALF, so the same tag can arrive beside real rows the other
  # half returned — and a caller told "THE RETRIEVAL DID NOT RUN" discards them. Rows
  # present, that is a partial read, which is what `"degraded"` means.
  defp unrunnable_outcome(0), do: "error"
  defp unrunnable_outcome(_count), do: "degraded"

  # Capacity, not correctness — and the ONE signal read ahead of `fallback` (see the
  # moduledoc's precedence note). A shed that served no substitute lane leaves the caller
  # nothing, so the remedy is to WAIT rather than to retry a different ranking. A shed the
  # KNOWLEDGE tier answered with keyword-only is NOT this case: it declares the lane it
  # served under `search_mode`, and its remedy is the fallback one.
  defp capacity_shed?(meta),
    do: @capacity_reason in reasons(meta) and meta[:search_mode] != "keyword_only"

  # The documented fallback: semantic ranking was unavailable and a keyword/text-match
  # lane was served in its place. `fallback` is the knowledge/memory flag; `degraded` is
  # the US-41.4 label and the merged-recall flag (`degraded?` is its internal spelling,
  # accepted here so an unprojected envelope classifies the same way a projected one
  # does); `semantic_unavailable_reason` is the corpus tier's name for the same event
  # (on a 200 it always means the OTHER lane answered, since every attempted lane
  # failing is a 502).
  defp lane_fallback?(meta) do
    meta[:fallback] == true or meta[:degraded] == true or meta[:degraded?] == true or
      present?(meta[:semantic_unavailable_reason])
  end

  # A lane RAN but could not reach the whole corpus, or a non-semantic lane dropped out.
  # Nothing was substituted for the ranking the caller asked for, so this is not the
  # fallback case, but the result set is a half and must not read as a complete miss.
  #
  # - `semantic_under_filled` — the corpus semantic lane returned a partial set.
  # - `ann_iterative_scan: "unavailable"` — the vector read ran WITHOUT pgvector's
  #   iterative scan while the operator had enabled it, so the tenant filter was applied
  #   after a single index batch and the page may be incomplete.
  # - `keyword_unavailable_reason` — the corpus keyword lane dropped out.
  defp short_lane?(meta) do
    meta[:semantic_under_filled] == true or
      meta[:ann_iterative_scan] == "unavailable" or
      present?(meta[:keyword_unavailable_reason])
  end

  # Every key on every surface that carries a bounded degradation tag. Collected into one
  # list so the classification reads a REASON, not a key name, and a surface that renames
  # its key changes one line here rather than the rules.
  defp reasons(meta) do
    [
      meta[:fallback_reason],
      meta[:degraded_reason],
      meta[:reason],
      meta[:semantic_unavailable_reason],
      meta[:keyword_unavailable_reason]
    ]
    |> Enum.filter(&is_binary/1)
  end

  # A REAL miss: no rows, and not merely a page walked past the end. `count` is the PAGE,
  # so an empty page over a non-empty set told an agent doing an existence check the row is
  # absent while `total_count` beside it said otherwise.
  #
  # `offset > 0` is the discriminator, MINUS the one case it gets wrong: a NONZERO
  # `total_count` cannot bound the matched set (in relevance mode it counts a pool,
  # `total_count_scope`), but a `total_count` of EXACTLY 0 can — nothing matched, so no
  # earlier page carried rows either and this is a genuine miss however deep the offset.
  # An ABSENT `total_count` (the hybrid meta only `maybe_put`s it) stays exhaustion, which
  # is the safe read: it claims a set exists rather than claiming absence.
  defp matched_nothing?(meta, count), do: count == 0 and not past_end?(meta)

  defp past_end?(meta),
    do: is_integer(meta[:offset]) and meta[:offset] > 0 and meta[:total_count] != 0

  defp present?(value), do: is_binary(value) and value != ""
end
