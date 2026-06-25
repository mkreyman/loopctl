defmodule Loopctl.Knowledge.CosineLintExceptions do
  @moduledoc """
  The auditable allowlist of functions that legitimately hand-roll a cosine
  distance/ORDER BY **outside** the shared `Loopctl.Knowledge.VectorSearch` helper.

  ## Why this exists

  The shared `Loopctl.Knowledge.VectorSearch` module is the sanctioned home for top-k
  `ORDER BY embedding <=> $const LIMIT k` — its exact SQL shape is load-bearing (the
  #168/#170/#172 production 500s came from variations that defeated the HNSW index). US-27.8
  introduces a "no hand-rolled cosine ORDER BY/distance outside the helper" source-lint to
  prevent that shape from being reintroduced ad hoc.

  This registry is NOT a claim that no other `<=>` exists in the codebase — it is the
  auditable list of the TWO US-27.7b-owned exceptions (distant_pairs + novelty). The broader
  cosine-site inventory and the lint's full exemption policy are US-27.8's design. For
  context, the other known cosine sites the US-27.8 lint must account for (NOT registered
  here — out of US-27.7b's scope) are:

    * `Loopctl.Knowledge.VectorSearch`'s own query builders (e.g. `candidate_query/4`) —
      they necessarily CONTAIN the `<=>` literal because that module IS the sanctioned top-k
      helper; US-27.8 will exempt the whole `VectorSearch` module as its home, not via this
      per-function registry.
    * `Loopctl.Knowledge.suggestion_candidates_query/6` — a known, intentional INLINE top-k
      `ORDER BY embedding <=> $const LIMIT pool` whose own comment frames the inline split as
      the #170/#172 prod-500 FIX (the index-defeating anti-join/threshold was moved to the
      OUTER query so the inner ANN stays HNSW-eligible). Its lint disposition is a US-27.8
      decision, deliberately left out of this US-27.7b registry.

  Some functions in `Loopctl.Knowledge` legitimately compute a cosine `<=>` distance WITHOUT
  going through (and MUST NOT be routed through) `nearest/4`, because neither is a
  top-k-against-a-constant — forcing them onto `nearest/4` would CHANGE their semantics:

    * `do_distant_pairs/7` — a column-to-column self-join
      (`a.embedding <=> b.embedding`). There is no `$const` target vector, so HNSW cannot
      apply by nature; it is instead bounded by a `LIMIT max_pair_candidates()` sampled
      subquery.
    * `novelty_distance_query/4` — builds a `MIN(embedding <=> $const::vector)` AGGREGATE.
      Top-k-then-min ≠ the true MIN over the prior-tag-scoped set, so a top-k helper would
      change recall semantics. Bounded by prior-tag selectivity (NOT a full-corpus read):
      Postgres serves the MIN via an HNSW `ORDER BY <=> LIMIT 1` rewrite (verified at 80k)
      OR a `tags &&` GIN-bounded scan — the planner picks by cost; either way bounded.
      `nearest_prior_distance/4` is its logical owner (the caller that runs it through
      `HeavyRead`) and is registered too for documentation, but the `<=>` literal lives in
      `novelty_distance_query/4` after the US-27.7b extraction.

  ## How the US-27.8 lint consumes this (the mapping is NOT free)

  The lint scans the source for a hand-rolled cosine `<=>` site, then resolves that site to
  its ENCLOSING `def`/`defp` and arity (e.g. via the AST / `Macro` env) BEFORE calling
  `registered?/3`. So the function that must appear in this allowlist is the one whose body
  TEXTUALLY CONTAINS the `<=>` operator — `do_distant_pairs/7` and `novelty_distance_query/4`
  — not necessarily the logical/owning caller. (Registering only the owner would let the
  lint false-positive on the extracted builder that actually holds the literal.)

  This module is the SINGLE, programmatic source of truth that lint reads so it does NOT
  false-positive on these legitimately-different shapes — and so the set of exceptions stays
  auditable (each carries a non-empty one-line rationale; adding a new exception is a
  visible, reviewable diff here, not a scattered inline comment the lint can't see).

  ## Shape

  `exceptions/0` returns a list of `%{module, function, arity, rationale}` maps.
  `registered?/3` returns true only for a registered `{module, function, arity}` whose
  rationale is NON-EMPTY — a blank justification can never silently suppress the lint.
  """

  @typedoc """
  A single registered exception: the `{module, function, arity}` of a function that
  hand-rolls a cosine `<=>` distance outside `VectorSearch`, plus a one-line `rationale`
  the lint surfaces when it skips that site.
  """
  @type exception :: %{
          module: module(),
          function: atom(),
          arity: arity(),
          rationale: String.t()
        }

  @exceptions [
    %{
      module: Loopctl.Knowledge,
      function: :do_distant_pairs,
      arity: 7,
      rationale:
        "column-to-column self-join (a.embedding <=> b.embedding) — no $const target, " <>
          "HNSW N/A; bounded by the max_pair_candidates() sampled subquery"
    },
    %{
      module: Loopctl.Knowledge,
      function: :novelty_distance_query,
      arity: 4,
      rationale:
        "builds MIN(embedding <=> $const::vector) — the `<=>` literal lives here after the " <>
          "US-27.7b extraction; top-k then min ≠ true min over the set; bounded by prior-tag " <>
          "selectivity (HNSW ORDER-BY-LIMIT-1 rewrite OR a tags && GIN scan), never full-corpus"
    },
    %{
      module: Loopctl.Knowledge,
      function: :nearest_prior_distance,
      arity: 4,
      rationale:
        "logical owner of the novelty MIN aggregate (runs novelty_distance_query/4 through " <>
          "HeavyRead) — documented for auditability; the cosine literal itself is in " <>
          "novelty_distance_query/4 (also registered)"
    }
  ]

  @doc """
  Returns the full list of registered cosine-lint exceptions.

  Each entry is a `t:exception/0`. The list is the auditable source of truth the US-27.8
  guard consumes — extend it (with a non-empty rationale) when a genuinely-different
  cosine shape is added, rather than suppressing the lint inline.
  """
  @spec exceptions() :: [exception()]
  def exceptions, do: @exceptions

  @doc """
  Returns true iff `{module, function, arity}` is a registered exception **with a
  non-empty rationale**.

  Intended for the US-27.8 lint: a flagged hand-rolled-cosine site is a violation UNLESS
  this returns true for its enclosing function. The non-empty-rationale requirement means a
  registry entry with a blank justification can never silently suppress the lint — it would
  still be reported, forcing a real rationale to be written.
  """
  @spec registered?(module(), atom(), arity()) :: boolean()
  def registered?(module, function, arity)
      when is_atom(module) and is_atom(function) and is_integer(arity) do
    registered_in?(@exceptions, module, function, arity)
  end

  @doc """
  Pure form of `registered?/3` that takes the exception list explicitly: true iff
  `{module, function, arity}` matches an entry in `exceptions` whose rationale is non-empty.

  Extracted so the rationale-rejection branch (an entry with a blank/nil rationale does NOT
  suppress the lint) is reachable by tests — the compile-time `@exceptions` constant is
  all-non-empty by construction, so without this seam that branch would be untestable.
  """
  @spec registered_in?([exception()] | [map()], module(), atom(), arity()) :: boolean()
  def registered_in?(exceptions, module, function, arity)
      when is_list(exceptions) and is_atom(module) and is_atom(function) and is_integer(arity) do
    Enum.any?(exceptions, fn exc ->
      exc[:module] == module and exc[:function] == function and exc[:arity] == arity and
        non_empty_rationale?(exc[:rationale])
    end)
  end

  # A rationale suppresses the lint only when it is a present, non-blank string. A nil or
  # whitespace-only rationale must NOT suppress — it forces a real justification to be written.
  defp non_empty_rationale?(rationale) do
    is_binary(rationale) and String.trim(rationale) != ""
  end
end
