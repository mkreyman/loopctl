defmodule Loopctl.Knowledge.RetrievalMetricSnapshot do
  @moduledoc """
  A daily retrieval-precision snapshot (agents' KB #3). `precision` is the share of a
  day's RECORDED search RESULTS the agent then opened (search → get/context within
  `window_seconds`) — a mechanical proxy for retrieval quality, tracked over time.

  `searched` counts RECORDED SURFACED RESULTS (one row per result a search put in front
  of an agent, capped at the first
  #{Loopctl.Knowledge.Analytics.max_recorded_search_results()} per call), never search
  calls — reading it as the latter is #582. Because of that cap `precision` is
  precision@#{Loopctl.Knowledge.Analytics.max_recorded_search_results()}, not precision
  over a call's full result set, and an open of a result ranked beyond the cap is in
  neither term. The call-level series added by that fix answers the other question
  without redefining this one:
  `searches` (distinct QUERY-BEARING search calls), `searches_with_follow_through` /
  `search_follow_through` (the share of CALLS that led to an open), and
  `results_returned` (the true un-truncated result count for those same calls, since
  only the first
  #{Loopctl.Knowledge.Analytics.max_recorded_search_results()} results per search are
  recorded).

  The four call-level columns are computed over a per-ROW subset: a row counts only if
  it carries a `search_id` (nothing written before #582 does) and its `mode` is not a
  query-less enumeration (`list` / `list_keyset`, written by the browse paths). So a day
  that MIXES qualifying and non-qualifying rows — every day spanning the #582 deploy
  does — carries a PARTIAL figure, not `0`; only a day with no qualifying row at all
  reads `0`/`0.0`. For the same reason `results_returned` is NOT comparable to
  `searched`: they aggregate different row populations, and `results_returned <
  searched` is the normal shape of a legacy-heavy or browse-heavy day.

  `precision` — and `precision` ALONE — is gameable by returning fewer results: its
  denominator counts surfaced RESULTS, so a narrower page raises the ratio with no better
  retrieval whatsoever. The two follow-through rates divide CALL counts, which a narrower
  page does not shrink, so they do not move that way. Read `precision` with the absolute
  `followed_through` and the volume columns, never alone.

  BOTH follow-through rates carry two biases that point OPPOSITE ways: the recording cap
  hides opens of results ranked beyond it (DOWN), and one open credits every search in the
  window that surfaced that article (UP). They share `with_follow_through/2`, so neither is
  exempt — and the upward bias bites hardest on the scored rate, whose denominator is the
  smaller of the two. Full derivation, those biases, and the two structural exclusions
  (zero-result and keyless searches) are in `Loopctl.Knowledge.RetrievalMetrics`.

  ## `scored_follow_through` is served from this schema but is NOT a column here

  The payloads built from this struct carry a third rate,
  `searches_scored_with_follow_through / searches_scored`, derived on read rather than
  stored — a pure ratio of two columns above, so computing it at presentation time makes
  every historical row correct with no migration. **It is the rate to quote when the
  question is whether AGENTS are consuming the KB**, because `search_follow_through`'s
  denominator still includes the recall-hook and session-start channels, which cannot
  follow through by construction. `nil`, never `0.0`, when nothing was scoreable. Adding
  a column for it would be a mistake: two sources for one number is how the published
  figure and the stored one drift.

  The `curated_*`/`retrieved_*` columns were dropped in #712. They could never report
  anything: nothing has ever set `curated_at`, and the buckets filtered a `mode` tag
  namespace (`hybrid_*`) that the default search path does not write (`combined_*`). See
  `Loopctl.Knowledge.RetrievalMetrics` for the full reasoning and the two conditions that
  would have to hold before reintroducing them.

  `tenant_id` is set programmatically, never cast.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "retrieval_metric_snapshots" do
    tenant_field()

    field :day, :date
    field :window_seconds, :integer
    field :searched, :integer, default: 0
    field :followed_through, :integer, default: 0
    field :precision, :float, default: 0.0
    field :searches, :integer, default: 0
    field :searches_with_follow_through, :integer, default: 0
    field :search_follow_through, :float, default: 0.0
    field :results_returned, :integer, default: 0

    # Unit: READS (get/context/drill rows), NOT surfaced results and NOT search calls.
    # `followed_through` above counts SURFACED RESULTS that were later opened, so it is not
    # comparable with these three — the naming keeps the units legible.
    field :attributed_opens, :integer, default: 0
    field :cross_key_opens, :integer, default: 0
    field :direct_opens, :integer, default: 0

    # Unit: SEARCH CALLS. These four partition each other, not `searches`:
    # `searches_scored_with_follow_through + searches_reformulated + searches_quiet ==
    # searches_scored`. A search is SCORED only if it carries a session identity and comes
    # from a channel that can react to a result at all, so `searches - searches_scored` is
    # unscoreable traffic — an `n/a`, never a quiet search (#711). A pre-#711 row has
    # `searches_scored = 0`, which is how "not computed" is told apart from "nothing scored".
    field :searches_scored, :integer, default: 0
    field :searches_scored_with_follow_through, :integer, default: 0
    field :searches_reformulated, :integer, default: 0
    field :searches_quiet, :integer, default: 0

    # Which set of DEFINITIONS produced this row (see `RetrievalMetrics.@metric_version`).
    # Rows are comparable only within a version. `0` predates the stamp.
    field :metric_version, :integer, default: 0

    field :computed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields [
    :day,
    :window_seconds,
    :searched,
    :followed_through,
    :precision,
    :searches,
    :searches_with_follow_through,
    :search_follow_through,
    :results_returned,
    :attributed_opens,
    :cross_key_opens,
    :direct_opens,
    :searches_scored,
    :searches_scored_with_follow_through,
    :searches_reformulated,
    :searches_quiet,
    :metric_version,
    :computed_at
  ]

  @doc "Changeset for a snapshot. `tenant_id` is set on the struct, not cast."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(snapshot \\ %__MODULE__{}, attrs) do
    snapshot
    |> cast(attrs, @cast_fields)
    |> validate_required([
      :day,
      :window_seconds,
      :searched,
      :followed_through,
      :precision,
      :searches,
      :searches_with_follow_through,
      :search_follow_through,
      :results_returned,
      :computed_at
    ])
    |> unique_constraint([:tenant_id, :day, :window_seconds],
      name: :retrieval_metric_snapshots_tenant_day_window_index
    )
  end
end
