defmodule Loopctl.Repo.Migrations.AddScoredDispositionBaseToRetrievalSnapshots do
  use Ecto.Migration

  @moduledoc """
  Gives the search-disposition trio the denominator it actually partitions.

  `searches_reformulated` / `searches_quiet` shipped in
  `20260817173100_add_origin_metrics_to_retrieval_snapshots` as a partition of `searches`.
  They never were one, and the published figure was wrong in two independent ways
  (both are documented at `Loopctl.Knowledge.RetrievalMetrics.reformulation_exists/1`):

    * it scored on `api_key_id`, and only TWO keys search this system, with a 127-second
      median gap between consecutive searches on one of them — so the metric was a function
      of search DENSITY and reported 97% where the session-scoped figure is 27%;
    * it compared `search_id` without the query text, so a verbatim retry counted as a
      reformulation (142 of 311 flagged rows on 2026-08-17).

  Narrowing the numerator is not enough on its own: a search can only be SCORED for
  reformulation if it carries a session identity, and if it comes from a channel capable of
  reacting to a result at all — the recall hook and the session-start auto-query emit one
  distilled query per prompt and never see what came back. Those rows are not quiet; they are
  unscoreable, and folding an `n/a` into a bucket named "quiet" publishes a structural blind
  spot as an observation.

  So the base itself becomes a column:

    * `searches_scored` — qualifying search calls that could be observed reformulating.
    * `searches_scored_with_follow_through` — of those, the ones that opened something.

  With `searches_reformulated` and `searches_quiet` these partition `searches_scored`
  exactly. `searches - searches_scored` is unscoreable traffic and must be reported as such.

  No separate "computed from" marker is needed, and that is deliberate: a pre-migration row
  carries `searches_scored = 0`, and a partition over a zero base is self-evidently
  uncomputed. (The prior migration's moduledoc promised an `origin_metrics_from` field in the
  payload for exactly this purpose; it was never implemented, which is why this one encodes
  the same information structurally instead of in a parallel marker that can go missing.)

  Both columns default to 0 so historical snapshots stay readable.
  """

  def change do
    alter table(:retrieval_metric_snapshots) do
      add :searches_scored, :integer, default: 0, null: false
      add :searches_scored_with_follow_through, :integer, default: 0, null: false
    end
  end
end
