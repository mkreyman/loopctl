defmodule Loopctl.Repo.Migrations.CreateChannelPosts do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:channel_posts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      # Server-stamped from the verified key identity — a post always has an author.
      # FK to agents so attribution can never dangle (matches token_usage_reports).
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false

      # Client-supplied, informational, spoofable — never used for authorization.
      # Length-bounded in the changeset (see ChannelPost.create_changeset).
      add :session_id, :text, null: true
      add :host, :text, null: true

      # Optional per-session working-state slot key. No message-type taxonomy.
      # Insert-with-unique-reject in US-39.1; on_conflict upsert lands in US-39.2.
      add :key, :text, null: true

      add :body, :text, null: false
      add :refs, :map, null: true

      # Uniform 30-day retention; set server-side in Loopctl.Coordination.
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Recent-reads path: WHERE tenant_id = ? AND project_id = ? ORDER BY inserted_at DESC.
    create index(:channel_posts, [:tenant_id, :project_id, "inserted_at DESC"],
             name: :channel_posts_recent_idx
           )

    # TTL sweep path (US-39.5): delete WHERE expires_at <= now().
    create index(:channel_posts, [:expires_at])

    # Per-SESSION keyed upsert slot: two concurrent sessions writing key "session_goal"
    # do not clobber each other (session_id participates in the uniqueness). Partial —
    # only keyed posts are constrained; keyless posts are append-only.
    create unique_index(:channel_posts, [:tenant_id, :project_id, :session_id, :key],
             where: "key IS NOT NULL",
             name: :channel_posts_session_key_uidx
           )

    # Defense-in-depth: production isolation is AdminRepo + explicit tenant_id filter;
    # RLS is the second layer (ENABLE, not FORCE — same as every other tenant table).
    enable_rls(:channel_posts)
  end
end
