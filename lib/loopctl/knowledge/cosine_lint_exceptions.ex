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
  auditable list of the cosine exceptions in `Loopctl.Knowledge` (distant_pairs + novelty).
  The US-27.8 lint (`Loopctl.Credo.Check.CosineQueryReintroduction`) is now LIVE and reads
  this registry as its allowlist. Its full exemption policy — DECIDED in US-27.8 — is:

    * `Loopctl.Knowledge.VectorSearch`'s own query builders (e.g. `candidate_query/4`) —
      they necessarily CONTAIN the `<=>` literal because that module IS the sanctioned top-k
      helper; the US-27.8 lint exempts the WHOLE `VectorSearch` module as its home (matched
      by module name), NOT via this per-function registry. (Decision made — no longer
      deferred.)
    * `Loopctl.Knowledge.suggestion_candidates_query/6` — post-US-27.7a this DELEGATES to
      `VectorSearch.candidate_query/4` and carries NO inline `<=>` literal, so the lint never
      sees a site there: it is not a lint target and needs no registry entry. (The earlier
      inline `ORDER BY embedding <=> $const LIMIT pool` — the #170/#172 prod-500 FIX — has
      since been routed through the shared helper; decision made — no longer deferred.)

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

  Two rules when adding an entry:

    * **Register at the HEAD-slot (maximum) arity.** The lint computes arity from the
      `def` head's argument count, so a function with default args (`def f(x \\ 1)` —
      callable at /1 AND /2) is flagged at /2 (the head slot). Register the head-slot arity
      or the exemption silently won't match. (All current entries are default-arg-free.)
    * **`nearest_prior_distance/4` holds NO `<=>` literal** (it delegates to
      `novelty_distance_query/4`). It is registered for AUDIT/documentation only — the lint
      never produces a site there, so this entry is inert-but-harmless (it documents the
      logical owner of the MIN-distance novelty path).

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
    # NB: `Loopctl.Memory.memory_candidate_query/4` (US-28.2 agent-memory HNSW recall) is
    # DELIBERATELY NOT registered here — it holds NO hand-rolled cosine literal. It builds
    # its index-ordered inner pool through the shared, schema-parameterized
    # `Loopctl.Knowledge.VectorSearch.index_safe_knn_base/4` + `put_distance/2`, so the
    # cosine operator lives ONLY in `VectorSearch` (the lint whole-module home). Extracting that
    # shared helper — rather than duplicating the HNSW query into Memory and registering an
    # exception — is exactly what US-28.2 technical notes mandated.
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
