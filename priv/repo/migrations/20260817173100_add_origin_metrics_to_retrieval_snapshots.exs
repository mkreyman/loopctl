defmodule Loopctl.Repo.Migrations.AddOriginMetricsToRetrievalSnapshots do
  use Ecto.Migration

  @moduledoc """
  Persists the exactly-attributed follow-through counters alongside the correlated ones.

  `GET /api/v1/knowledge/retrieval_metrics` (and the `knowledge_retrieval_metrics` MCP tool)
  serve PERSISTED snapshots, not live computation, so a metric that is not a column here is
  invisible to every consumer.

  The existing `followed_through` / `search_follow_through` pair stays exactly as it is —
  same definition, same correlation, so the committed series remains comparable across this
  migration. These columns are added BESIDE it:

    * `attributed_opens` / `cross_key_opens` / `direct_opens` — unit is READS, not surfaced
      results and not search calls. The moduledoc discipline about units is load-bearing
      here: `followed_through` counts SURFACED RESULTS that were later opened, so it is not
      comparable with these. `cross_key_opens` is the one the injected recall hook lands in,
      and it was structurally unrepresentable before.
    * `searches_reformulated` / `searches_quiet` — unit is SEARCH CALLS. With the existing
      `searches_with_follow_through` these form a partition of `searches`: a search was
      opened, or it was followed by another query from the same key inside the window, or
      neither.

  Why the trichotomy matters more than another ratio: this repo's own
  `docs/runbooks/search-events-analysis.md` warns that "an agent whose question is answered
  by the snippet correctly opens nothing, and that is a success this metric scores as a
  failure". Splitting `reformulated` out of the not-opened bucket does not resolve that
  ambiguity — `quiet` is still "sufficed OR ignored" — but it removes the one case that is
  unambiguously a FAILURE and was being averaged in with the successes. Do not rename
  `quiet` to anything that asserts satisfaction.

  All columns default to 0 so historical snapshots stay readable; a 0 in a pre-migration row
  means "not computed", which is why the payload reports `origin_metrics_from` alongside.
  """

  def change do
    alter table(:retrieval_metric_snapshots) do
      add :attributed_opens, :integer, default: 0, null: false
      add :cross_key_opens, :integer, default: 0, null: false
      add :direct_opens, :integer, default: 0, null: false
      add :searches_reformulated, :integer, default: 0, null: false
      add :searches_quiet, :integer, default: 0, null: false
    end
  end
end
