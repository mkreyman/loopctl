defmodule Loopctl.Knowledge.RankingPriors do
  @moduledoc """
  Pure, DB-free ranking priors applied on top of `Loopctl.Knowledge.search_combined/3`'s
  fused candidate list (#471, epic #468 — the Cerebras/Nick-Saraev RAG playbook).

  Two priors re-rank the fused output:

    * **Recency decay** — `exp(-age_days / 30)`, the SAME decay `knowledge_context` uses
      (`recency_decay/2` is the single source of truth for both). Applied as a BOUNDED
      factor `1 - w + w * decay` on the score, so a stale document is nudged down but a
      brand-new one is never lifted above a document with materially stronger relevance.
      > #### "Recency" is LAST-MUTATION time, not authored time {: .warning}
      > `age_days` is measured from `updated_at`, and `updated_at` is bumped by ANY write
      > that changes the row — including a re-embed / content-hash refresh
      > (`Loopctl.Knowledge.update_embedding/4`). A model migration or a bulk re-embedding
      > backfill therefore resets a years-old note's apparent freshness to "now" and, if run
      > across the whole corpus, globally FLATTENS the recency signal. This is inherited
      > verbatim from `knowledge_context` (#471's AC mandates reusing that exact field +
      > decay as the single source of truth), but #471 now surfaces it on the PRIMARY search
      > path. If you run a mass re-embed, expect ranking to shift until authored-age drift
      > re-accumulates; there is no separate authored/source timestamp to fall back to.
    * **Source authority** — a bounded prior derived from `category` / `source_type` /
      `tags`, centered on 1.0 and clamped to a narrow band, so it re-ranks NEAR-TIES
      (which post-#470 Reciprocal Rank Fusion produces by construction) rather than
      overriding strong relevance. `verdict-kill` ideas and `:superseded` articles are
      demoted regardless of the authority toggle, so dead doctrine stops outranking live
      doctrine.

  > #### The `:superseded` demotion is DEFENSIVE on the default path {: .info}
  >
  > Both search lanes filter to a SINGLE status atom (defaulting to `:published` —
  > keyword via `maybe_filter_by_status/2`, semantic via the same equality in
  > `Loopctl.Knowledge.VectorSearch`), so published and superseded rows never coexist
  > in one candidate set. On that default path the AC "superseded doctrine does not
  > outrank live doctrine" is already satisfied by EXCLUSION — the `:superseded` branch
  > of `demotion_factor/1` never fires. It earns its keep only when a caller relaxes the
  > status filter (`status: nil` pools all statuses), where demotion is the mechanism
  > that keeps a superseded doc from outranking a live one. `verdict-kill` demotion, by
  > contrast, IS live on the default path (a killed idea can still be `:published`).

  ## Why bounded (break ties, do not dominate)

  Post-#470 the fused `:final_score` is `Σ_lane weight/(k + rank)`. Two docs that each top
  a single lane tie EXACTLY; a doc with cross-lane consensus scores ~2x a single-lane hit.
  The authority factor clamps to `[0.9, 1.1]`, but the band is ONE-SIDED in practice: every
  category/source weight is >= 0 and `strength` >= 0, so `1 + strength*(cat+src)` is always
  >= 1.0 and the 0.9 floor is unreachable — the EFFECTIVE range is `[1.0, 1.1]`. Authority
  therefore only ever BOOSTS a higher-authority doc; it never demotes a low-authority raw
  note below neutral (that demotion is the SEPARATE `demotion_factor/1` job). Even so it can
  flip an exact/near tie but can NEVER flip a 2x-stronger consensus winner — precisely the
  "priors break ties, not dominate strong relevance" risk the issue calls out. The recency
  factor is likewise bounded in `[1 - w, 1]`.

  This module is intentionally PURE (no DB, no clock of its own — `now` is passed in) so it
  can be applied inside `Loopctl.Knowledge.merge_results/5` (which must stay DB-free) and
  unit-tested directly.
  """

  # Recency decay time constant in days. A 30-day-old doc decays to exp(-1) ≈ 0.37.
  # Shared with knowledge_context via recency_decay/2 — the single source of truth.
  @decay_tau_days 30.0

  # Category authority (data-driven). Higher = more canonical/curated doctrine. Keyed by
  # the STRING form of the category atom so a result map carrying an Ecto.Enum atom or a
  # stringified category both resolve without String.to_atom on anything.
  #
  # Ordering rationale (verified by unit tests): the issue-#471 top authority tier is
  # `decision / playbook / finding` (its literal example: "decision / playbook / finding
  # > idea > raw harvested atomic note"), so `finding` sits WITH decision/playbook at the
  # top and strictly ABOVE `reference`. Ordering: top curated doctrine
  # (decision/playbook/finding) > reference > structural knowledge (pattern/insight/
  # convention) > low-signal captured notes (entity/quote/question) > a speculative
  # `idea` > an uncategorized raw atomic note (the @default_category_authority floor).
  # `finding >= reference` is load-bearing: when a grade-3 `finding` answer and a grade-2
  # `reference` distractor near-tie in RRF, the higher-authority side must be the finding,
  # or the prior would reorder the stronger-graded doc DOWN (the regression #471 review
  # caught on q-keyword-fallback). Every weight is >= the floor, so the prior only ever
  # REORDERS ties upward by authority; dead-doctrine demotion (verdict-kill / superseded)
  # is what pushes down.
  @category_authority %{
    "decision" => 1.0,
    "playbook" => 1.0,
    "finding" => 0.9,
    "reference" => 0.8,
    "pattern" => 0.7,
    "convention" => 0.6,
    "insight" => 0.6,
    "entity" => 0.4,
    "quote" => 0.3,
    "question" => 0.3,
    "idea" => 0.2
  }
  # A raw atomic note (nil/unknown category) is the authority floor — strictly below
  # `idea`, per the issue's "decision/playbook/finding > idea > raw atomic note".
  @default_category_authority 0.0

  # Source-type authority (data-driven). Human/reviewed provenance over raw automated
  # ingests. Keys mirror Loopctl.Knowledge.Article.known_source_types/0; an unknown or
  # nil source_type is neutral (0.0).
  @source_authority %{
    "review_finding" => 1.0,
    "manual" => 0.8,
    "skill" => 0.6,
    "channel_graduation" => 0.5,
    "session_log" => 0.2,
    "agent" => 0.2,
    "newsletter" => 0.1,
    "web_article" => 0.1,
    "ingestion" => 0.0
  }
  @default_source_authority 0.0

  # Provenance authority (#251). The single strongest measured signal in this table, and
  # the one the category/source_type weights above could not see.
  #
  # Measured on the live corpus 2026-08-11, over 30 days of reads:
  #
  #   first-party              3,164 articles   389.7 reads/1k   18.30% ever read
  #   third-party (harvested) 75,768 articles    14.6 reads/1k    1.09% ever read
  #
  # A 26.7x per-article read rate: first-party is 4% of the corpus and 53% of the reads.
  # The June 2026 bulk harvest added 76k third-party articles, and every query since has
  # had to pull the ~3k articles anyone actually opens out of that pool.
  #
  # Why TAGS and not `source_type`: 83,487 of 85,157 articles carry a NULL `source_type`,
  # the whole harvest included, so `@source_authority` returns its 0.0 default for
  # essentially the entire corpus and cannot separate these cohorts at all. The sourcers
  # DO stamp a structural capture tag (`book-<id>`, `url-<id>`, `yt-<id>`, `doc-<id>`, plus
  # the bare kind tags below). Verified as a discriminator before being relied on: it marks
  # 98.5% of the June harvest and 0.4% of the pre-June curated set.
  #
  # THIRD-PARTY IS THE POSITIVE TEST, and first-party is the absence of a marker — never the
  # reverse. A first-party allowlist would have to enumerate every repo/topic tag Mark will
  # ever use, and each one it missed would silently demote genuinely first-party knowledge.
  # A missed marker here fails the other way: an unmarked harvest article is merely treated
  # as neutral, which is exactly today's behaviour.
  #
  # The weight is deliberately SMALLER than the measured effect. Priors here break near-ties
  # (RRF ties by construction), they do not dominate relevance — a 26.7x weight would let
  # provenance outrank the query. At the default strength 0.05 this is a ~2.5% edge on an
  # otherwise-equal pair, and it can never flip a cross-lane consensus winner (~2x a
  # single-lane hit).
  # SCOPE: these markers are the SOURCERS' own convention (the harvest skills stamp them at
  # knowledge_create time), not user-authored freeform tags, which is what makes them a
  # reliable signal. They are nonetheless GLOBAL, like `@category_authority` above, so a
  # future tenant that uses `book-`/`document` to mean something else would inherit this
  # prior. The failure is bounded and one-directional — a misread tag costs an article its
  # 0.5 boost, dropping it to the neutral 0.0 every article gets today — so it can never
  # demote anything below current behaviour. Revisit if a second real tenant appears; the
  # right fix then is config-driven weight tables for the whole module, not a special case
  # for this one term.
  @harvest_marker_prefixes ~w(book- url- yt- doc-)
  @harvest_marker_tags ~w(web-article newsletter inbox-harvest youtube document book)
  @first_party_authority 0.5
  @third_party_authority 0.0

  # A verdict-killed idea and a superseded article are demoted hard regardless of the
  # authority toggle — they are dead doctrine that must not outrank live doctrine.
  @kill_tag "verdict-kill"
  @demote_factor 0.5

  @doc """
  The recency decay `exp(-age_days / 30)` for a document last updated at `updated_at`,
  measured against `now`. Range `(0, 1]` (1.0 for a doc updated exactly now). This is the
  SINGLE SOURCE OF TRUTH for the decay — `knowledge_context` calls it too.

  `updated_at` is LAST-MUTATION time, so a re-embed / content-hash refresh resets a note's
  apparent freshness (see the module doc's warning). There is no authored-time fallback.
  """
  @spec recency_decay(DateTime.t(), DateTime.t()) :: float()
  def recency_decay(updated_at, now) do
    age_days = DateTime.diff(now, updated_at, :second) / 86_400.0
    :math.exp(-age_days / @decay_tau_days)
  end

  @doc """
  The bounded recency FACTOR to multiply a fused score by: `1 - w + w * decay`, in
  `[1 - w, 1]`. A `recency_weight` of 0 (or a nil `updated_at`) makes recency a no-op
  (factor 1.0), so the fused ordering is preserved exactly.
  """
  @spec recency_factor(DateTime.t() | nil, DateTime.t(), float()) :: float()
  def recency_factor(_updated_at, _now, recency_weight) when recency_weight <= 0.0, do: 1.0
  def recency_factor(nil, _now, _recency_weight), do: 1.0

  def recency_factor(updated_at, now, recency_weight) do
    1.0 - recency_weight + recency_weight * recency_decay(updated_at, now)
  end

  @doc """
  The bounded authority FACTOR for a result map, centered on 1.0 and clamped to
  `[floor, ceiling]`. `strength` scales the combined category + source_type prior; a
  `strength` of 0 makes authority a no-op (factor 1.0).

  NOTE the band is effectively ONE-SIDED: every category/source weight is >= 0 and
  `strength` >= 0, so `1 + strength*(cat+src)` is always >= 1.0 and the `floor` (0.9 in
  the default config) is never hit — the reachable range is `[1.0, ceiling]`. This factor
  only ever BOOSTS; demoting dead doctrine below neutral is `demotion_factor/1`'s job.
  """
  @spec authority_factor(map(), float(), float(), float()) :: float()
  def authority_factor(_result, strength, _floor, _ceiling) when strength <= 0.0, do: 1.0

  def authority_factor(result, strength, floor, ceiling) do
    cat = category_authority(Map.get(result, :category))
    src = source_authority(Map.get(result, :source_type))
    prov = provenance_authority(Map.get(result, :tags))

    (1.0 + strength * (cat + src + prov))
    |> max(floor)
    |> min(ceiling)
  end

  @doc """
  The provenance weight for a result's `tags`: `#{@first_party_authority}` for first-party
  knowledge, `#{@third_party_authority}` for third-party harvested material (#251).

  Third-party is the POSITIVE test — a structural capture tag stamped by a sourcer
  (`book-`/`url-`/`yt-`/`doc-` prefixes, or a bare kind tag). First-party is the absence of
  one, so a marker this function does not know leaves the article neutral rather than
  demoting real first-party knowledge. `nil` tags are first-party (an article no sourcer
  stamped).
  """
  @spec provenance_authority([String.t()] | nil) :: float()
  def provenance_authority(nil), do: @first_party_authority

  def provenance_authority(tags) when is_list(tags) do
    if Enum.any?(tags, &harvest_marker?/1) do
      @third_party_authority
    else
      @first_party_authority
    end
  end

  def provenance_authority(_), do: @first_party_authority

  defp harvest_marker?(tag) when is_binary(tag) do
    tag in @harvest_marker_tags or
      Enum.any?(@harvest_marker_prefixes, &String.starts_with?(tag, &1))
  end

  defp harvest_marker?(_), do: false

  @doc """
  The demotion FACTOR for dead doctrine: `#{@demote_factor}` when the result carries the
  `#{@kill_tag}` tag or is `:superseded`, else 1.0. Independent of the authority toggle.
  """
  @spec demotion_factor(map()) :: float()
  def demotion_factor(result) do
    tags = Map.get(result, :tags) || []
    status = Map.get(result, :status)

    # The `:superseded` half is DEFENSIVE: the default search path filters to one status
    # atom (published), so a superseded row never reaches this function unless a caller
    # relaxes the filter (status: nil pools all statuses). The `verdict-kill` half is live
    # on the default path — a killed idea can still be published. See the moduledoc.
    if @kill_tag in tags or status == :superseded or status == "superseded" do
      @demote_factor
    else
      1.0
    end
  end

  @doc """
  The combined prior multiplier for a result map: `recency_factor * authority_factor *
  demotion_factor`. `authority?` gates only the (bounded) authority prior; recency and the
  dead-doctrine demotion always apply (recency is a no-op when `recency_weight <= 0`).
  """
  @spec multiplier(map(), keyword()) :: float()
  def multiplier(result, opts) do
    now = Keyword.fetch!(opts, :now)
    recency_weight = Keyword.fetch!(opts, :recency_weight)
    authority? = Keyword.fetch!(opts, :authority?)
    strength = Keyword.fetch!(opts, :strength)
    floor = Keyword.fetch!(opts, :floor)
    ceiling = Keyword.fetch!(opts, :ceiling)

    recency = recency_factor(Map.get(result, :updated_at), now, recency_weight)
    authority = if authority?, do: authority_factor(result, strength, floor, ceiling), else: 1.0

    recency * authority * demotion_factor(result)
  end

  defp category_authority(nil), do: @default_category_authority

  defp category_authority(category) do
    Map.get(@category_authority, to_string(category), @default_category_authority)
  end

  defp source_authority(nil), do: @default_source_authority

  defp source_authority(source_type) do
    Map.get(@source_authority, to_string(source_type), @default_source_authority)
  end
end
