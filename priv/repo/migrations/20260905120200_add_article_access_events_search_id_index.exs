defmodule Loopctl.Repo.Migrations.AddArticleAccessEventsSearchIdIndex do
  use Ecto.Migration

  @moduledoc """
  Indexes the surfacing lookup `POST /api/v1/recall/:recall_id/referenced` runs.

  `Knowledge.Analytics.surfaced_article_ids/2` filters `metadata->>'search_id'`, which no
  existing index covers: the closest is `article_access_events_surface_lookup_idx`
  (tenant_id, article_id, accessed_at) WHERE access_type = 'search', so the planner seeks
  on `tenant_id` and then applies the JSON key as a heap filter — a scan of every
  surfacing impression the tenant has ever written. Impressions outnumber reads ~50:1
  (see `Analytics.@read_access_types`), the lookup is SYNCHRONOUS on a request path, and
  it runs on `AdminRepo`, whose pool is 3.

  Partial on `access_type = 'search'` because that is the only type the lookup reads, and
  `CONCURRENTLY` because this table is large in production and an exclusive lock on it
  would stall every recorder.

  `create_if_not_exists` + explicit `up`/`down`, per `20260827121000`: plain
  `create index(concurrently: true)` emits no `IF NOT EXISTS`, so an interrupted build
  leaves an INVALID index and no migration row, and every later deploy trips over it.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up, do: create_if_not_exists(search_id_index())
  def down, do: drop_if_exists(search_id_index())

  defp search_id_index do
    index(:article_access_events, [:tenant_id, "(metadata->>'search_id')"],
      where: "access_type = 'search'",
      name: :article_access_events_search_id_idx,
      concurrently: true
    )
  end
end
