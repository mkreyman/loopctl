defmodule Loopctl.Knowledge.CosineLintExceptions do
  @moduledoc """
  The auditable allowlist of functions that legitimately hand-roll a cosine
  distance/ORDER BY **outside** the shared `Loopctl.Knowledge.VectorSearch` helper.

  ## Why this exists

  The shared `VectorSearch.nearest/4` helper is the ONLY place a top-k
  `ORDER BY embedding <=> $const LIMIT k` should be written — its exact SQL shape is
  load-bearing (the #168/#170/#172 production 500s came from variations that defeated
  the HNSW index). US-27.8 introduces a "no hand-rolled cosine ORDER BY/distance outside
  the helper" source-lint to prevent that shape from being reintroduced ad hoc.

  Two functions in `Loopctl.Knowledge` legitimately compute a cosine `<=>` distance WITHOUT
  going through (and MUST NOT be routed through) `nearest/4`, because neither is a
  top-k-against-a-constant — forcing them onto `nearest/4` would CHANGE their semantics:

    * `do_distant_pairs/7` — a column-to-column self-join
      (`a.embedding <=> b.embedding`). There is no `$const` target vector, so HNSW cannot
      apply by nature; it is instead bounded by a `LIMIT max_pair_candidates()` sampled
      subquery.
    * `nearest_prior_distance/4` — a `MIN(embedding <=> $const::vector)` AGGREGATE.
      Top-k-then-min ≠ the true MIN over the prior-tag-scoped set, so a top-k helper would
      change recall semantics; it is bounded by the `tags &&` GIN residual.

  This module is the SINGLE, programmatic source of truth the US-27.8 lint reads so it
  does NOT false-positive on these two legitimately-different shapes — and so the set of
  exceptions stays auditable (each carries a one-line rationale; adding a new exception is
  a visible, reviewable diff here, not a scattered inline comment the lint can't see).

  ## Shape

  `exceptions/0` returns a list of `%{module, function, arity, rationale}` maps. A future
  lint matches a flagged hand-rolled-cosine site against `{module, function, arity}` and
  skips it iff there is a registered exception whose `rationale` is non-empty.
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
      function: :nearest_prior_distance,
      arity: 4,
      rationale:
        "MIN(embedding <=> $const::vector) aggregate — top-k then min ≠ true min over " <>
          "the set; bounded by the prior-tag (tags &&) GIN residual"
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
  Returns true iff `{module, function, arity}` is a registered exception.

  Intended for the US-27.8 lint: a flagged hand-rolled-cosine site is a violation UNLESS
  this returns true for its enclosing function.
  """
  @spec registered?(module(), atom(), arity()) :: boolean()
  def registered?(module, function, arity)
      when is_atom(module) and is_atom(function) and is_integer(arity) do
    Enum.any?(
      @exceptions,
      &(&1.module == module and &1.function == function and &1.arity == arity)
    )
  end
end
