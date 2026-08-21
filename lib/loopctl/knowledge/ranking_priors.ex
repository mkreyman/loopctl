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
    * **Category authority** — a bounded prior derived from `category` ALONE, centered on
      1.0 and clamped to a narrow band, so it re-ranks NEAR-TIES
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

  # PROVENANCE PRIORS REMOVED (2026-08-21, owner decision).
  #
  # This module carried two priors keyed on WHERE A DOCUMENT CAME FROM: a source_type
  # table ("human/reviewed provenance over raw automated ingests") and a first-party /
  # third-party split keyed on the sourcers' capture tags (`book-`/`url-`/`yt-`/`doc-`).
  # Both are gone, and the reason they must not come back is worth more than the code was.
  #
  # THE EVIDENCE THEY RESTED ON DID NOT HOLD. The provenance prior cited a 26.7x
  # per-article read rate. That statistic carries the harvest's own volume in its
  # denominator — third-party was ~96% of the corpus — so with a roughly fixed query rate
  # it falls ~1/N mechanically, whatever the material is worth. The number that actually
  # answers "is this material worse?" is SURFACED-TO-OPENED CONVERSION, and nobody had
  # taken it. Measured 2026-08-21 over the whole history of `article_access_events`, using
  # this module's own discriminator and stratified by rank to remove position bias:
  #
  #   rank | first-party (+0.5) | third-party (0.0)
  #      1 |  8.30% (6,144)     |  4.48% (3,304)
  #      2 |  3.91% (5,390)     |  2.75% (3,927)
  #      3 |  2.57% (5,167)     |  2.41% (4,019)
  #      4 |  1.95% (4,916)     |  1.96% (3,477)
  #      5 |  1.57% (4,774)     |  1.74% (3,455)
  #
  # Converged by rank 3 and INVERTED by rank 4. Controlling for position, provenance
  # carried almost no signal — and the residual top-of-list gap is partly the prior marking
  # its own homework, since it lifted first-party into the positions where conversion is
  # highest and that conversion then read as evidence for the prior.
  #
  # The discriminator's own verification had also gone stale: it was justified as marking
  # "98.5% of the June harvest and 0.4% of the pre-June curated set". On the live corpus in
  # August the split was 82,851 / 3,562 and no longer separated the cohorts that cleanly.
  #
  # THE OWNER'S REASONING, which outlives the measurement (Mark, 2026-08-21):
  #
  #   "If we heavily favor the internally produced knowledge, we would never learn anything
  #    new and unexpectedly useful. Besides, agents improve and I don't want less
  #    intelligent agents to decide what to pick for more intelligent future agents. I want
  #    the decision of what knowledge to use and how to combine it to be done on the
  #    receiving side."
  #
  # Two failure modes that argument names, neither of which a measurement would catch:
  # a provenance prior is a CLOSED LOOP (demote unread material, it stays unread, cite the
  # ratio as proof), and it is a RATCHET (a weight shipped once by one model constrains
  # every future receiver regardless of how much more capable that receiver is).
  #
  # WHAT IS STILL ALLOWED HERE, so this is a rule and not a mood:
  #   * relevance itself (RRF over the lanes) — that IS the retrieval, not a prior;
  #   * DELIBERATE EDITORIAL ACTS — `verdict-kill`, `:superseded`, curation. Someone judged
  #     the content on its merits;
  #   * FORM, not origin — the MOC-hub demotion below. A navigation stub is not an answer
  #     whoever generated it;
  #   * `@category_authority` above, KEPT by explicit owner decision on the same date: it
  #     keys on an editorial classification, not on how a document was ingested.
  #
  # What is forbidden is a weight keyed on HOW A DOCUMENT GOT IN — its sourcer, its capture
  # tag, its source_type, its ingestion batch. If a future measurement seems to justify one,
  # re-read the table above first: that is what the last one looked like.
  #
  # WHAT WOULD OVERTURN THIS: the owner saying so, or a conversion measurement that is
  # rank-stratified, uses a discriminator verified against the CURRENT corpus, and still
  # shows a durable gap. Reads-per-article is not that measurement and never was.

  # A verdict-killed idea and a superseded article are demoted hard regardless of the
  # authority toggle — they are dead doctrine that must not outrank live doctrine.
  @kill_tag "verdict-kill"
  @demote_factor 0.5

  # Hubs get their OWN factor, and it must be STRICTLY BELOW 0.5 — 0.5 is the
  # dead-doctrine constant and, against post-#470 RRF, it is exactly the value that
  # cancels one fusion lane and nothing more.
  #
  # The arithmetic: a fused score is `Σ_lane weight/(60 + rank)`. A hub that tops BOTH
  # lanes scores `2w/61`; a real answer that tops ONE lane scores `w/61`. At factor f the
  # hub scores `2f·w/61`, so it still WINS unless `2f < 1`, i.e. `f < 0.5`. At exactly
  # 0.5 the two TIE and the `{final_score, id}` tiebreak decides by UUID — a coin flip.
  # #654 shipped 0.5 and therefore only half-demoted the hubs it measured.
  #
  # 0.25 puts a two-lane rank-1 hub at half a one-lane rank-1 answer: it loses to every
  # genuine top hit while staying well inside the result list, which is the "demoted, not
  # excluded" contract the block above promises.
  @hub_demote_factor 0.25

  # MOC / "Index: <tag>" hubs (#654). Generated by KnowledgeMocWorker, these are
  # NAVIGATION, not answers: the body is a list of member titles grouped by category.
  # That composition makes them match a great many queries — a hub for a broad tag
  # contains dozens of real titles and their vocabulary — while carrying no knowledge
  # of their own.
  #
  # Measured on the live corpus (2026-08-11, 30 days, 677 real multi-word queries):
  # a MOC hub was RANK 1 on 12.0% of them and in the top 3 on 19.8%. Over the same
  # window the 52 hubs were opened ONCE in their entire lifetime. So on one real
  # question in eight the best answer on offer was a stub nobody wants, and one slot
  # in five of the top three was spent on one — which is a large part of why search
  # felt empty while the corpus was fine.
  #
  # Demoted rather than EXCLUDED: a hub is genuinely the right result for a browse
  # ("what do we know about deployment?"), and it stays reachable both by an explicit
  # title search and through `progressive_index/3`, whose hub enrichment walks the
  # relates_to graph (`progressive_hub_neighbor_ids/3`) and never consults this
  # ranking, so nothing here can hide a hub from the browse surface it belongs to.
  #
  # Identified by the `moc:` IDEMPOTENCY-KEY PREFIX the worker itself writes
  # (`idempotency_key: "moc:#{tag}"`, knowledge_moc_worker.ex), NOT by tags.
  #
  # Tags were the original signal and were wrong in a way measurement could not show:
  # `tags` is in `Article`'s `@cast_fields` AND in `update_changeset/2`, and the #331
  # KB-content carve-out puts `knowledge_update` at AGENT role — so any agent key could
  # add `hub` + `moc` to ANOTHER agent's article and silently halve its search rank.
  # A ranking penalty writable by the party it penalises is not a ranking signal.
  #
  # `idempotency_key` is cast on CREATE only — `update_changeset/2` does not cast it — so
  # the worst an agent can do is mark its OWN new article as a hub, which demotes only
  # itself. Self-demotion is harmless; demoting a rival is not.
  @moc_key_prefix "moc:"

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
  `[floor, ceiling]`. `strength` scales the CATEGORY prior — the only one left; a
  `strength` of 0 makes authority a no-op (factor 1.0).

  It keys on `:category` and nothing else. The `source_type` and capture-tag provenance
  priors were removed on 2026-08-21 — see the long note above `@kill_tag` for why, and for
  what would have to be true to bring one back.

  NOTE the band is effectively ONE-SIDED: every category weight is >= 0 and
  `strength` >= 0, so `1 + strength*cat` is always >= 1.0 and the `floor` (0.9 in
  the default config) is never hit — the reachable range is `[1.0, ceiling]`. This factor
  only ever BOOSTS; demoting dead doctrine below neutral is `demotion_factor/1`'s job.
  """
  @spec authority_factor(map(), float(), float(), float()) :: float()
  def authority_factor(_result, strength, _floor, _ceiling) when strength <= 0.0, do: 1.0

  def authority_factor(result, strength, floor, ceiling) do
    cat = category_authority(Map.get(result, :category))

    (1.0 + strength * cat)
    |> max(floor)
    |> min(ceiling)
  end

  @doc """
  The demotion FACTOR for a result that should not win a question: `#{@demote_factor}`
  for dead doctrine (the `#{@kill_tag}` tag or `:superseded`), `#{@hub_demote_factor}`
  for a MOC/index hub, else 1.0. Independent of the authority toggle.

  Dead doctrine and hubs are demoted for DIFFERENT reasons and by different amounts —
  see `@hub_demote_factor` for why one shared 0.5 could not do both jobs.

  Uses the process-wide hub-demotion toggle; call `demotion_factor/2` to pass it
  explicitly and keep the call pure.
  """
  @spec demotion_factor(map()) :: float()
  def demotion_factor(result), do: demotion_factor(result, hub_demotion?: hub_demotion_enabled?())

  @doc """
  `demotion_factor/1` with the hub toggle supplied explicitly (pure).

  Dead-doctrine demotion is NOT toggleable — superseded and verdict-killed material must
  never outrank live doctrine, and there is no tenant for whom that is wrong.
  """
  @spec demotion_factor(map(), keyword()) :: float()
  def demotion_factor(result, opts) do
    tags = Map.get(result, :tags) || []
    status = Map.get(result, :status)

    # The `:superseded` half is DEFENSIVE: the default search path filters to one status
    # atom (published), so a superseded row never reaches this function unless a caller
    # relaxes the filter (status: nil pools all statuses). The `verdict-kill` half is live
    # on the default path — a killed idea can still be published. See the moduledoc.
    cond do
      @kill_tag in tags or status == :superseded or status == "superseded" -> @demote_factor
      Keyword.get(opts, :hub_demotion?, true) and moc_hub?(result) -> @hub_demote_factor
      true -> 1.0
    end
  end

  @doc """
  Whether a result map is a generated MOC / "Index: <tag>" hub — navigation rather than
  an answer.

  Reads `:idempotency_key`, which only the MOC worker writes and which no agent-role
  update can change (see `@moc_key_prefix`). A result map that does not project
  `:idempotency_key` is never a hub — fail OPEN, because the cost of missing a demotion
  is one stub ranked too high, while the cost of guessing is demoting a real answer.
  """
  @spec moc_hub?(map()) :: boolean()
  def moc_hub?(%{} = result) do
    case Map.get(result, :idempotency_key) do
      key when is_binary(key) -> String.starts_with?(key, @moc_key_prefix)
      _ -> false
    end
  end

  def moc_hub?(_), do: false

  @doc """
  Whether the MOC-hub demotion is active (`:knowledge_hub_demotion_enabled`, default
  `true`), mirroring `:knowledge_authority_prior_enabled`.

  A kill switch exists because hub-ness is inferred, corpus-wide and compile-time: if a
  tenant's MOC worker output is genuinely what its agents want to read, this turns the
  penalty off without a deploy.
  """
  @spec hub_demotion_enabled?() :: boolean()
  def hub_demotion_enabled? do
    Application.get_env(:loopctl, :knowledge_hub_demotion_enabled, true)
  end

  @doc """
  The combined prior multiplier for a result map: `recency_factor * authority_factor *
  demotion_factor`. `authority?` gates only the (bounded) authority prior and
  `hub_demotion?` only the MOC-hub demotion; recency and the dead-doctrine demotion
  always apply (recency is a no-op when `recency_weight <= 0`).
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

    hub? = Keyword.get(opts, :hub_demotion?, true)

    recency * authority * demotion_factor(result, hub_demotion?: hub?)
  end

  defp category_authority(nil), do: @default_category_authority

  defp category_authority(category) do
    Map.get(@category_authority, to_string(category), @default_category_authority)
  end
end
