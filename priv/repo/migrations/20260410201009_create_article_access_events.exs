defmodule Loopctl.Repo.Migrations.CreateArticleAccessEvents do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:article_access_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :article_id, references(:articles, type: :binary_id, on_delete: :delete_all),
        null: false

      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :delete_all),
        null: false

      add :access_type, :string, null: false
      add :metadata, :map, null: false, default: %{}
      add :accessed_at, :utc_datetime_usec, null: false

      # No timestamps() — access events are immutable facts.
      # `accessed_at` is the only timestamp on this row.
    end

    # Per-article stats: usage trends and counts for a given article over time
    create index(:article_access_events, [:tenant_id, :article_id, :accessed_at],
             name: :article_access_events_tenant_article_time_idx
           )

    # Per-agent usage: what each api_key reads, ordered by recency
    create index(:article_access_events, [:tenant_id, :api_key_id, :accessed_at],
             name: :article_access_events_tenant_apikey_time_idx
           )

    # Recent activity feed across the tenant
    create index(:article_access_events, [:tenant_id, :accessed_at],
             name: :article_access_events_tenant_time_idx
           )

    # Filtered queries by access type (e.g., only "search" or only "context")
    create index(:article_access_events, [:tenant_id, :access_type, :accessed_at],
             name: :article_access_events_tenant_type_time_idx
           )

    # Enforce DESC ordering on the time-ordered indexes via fragment.
    # PostgreSQL can use forward indexes for ORDER BY DESC, but explicit
    # DESC indexes optimize the common "recent first" access pattern.
    execute(
      "CREATE INDEX article_access_events_recent_idx ON article_access_events (tenant_id, accessed_at DESC)",
      "DROP INDEX IF EXISTS article_access_events_recent_idx"
    )

    enable_rls(:article_access_events)
  end
end
