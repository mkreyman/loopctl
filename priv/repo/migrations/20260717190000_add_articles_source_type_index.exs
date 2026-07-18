defmodule Loopctl.Repo.Migrations.AddArticlesSourceTypeIndex do
  use Ecto.Migration

  # Supports the hourly IngestionHealth capture-silence scan
  # (Loopctl.Knowledge.IngestionHealth.detect/1): it joins articles to active
  # tenants, filters `inserted_at >= window_start`, groups by
  # (tenant_id, source_type) and reads max(inserted_at). The existing articles
  # indexes cover (tenant_id) and (tenant_id, source_id, inserted_at, id) but none
  # include source_type, so without this the scan reads ALL of a large-corpus
  # tenant's articles via the (tenant_id) index and filters source_type on the heap.
  # This composite makes the grouped scan selective on the hot read path.
  def change do
    create index(:articles, [:tenant_id, :source_type, :inserted_at])
  end
end
