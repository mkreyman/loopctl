defmodule Loopctl.Knowledge.Reranker do
  @moduledoc """
  Second-stage reordering of an already-retrieved page (Phase 4 of the KB retrieval plan).

  Fusion decides WHICH documents come back; a reranker decides in WHAT ORDER, using the
  query and the documents together rather than a lane-wise score. The literature's headline
  for this is a combined figure with contextual embeddings, so it is sequenced after that
  work and is the phase with the least measurement behind it — see the plan.

  ## What it reorders, and what it therefore cannot fix

  It reorders the RETURNED PAGE, not the wider fused pool. A document the fusion left
  outside the page is not rescued. Two reasons, both deliberate:

    * `merge_results/5` in `Loopctl.Knowledge` is documented as a pure, DB-free fusion
      function, and this makes an outbound provider call. The graph lane is kept outside it
      for the same reason.
    * Cost is bounded by the page size instead of by the candidate pool, which is what makes
      an LLM call on the default search path arguable at all.

  So it can move recall@k for k below the page size, and MRR/nDCG within it. It cannot move
  recall at the page size itself. Say that when reading an eval delta.

  ## Measured: it fights the graph lane, and that is why it ships OFF

  On golden_v4 a real model's reranking moved MRR +0.113 and nDCG@5 +0.084 — the largest
  single-metric gain in the retrieval plan — while driving `q-mh-rotating-verifier` and its
  distilled pair from recall@5 1.0 to **0.0**. Those are multi-hop questions: their answer is
  reachable only through a link, which is what the Phase 5 graph lane exists to retrieve. A
  reranker judges a candidate from the query, its title and its snippet, so it re-applies
  exactly the surface-similarity criterion the graph lane was added to bypass. The aggregate
  recall stayed FLAT while this happened, because other questions gained at the same time —
  so the interaction is invisible in the headline and visible only per question.

  A positional pin on graph-lane-ONLY candidates was tried and is inert: with the eval's
  synthetic embeddings those documents also carry a weak semantic score, so they are not
  graph-only — the graph lane PROMOTES them rather than solely surfacing them, and there is
  no field on the fused result that says so. A real fix would have the fusion tell the
  reranker WHY each candidate is present, which is a change to `merge_results/5`'s contract
  and is not justified by anything measured yet.

  ## Failing open is the contract

  Every error path returns the input order unchanged: no key, provider error, timeout,
  malformed reply, an id the model invented, a truncated list. Search degrading to
  "unreranked" is invisible to a caller and correct; search failing because a reranker was
  unavailable is not. `Loopctl.Knowledge` therefore has no error branch to handle.

  ## Implementations

    * `Loopctl.Knowledge.Reranker.Noop` — returns the input order. The default, and what
      runs when the feature is off.
    * `Loopctl.Knowledge.Reranker.Llm` — asks the tenant's configured model to order the
      page. Production.
    * `Loopctl.Knowledge.Reranker.Fixture` — replays a committed recording of the above, so
      the retrieval eval can score a real model's judgement offline and deterministically in
      CI. Recording is how the experiment gets evidence; replay is how it stays a gate.
  """

  @typedoc "A candidate handed to a reranker: enough to judge relevance, never the full body."
  @type candidate :: %{id: String.t(), title: String.t(), snippet: String.t() | nil}

  @doc """
  Reorder `candidates` for `query`, returning their ids in the new order.

  Implementations MUST return a permutation of the input ids, or an error. Anything else
  (a dropped id, an invented one, a partial list) is a contract violation the dispatcher
  below treats as an error and discards.
  """
  @callback rerank(
              scope_or_tenant_id :: term(),
              query :: String.t(),
              candidates :: [candidate()],
              opts :: keyword()
            ) :: {:ok, [String.t()]} | {:error, term()}

  require Logger

  @doc """
  Apply the configured reranker to `results`, returning them reordered — or unchanged.

  `results` are the search result maps; only `:id`, `:title` and `:snippet` are shown to the
  reranker. The reordering is applied here rather than trusting the implementation to return
  whole results, so a reranker can never inject, drop or edit a document — only permute one.
  That is the only structural guarantee available when the ordering comes from a model.
  """
  @spec maybe_rerank(term(), String.t(), [map()], keyword()) :: [map()]
  def maybe_rerank(scope_or_tenant_id, query, results, opts \\ []) do
    if enabled?(opts) and length(results) > 1 do
      do_rerank(scope_or_tenant_id, query, results, opts)
    else
      results
    end
  end

  @doc "Whether reranking runs for this call (per-call `:rerank` opt over app config)."
  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    Keyword.get(
      opts,
      :rerank,
      Application.get_env(:loopctl, :knowledge_reranker_enabled, false)
    )
  end

  @doc """
  The implementation module for this call: the per-call `:reranker` opt over app config.

  A per-call override rather than `Application.put_env`, so the retrieval eval's recording
  and replay modes select an implementation without mutating VM-global state that every
  other process in the node would see.
  """
  @spec impl(keyword()) :: module()
  def impl(opts \\ []) do
    Keyword.get(
      opts,
      :reranker,
      Application.get_env(:loopctl, :knowledge_reranker, __MODULE__.Noop)
    )
  end

  defp do_rerank(scope_or_tenant_id, query, results, opts) do
    candidates = Enum.map(results, &to_candidate/1)

    case impl(opts).rerank(scope_or_tenant_id, query, candidates, opts) do
      {:ok, ordered_ids} -> apply_order(results, ordered_ids)
      {:error, reason} -> unchanged(results, reason)
    end
  rescue
    # A reranker is an outbound call behind a behaviour; a raise inside it must degrade the
    # ORDER, never the search. Rescuing here rather than in each implementation keeps that
    # guarantee independent of who wrote the implementation.
    error -> unchanged(results, error)
  end

  defp to_candidate(result) do
    %{
      id: result.id,
      title: Map.get(result, :title, ""),
      snippet: Map.get(result, :snippet)
    }
  end

  # The permutation check. A model that drops, duplicates or invents an id has not reordered
  # the page — it has proposed a different page — so the whole reply is discarded rather than
  # partially applied, which would silently truncate results.
  defp apply_order(results, ordered_ids) do
    by_id = Map.new(results, &{&1.id, &1})
    input_ids = MapSet.new(Map.keys(by_id))
    proposed = MapSet.new(ordered_ids)

    if length(ordered_ids) == map_size(by_id) and MapSet.equal?(input_ids, proposed) do
      Enum.map(ordered_ids, &Map.fetch!(by_id, &1))
    else
      unchanged(results, :not_a_permutation)
    end
  end

  defp unchanged(results, reason) do
    Logger.debug("knowledge reranker declined: #{inspect(reason)}")
    results
  end
end
