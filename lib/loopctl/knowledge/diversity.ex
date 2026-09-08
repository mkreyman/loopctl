defmodule Loopctl.Knowledge.Diversity do
  @moduledoc """
  Redundancy removal + maximal-marginal-relevance selection over a ranked candidate set
  (#792).

  ## Why

  `POST /api/v1/recall` becomes the SECOND-BRAIN HITS block: three rows out of a five-row
  request, in every claude-config session. The candidate set was ranked and truncated and
  never checked for redundancy, so on a topically clustered corpus two near-copies could
  occupy two of the three slots a session ever sees and the third relevant-but-dissimilar
  article never rendered. Similarity PROPOSES; it must not DISPOSE.

  ## The pipeline

  `select/3` runs four stages over candidates the caller supplies IN RELEVANCE ORDER:

    1. **Containment in history** — an id in `:exclude_ids` was already shown to this
       session and is dropped. Server-side, so the slot it frees is REFILLED from the
       over-fetched pool rather than merely dropped (which is all a client-side filter
       can do). It has a FLOOR: containment may never cost a slot it cannot refill, so
       when the shown-set has swallowed the pool the highest-ranked repeats are re-admitted
       (counted as `readmitted_already_seen`) rather than returning a short or empty page.
       An empty knowledge half is read as "the KB has nothing on this", which is a worse
       answer than a repeat.
    2. **Exact-fingerprint dedup** — candidates sharing a `:content_hash` collapse to the
       highest-ranked one. A `nil` hash is never a fingerprint: unfingerprinted rows are
       all distinct from each other and from everything else.
    3. **Near-duplicate removal** — a survivor whose cosine similarity to an ALREADY
       SELECTED item reaches `:near_dup_threshold` is dropped. Measured against the
       selected set, never against the query: two articles can both be highly relevant
       and still be the same fact twice.
    4. **MMR selection** — of what remains, pick the candidate maximizing
       `λ · relevance − (1 − λ) · max_similarity_to_selected`, repeat until `limit`.

  Stages 3 and 4 share one loop, because both need the same
  `max similarity against the already-selected set` and computing it twice would double
  the only expensive part.

  ## λ = 1.0 is EXACTLY today's selection

  At `lambda: 1.0` the MMR term is `1.0 * score - 0.0 * max_sim`, which is `score` to the
  bit (`x - 0.0 == x` for every finite float), and ties resolve to the earlier input
  position. So the MMR stage degenerates to "take the highest `:score`, ties to the earlier
  position", and because the caller supplies candidates IN RELEVANCE ORDER — `:score`
  descending on the caller's own ranking scale — that is "take them in the order you were
  given", the pre-#792 behaviour, with `t:stats/0` reporting zero drops. THE PRECONDITION IS
  LOAD-BEARING: a caller that ranks the list on one scale and fills `:score` from another
  gets a page MMR re-chose even at λ = 1.0, which is why `Knowledge.hybrid_search/3` scores
  its candidates from their POSITION in the fused pool rather than from a per-lane absolute
  score. The dedup stages are INDEPENDENT knobs: pass a `:near_dup_threshold` above `1.0` to
  disable them too and the whole function is `Enum.take(candidates, limit)`.

  ## Ordering is NOT this module's job

  MMR decides WHAT is in the set. It must never decide the order the set renders in —
  that stays the caller's deterministic sort (`Memory.recall_context/2` sorts the merged
  list score DESC / source / id ASC; `Knowledge.hybrid_search/3` restores pool order with
  the curated winner pinned first). Selecting with MMR and then sorting deterministically
  satisfies both this and the cache-friendly-ordering requirement it would otherwise
  fight with.

  ## A candidate we cannot measure is never dropped

  A candidate with no embedding contributes `max_sim = 0.0`: it is never removed as a
  near-duplicate and never demoted by the diversity term. Fail-open is the only safe
  direction — a missing vector (unembedded article, provider outage, dimension cutover
  mid-flight) must cost recall nothing, and the alternative silently deletes rows for a
  reason that has nothing to do with them.

  Pure: no DB, no config reads inside the loop, no process state. The vectors are fetched
  by `Loopctl.Knowledge.diversity_vectors/2` and the knobs resolved by `config/1`, both
  at the call site.
  """

  @typedoc """
  One ranked candidate. `:score` is its relevance on whatever scale the caller ranks on
  (the loop only ever compares scores to each other). `:embedding` and `:content_hash`
  are optional — absent means "unmeasurable", never "dissimilar".
  """
  @type candidate :: %{
          required(:id) => String.t(),
          required(:score) => number(),
          optional(:embedding) => [float()] | nil,
          optional(:content_hash) => String.t() | nil,
          optional(any()) => any()
        }

  @typedoc """
  What the pipeline did, published on `meta.diversity` so the effect is MEASURABLE rather
  than assumed. Every `dropped_*` counter is a candidate that would have been returned
  before #792.
  """
  @type stats :: %{
          enabled: boolean(),
          lambda: float(),
          near_dup_threshold: float(),
          candidates: non_neg_integer(),
          selected: non_neg_integer(),
          dropped_already_seen: non_neg_integer(),
          readmitted_already_seen: non_neg_integer(),
          dropped_exact_duplicates: non_neg_integer(),
          dropped_near_duplicates: non_neg_integer(),
          vectors_available: non_neg_integer()
        }

  @typedoc "The resolved knobs for one call — see `config/1`."
  @type opts :: %{
          enabled?: boolean(),
          lambda: float(),
          near_dup_threshold: float(),
          over_fetch: pos_integer(),
          max_pool: pos_integer()
        }

  # Weighted toward RELEVANCE, per #792: diversity is a correction on a ranked list, not a
  # co-equal objective. 0.7 keeps a clearly-better article ahead of a merely-different one
  # while still breaking up a cluster — at 0.5 a low-scoring outlier displaces a strong hit
  # whenever the top two are even mildly related.
  @default_lambda 0.7

  # The threshold #792 specifies. Cosine >= 0.95 between two EMBEDDED ARTICLES is not
  # "related", it is the same content twice; 0.90 already catches genuinely distinct
  # articles on one narrow topic, which is the material this exists to keep.
  @default_near_dup_threshold 0.95

  # Refill needs somewhere to refill FROM: dropping a near-duplicate out of a set that was
  # fetched at exactly `limit` leaves `limit - 1` rows, which is the outcome a client-side
  # filter already achieves. The knowledge half is therefore fetched at `limit * over_fetch`
  # so every drop is replaced by the next distinct candidate.
  @default_over_fetch 3

  # The over-fetch is bounded because every candidate above `limit` costs a vector on the
  # wire: at 1536 dimensions a candidate is ~6 KB, so an unbounded `limit * over_fetch` at
  # the max page size of 50 would pull ~900 KB per recall through the small admin pool.
  @default_max_pool 30

  @doc """
  Resolves the per-call knobs: application config, overridden by `opts`.

  Config-DI (never `Application.put_env` in a test — pass the override through `opts`):

    * `:recall_diversity_enabled` (default `true`) — the master switch. Disabled, `select/3`
      is `Enum.take/2` and reports `enabled: false` with zero drops.
    * `:recall_diversity_lambda` (default `#{@default_lambda}`) — the MMR relevance weight,
      clamped to `[0.0, 1.0]`. `1.0` is pure relevance.
    * `:recall_diversity_near_dup_threshold` (default `#{@default_near_dup_threshold}`) —
      cosine at or above which a candidate is a duplicate of something already selected.
      A value above `1.0` disables the stage (cosine cannot exceed 1.0). It must be
      STRICTLY POSITIVE: `0` is in `[0.0, 1.0]` and would classify every candidate —
      including every UNMEASURABLE one, whose similarity is `0.0` by definition — as a
      duplicate, so one config typo would return nothing for every query on the node.
    * `:recall_diversity_over_fetch` (default `#{@default_over_fetch}`) — how many times
      `limit` to fetch so drops can be refilled.
    * `:recall_diversity_max_pool` (default `#{@default_max_pool}`) — hard ceiling on the
      over-fetched pool, because each pool member costs a vector read.

  A non-numeric or out-of-range value falls back to the default rather than propagating:
  a config typo must not silently reshape retrieval.
  """
  @spec config(keyword() | map()) :: opts()
  def config(overrides \\ []) do
    %{
      enabled?: bool_opt(overrides, :diversity_enabled, :recall_diversity_enabled, true),
      lambda:
        unit_opt(
          overrides,
          :diversity_lambda,
          :recall_diversity_lambda,
          @default_lambda,
          1.0,
          :non_negative
        ),
      near_dup_threshold:
        unit_opt(
          overrides,
          :diversity_near_dup_threshold,
          :recall_diversity_near_dup_threshold,
          @default_near_dup_threshold,
          # Deliberately above 1.0: the documented way to DISABLE the stage is a threshold
          # cosine cannot reach, so the clamp must admit it.
          2.0,
          # ...and STRICTLY positive at the bottom: `0` would make every candidate a
          # duplicate of the first pick, including the unmeasurable ones the module
          # promises never to drop. A typo must not be able to empty retrieval.
          :positive
        ),
      over_fetch:
        pos_int_opt(
          overrides,
          :diversity_over_fetch,
          :recall_diversity_over_fetch,
          @default_over_fetch
        ),
      max_pool:
        pos_int_opt(overrides, :diversity_max_pool, :recall_diversity_max_pool, @default_max_pool)
    }
  end

  @doc """
  How many candidates to fetch so that `limit` can survive the drops.

  `:max_pool` caps the OVER-fetch, never the base: the result is never below `limit` (a
  cap that returned fewer candidates than the caller asked rows for would be a recall
  regression dressed as a budget) and never above `:max_pool` unless `limit` itself
  already is. Each pool member above `limit` costs a vector read, which is what the cap
  is buying.
  """
  @spec pool_size(integer(), opts()) :: pos_integer()
  def pool_size(limit, %{enabled?: false}) when is_integer(limit) and limit > 0, do: limit

  def pool_size(limit, %{over_fetch: over_fetch, max_pool: max_pool})
      when is_integer(limit) and limit > 0 do
    limit |> Kernel.*(over_fetch) |> min(max_pool) |> max(limit)
  end

  # A non-positive or non-integer limit is a caller bug, not a crash: `hybrid_search/3`
  # used to hand `limit: 0` straight through to `paginate_results/2`, which clamped it with
  # `max(1)`, so a FunctionClauseError here would be a NEW 500 on a public context function.
  # One row is the smallest pool that can answer at all.
  def pool_size(_limit, opts), do: pool_size(1, opts)

  @doc """
  Selects at most `limit` candidates from `candidates` (supplied IN RELEVANCE ORDER).

  Returns `{selected, stats}` where `selected` is in MMR pick order — the caller is
  responsible for the render order (see the moduledoc). `stats` is the `meta.diversity`
  block.

  ## Options

    * `:exclude_ids` — a `MapSet` (or list) of ids already shown to this session. Dropped
      only while something remains to refill the slot with: see the containment FLOOR in
      the moduledoc, and `stats.readmitted_already_seen` for when it bound.
    * `:preselected` — ids that are PINNED into the selected set before the loop starts.
      They count against `limit`, they are returned at the FRONT in the order given, and
      — the reason this exists rather than a caller prepending them afterwards — the
      near-duplicate and MMR stages measure against them, so a near-copy of a pinned item
      cannot take the next slot. `Knowledge.hybrid_search/3` pins the curated winner this
      way: a caller branching on `meta.provenance` must be able to trust
      `List.first(results)`, and MMR is not entitled to overrule a governed answer.
  """
  @spec select([candidate()], integer(), opts(), keyword()) :: {[candidate()], stats()}
  def select(candidates, limit, opts, extra \\ [])

  def select(candidates, limit, %{enabled?: false} = opts, _extra)
      when is_list(candidates) and is_integer(limit) and limit > 0 do
    selected = Enum.take(candidates, limit)

    {selected, no_drop_stats(candidates, selected, opts, false)}
  end

  def select(candidates, limit, opts, extra)
      when is_list(candidates) and is_integer(limit) and limit > 0 do
    exclude = to_id_set(Keyword.get(extra, :exclude_ids, []))
    pinned = to_id_set(Keyword.get(extra, :preselected, []))

    # A pinned candidate skips EVERY drop stage: it is split out here, at the top, before
    # containment and before the fingerprint collapse. Splitting it out after those two
    # (as this did until the #792 review) let a pinned article be dropped as the
    # lower-ranked member of its own content-hash group while `meta.provenance ==
    # :curated` and `meta.curated_article_id` still named it — the guarantee
    # `Knowledge.hybrid_search/3`'s hoist exists to provide, silently revoked.
    {pinned_candidates, rest} = Enum.split_with(candidates, &MapSet.member?(pinned, &1.id))

    {unseen, already_seen} = partition_seen(rest, exclude)

    # THE CONTAINMENT FLOOR. Suppressing a repeat is only correct while a distinct
    # candidate can take the freed slot; once the shown-set has swallowed the pool the
    # alternative is an EMPTY knowledge half, which a caller reads as "the KB has nothing
    # on this" while the articles it wanted still exist.
    {readmitted, dropped_seen} =
      readmit_for_shortfall(already_seen, limit - length(pinned_candidates) - length(unseen))

    {kept_exact, dropped_exact} =
      dedup_by_fingerprint(unseen ++ readmitted, fingerprints(pinned_candidates))

    pinned_items = Enum.map(pinned_candidates, &prepare/1)
    pool = Enum.map(kept_exact, &prepare/1)

    {selected, dropped_near} = mmr(pool, limit, opts, pinned_items)

    {Enum.map(selected, & &1.candidate),
     %{
       enabled: true,
       lambda: opts.lambda,
       near_dup_threshold: opts.near_dup_threshold,
       candidates: length(candidates),
       selected: length(selected),
       dropped_already_seen: length(dropped_seen),
       readmitted_already_seen: length(readmitted),
       dropped_exact_duplicates: dropped_exact,
       dropped_near_duplicates: dropped_near,
       vectors_available: Enum.count(pinned_items ++ pool, &(&1.vector != nil))
     }}
  end

  # A non-positive or non-integer limit selects nothing rather than raising: this is a
  # public API reached through `Knowledge.hybrid_search/3`, where the pre-#792 path
  # clamped such a limit in `paginate_results/2` instead of crashing.
  def select(candidates, _limit, opts, _extra) when is_list(candidates),
    do: {[], no_drop_stats(candidates, [], opts, false)}

  @doc """
  Cosine similarity of two equal-length vectors, `0.0` when either is absent, empty,
  zero-norm, or a different length.

  Full cosine (not a bare dot product): provider embeddings are not guaranteed unit-norm,
  and normalizing at read time is what keeps a `0.95` threshold meaning the same thing
  across models.
  """
  @spec cosine([float()] | nil, [float()] | nil) :: float()
  def cosine(a, b) when is_list(a) and is_list(b), do: cosine_with_norms(a, norm(a), b, norm(b))
  def cosine(_a, _b), do: 0.0

  # --- Stage 0: the uniform "nothing was dropped" stats block -----------------------

  defp no_drop_stats(candidates, selected, opts, enabled?) do
    %{
      enabled: enabled?,
      lambda: opts.lambda,
      near_dup_threshold: opts.near_dup_threshold,
      candidates: length(candidates),
      selected: length(selected),
      dropped_already_seen: 0,
      readmitted_already_seen: 0,
      dropped_exact_duplicates: 0,
      dropped_near_duplicates: 0,
      vectors_available: 0
    }
  end

  # --- Stage 1: containment in history ---------------------------------------------

  defp partition_seen(candidates, exclude) do
    if MapSet.size(exclude) == 0 do
      {candidates, []}
    else
      Enum.split_with(candidates, fn candidate -> not MapSet.member?(exclude, candidate.id) end)
    end
  end

  # The floor. `shortfall` is how many slots containment would leave unfilled; the
  # highest-ranked repeats come back to cover exactly that many and no more, so a session
  # with a healthy pool still never sees a repeat.
  defp readmit_for_shortfall(already_seen, shortfall) when shortfall > 0,
    do: Enum.split(already_seen, shortfall)

  defp readmit_for_shortfall(already_seen, _shortfall), do: {[], already_seen}

  # --- Stage 2: exact fingerprint --------------------------------------------------

  # `nil`/blank hashes are NOT a fingerprint group: an unembedded article and a
  # never-hashed one are not duplicates of each other, and collapsing them would delete
  # rows on the strength of a missing field. Highest-ranked member of a group wins because
  # `candidates` arrives in relevance order — and the PINNED candidates' fingerprints seed
  # `seen`, so a pin still wins its own group even though it never passes through here.
  defp dedup_by_fingerprint(candidates, seen) do
    {kept, _seen, dropped} =
      Enum.reduce(candidates, {[], seen, 0}, &take_first_of_fingerprint/2)

    {Enum.reverse(kept), dropped}
  end

  defp fingerprints(candidates) do
    candidates |> Enum.map(&fingerprint/1) |> Enum.reject(&is_nil/1) |> MapSet.new()
  end

  defp take_first_of_fingerprint(candidate, {kept, seen, dropped}) do
    hash = fingerprint(candidate)

    cond do
      is_nil(hash) -> {[candidate | kept], seen, dropped}
      MapSet.member?(seen, hash) -> {kept, seen, dropped + 1}
      true -> {[candidate | kept], MapSet.put(seen, hash), dropped}
    end
  end

  defp fingerprint(candidate) do
    case Map.get(candidate, :content_hash) do
      hash when is_binary(hash) and hash != "" -> hash
      _ -> nil
    end
  end

  # --- Stages 3 + 4: near-dup removal and MMR, one pass ----------------------------

  # Precompute the norm once per candidate: the loop compares every remaining candidate
  # against every selected one, so a norm recomputed inside it is O(k·n) work for a value
  # that never changes.
  defp prepare(candidate) do
    vector = vector_of(candidate)

    %{
      candidate: candidate,
      id: candidate.id,
      score: score_of(candidate),
      vector: vector,
      norm: if(vector, do: norm(vector), else: 0.0)
    }
  end

  defp mmr(prepared, limit, opts, pinned_items) do
    # The pinned items seed `selected` in REVERSE, because `mmr_loop/5` prepends its picks
    # and reverses once at the end — so seeding in reverse is what puts them at the front
    # of the result in the order the caller gave them.
    seeded = pinned_items |> Enum.with_index() |> Enum.map(&index_item/1) |> Enum.reverse()

    # Each candidate carries its RUNNING max similarity against the selected set, seeded
    # against the pins. The loop then only ever compares against the item it just picked,
    # which is what keeps the whole selection O(pool) cosines per pick instead of
    # O(pool x selected): at the 50-candidate recall maximum that is the difference between
    # ~1.3k and ~21k 1536-dimension cosines on the request process.
    prepared
    |> Enum.with_index()
    |> Enum.map(&index_item/1)
    |> Enum.map(fn item -> {item, max_similarity(item, pinned_items)} end)
    |> mmr_loop(seeded, limit, opts, 0)
  end

  defp index_item({item, index}), do: Map.put(item, :index, index)

  defp mmr_loop([], selected, _limit, _opts, dropped), do: {Enum.reverse(selected), dropped}

  defp mmr_loop(_remaining, selected, limit, _opts, dropped) when length(selected) >= limit,
    do: {Enum.reverse(selected), dropped}

  defp mmr_loop(scored, selected, limit, opts, dropped) do
    {near_dups, survivors} = Enum.split_with(scored, &near_duplicate?(&1, opts))

    case survivors do
      [] ->
        {Enum.reverse(selected), dropped + length(near_dups)}

      _ ->
        {winner, _sim} =
          Enum.min_by(survivors, fn {item, sim} -> {-mmr_score(item, sim, opts), item.index} end)

        rest =
          for {item, sim} <- survivors,
              item.index != winner.index,
              do: {item, max(sim, similarity(item, winner))}

        mmr_loop(rest, [winner | selected], limit, opts, dropped + length(near_dups))
    end
  end

  # `sim > 0.0` is the invariant, not an optimization: a candidate with no loadable vector
  # scores exactly 0.0, so without it a threshold of 0 would classify every unmeasurable
  # candidate as a duplicate of the first pick — the one thing this module promises never
  # to do. `config/1` already refuses a non-positive threshold; this is the second lock.
  defp near_duplicate?({_item, sim}, %{near_dup_threshold: threshold}),
    do: sim > 0.0 and sim >= threshold

  # `λ · relevance − (1 − λ) · max_sim`. At λ = 1.0 the second term is `0.0 * sim`, which
  # is `0.0` for any finite similarity, and `score - 0.0 == score` to the bit — that exact
  # identity is what makes λ = 1.0 reproduce the pre-#792 selection rather than merely
  # approximate it.
  defp mmr_score(item, max_sim, %{lambda: lambda}),
    do: lambda * item.score - (1.0 - lambda) * max_sim

  defp max_similarity(_item, []), do: 0.0

  defp max_similarity(%{vector: nil}, _selected), do: 0.0

  defp max_similarity(item, selected) do
    selected
    |> Enum.map(&similarity(item, &1))
    |> Enum.max(fn -> 0.0 end)
  end

  defp similarity(item, chosen),
    do: cosine_with_norms(item.vector, item.norm, chosen.vector, chosen.norm)

  # --- Vector math -----------------------------------------------------------------

  defp cosine_with_norms(a, norm_a, b, norm_b)
       when is_list(a) and is_list(b) and is_number(norm_a) and is_number(norm_b) do
    if norm_a <= 0.0 or norm_b <= 0.0 or length(a) != length(b) do
      0.0
    else
      dot(a, b) / (norm_a * norm_b)
    end
  end

  defp cosine_with_norms(_a, _norm_a, _b, _norm_b), do: 0.0

  # Hand-rolled rather than `Enum.zip/2 |> Enum.reduce/3`: zip allocates a 2-tuple PER
  # DIMENSION, so at 1536 dimensions it was ~1536 garbage tuples per cosine and the single
  # dominant cost of the whole selection.
  defp dot(a, b), do: dot(a, b, 0.0)

  defp dot([x | xs], [y | ys], acc), do: dot(xs, ys, acc + x * y)
  defp dot(_a, _b, acc), do: acc

  defp norm(vector), do: vector |> Enum.reduce(0.0, fn x, acc -> acc + x * x end) |> :math.sqrt()

  # --- Small helpers ---------------------------------------------------------------

  defp vector_of(candidate) do
    case Map.get(candidate, :embedding) do
      list when is_list(list) and list != [] -> list
      _ -> nil
    end
  end

  defp score_of(candidate) do
    case Map.get(candidate, :score) do
      score when is_number(score) -> score * 1.0
      _ -> 0.0
    end
  end

  defp to_id_set(%MapSet{} = set), do: set
  defp to_id_set(ids) when is_list(ids), do: MapSet.new(ids)
  defp to_id_set(_), do: MapSet.new()

  defp bool_opt(overrides, override_key, config_key, default) do
    case fetch_override(overrides, override_key) do
      {:ok, value} when is_boolean(value) -> value
      _ -> config_bool(config_key, default)
    end
  end

  defp config_bool(config_key, default) do
    case Application.get_env(:loopctl, config_key, default) do
      value when is_boolean(value) -> value
      _ -> default
    end
  end

  defp unit_opt(overrides, override_key, config_key, default, ceiling, floor) do
    case fetch_override(overrides, override_key) do
      {:ok, value} ->
        clamp_unit(value, default, ceiling, floor)

      :error ->
        clamp_unit(Application.get_env(:loopctl, config_key, default), default, ceiling, floor)
    end
  end

  defp clamp_unit(value, default, ceiling, floor) when is_number(value) do
    if above_floor?(value, floor), do: value |> min(ceiling) |> Kernel.*(1.0), else: default * 1.0
  end

  defp clamp_unit(_value, default, _ceiling, _floor), do: default * 1.0

  defp above_floor?(value, :positive), do: value > 0
  defp above_floor?(value, :non_negative), do: value >= 0

  defp pos_int_opt(overrides, override_key, config_key, default) do
    case fetch_override(overrides, override_key) do
      {:ok, value} -> clamp_pos_int(value, default)
      :error -> clamp_pos_int(Application.get_env(:loopctl, config_key, default), default)
    end
  end

  defp clamp_pos_int(value, _default) when is_integer(value) and value > 0, do: value
  defp clamp_pos_int(_value, default), do: default

  defp fetch_override(overrides, key) when is_list(overrides), do: Keyword.fetch(overrides, key)
  defp fetch_override(overrides, key) when is_map(overrides), do: Map.fetch(overrides, key)
  defp fetch_override(_overrides, _key), do: :error
end
