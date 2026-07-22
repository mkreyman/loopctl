defmodule Loopctl.Knowledge.RankingPriors do
  @moduledoc """
  Pure, DB-free ranking priors applied on top of `Loopctl.Knowledge.search_combined/3`'s
  fused candidate list (#471, epic #468 — the Cerebras/Nick-Saraev RAG playbook).

  Two priors re-rank the fused output:

    * **Recency decay** — `exp(-age_days / 30)`, the SAME decay `knowledge_context` uses
      (`recency_decay/2` is the single source of truth for both). Applied as a BOUNDED
      factor `1 - w + w * decay` on the score, so a stale document is nudged down but a
      brand-new one is never lifted above a document with materially stronger relevance.
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
  The authority band (`[0.9, 1.1]` by default) can flip an exact/near tie but can NEVER
  flip a 2x-stronger consensus winner — which is precisely the "priors break ties, not
  dominate strong relevance" risk the issue calls out. The recency factor is likewise
  bounded in `[1 - w, 1]`.

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
  # Ordering rationale (verified by unit tests): curated doctrine
  # (decision/playbook/reference/finding) > structural knowledge (pattern/insight/
  # convention) > low-signal captured notes (entity/quote/question) > a speculative
  # `idea` > an uncategorized raw atomic note (the @default_category_authority floor).
  # Every weight is >= the floor, so the prior only ever REORDERS ties upward by
  # authority; dead-doctrine demotion (verdict-kill / superseded) is what pushes down.
  @category_authority %{
    "decision" => 1.0,
    "playbook" => 1.0,
    "reference" => 0.9,
    "finding" => 0.8,
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

  # A verdict-killed idea and a superseded article are demoted hard regardless of the
  # authority toggle — they are dead doctrine that must not outrank live doctrine.
  @kill_tag "verdict-kill"
  @demote_factor 0.5

  @doc """
  The recency decay `exp(-age_days / 30)` for a document last updated at `updated_at`,
  measured against `now`. Range `(0, 1]` (1.0 for a doc updated exactly now). This is the
  SINGLE SOURCE OF TRUTH for the decay — `knowledge_context` calls it too.
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
  """
  @spec authority_factor(map(), float(), float(), float()) :: float()
  def authority_factor(_result, strength, _floor, _ceiling) when strength <= 0.0, do: 1.0

  def authority_factor(result, strength, floor, ceiling) do
    cat = category_authority(Map.get(result, :category))
    src = source_authority(Map.get(result, :source_type))

    (1.0 + strength * (cat + src))
    |> max(floor)
    |> min(ceiling)
  end

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
