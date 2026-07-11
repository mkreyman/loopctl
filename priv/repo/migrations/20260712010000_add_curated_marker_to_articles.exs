defmodule Loopctl.Repo.Migrations.AddCuratedMarkerToArticles do
  use Ecto.Migration

  @moduledoc """
  US-31.1: a GOVERNED "curated" marker for Knowledge Wiki articles.

  `curated_at`/`curated_by` are a dedicated, NON-castable marker: they are absent
  from `Article`'s `@cast_fields` (create/update changesets) and are writable ONLY
  via `Article.curation_changeset/3`, invoked from the governed
  `Loopctl.Knowledge.mark_curated/3` path. This mirrors the `embedding` isolation
  precedent so an agent cannot self-promote its own article to "authoritative" by
  setting `category`/`metadata` — which are agent-castable.

  A published article is "curated" iff `curated_at` is set (see
  `Loopctl.Knowledge.curated?/1`). The `articles` table already has
  `ENABLE ROW LEVEL SECURITY`; these are plain nullable columns, no new RLS surface.
  """

  def change do
    alter table(:articles) do
      # When set, the article carries the governed curated (authoritative) marker.
      add :curated_at, :utc_datetime_usec
      # Advisory label of the actor that marked it curated (e.g. "user:admin").
      add :curated_by, :string
    end

    # Partial index for the curated-source listing / hybrid resolver: only the
    # (small) set of published, marked-curated articles is indexed.
    create index(:articles, [:tenant_id, :scope],
             where: "curated_at IS NOT NULL AND status = 'published'",
             name: :articles_curated_published_idx
           )
  end
end
