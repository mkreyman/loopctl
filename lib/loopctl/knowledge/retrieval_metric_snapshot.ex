defmodule Loopctl.Knowledge.RetrievalMetricSnapshot do
  @moduledoc """
  A daily retrieval-precision snapshot (agents' KB #3). `precision` is the share of a
  day's search RESULTS the agent then opened (search → get/context within
  `window_seconds`) — a mechanical proxy for retrieval quality, tracked over time.

  `searched` counts SURFACED RESULTS (one row per result a search put in front of an
  agent), never search calls — reading it as the latter is #582. The call-level series
  added by that fix answers the other question without redefining this one:
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

  Both ratios are gameable in the same direction — returning fewer results raises them
  with no better retrieval — so read them with the absolute `followed_through` and the
  volume columns, never alone. Full derivation and the two structural exclusions
  (zero-result and keyless searches) are in `Loopctl.Knowledge.RetrievalMetrics`.

  The `curated_*`/`retrieved_*` columns (US-31.2, AC-31.2.5) are the SAME searched /
  followed_through / precision breakdown, restricted to `article_access_events` whose
  `metadata->>'mode'` is `"hybrid_curated"` / `"hybrid_retrieved"` respectively — so an
  operator can tell whether the hybrid resolver's `:curated` answers are actually
  followed through on as often as `:retrieved` ones (a "prefer-curated silently hides
  better retrieval" regression would show up as `curated_precision` trending well below
  `retrieved_precision`). Rows written before US-31.2 (or by non-hybrid searches) simply
  carry `0`/`0.0` in these columns — same "additive, never breaking" convention as the
  rest of this schema.

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
    field :curated_searched, :integer, default: 0
    field :curated_followed_through, :integer, default: 0
    field :curated_precision, :float, default: 0.0
    field :retrieved_searched, :integer, default: 0
    field :retrieved_followed_through, :integer, default: 0
    field :retrieved_precision, :float, default: 0.0
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
    :curated_searched,
    :curated_followed_through,
    :curated_precision,
    :retrieved_searched,
    :retrieved_followed_through,
    :retrieved_precision,
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
      :curated_searched,
      :curated_followed_through,
      :curated_precision,
      :retrieved_searched,
      :retrieved_followed_through,
      :retrieved_precision,
      :computed_at
    ])
    |> unique_constraint([:tenant_id, :day, :window_seconds],
      name: :retrieval_metric_snapshots_tenant_day_window_index
    )
  end
end
