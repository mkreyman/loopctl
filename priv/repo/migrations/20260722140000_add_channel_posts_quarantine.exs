defmodule Loopctl.Repo.Migrations.AddChannelPostsQuarantine do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  Quarantine + rescan bookkeeping for `channel_posts` (issue #499).

  The US-39.1 secret denylist is a WRITE-TIME gate only: a credential shape added
  to `Loopctl.Security.SecretDenylist` AFTER a post was written never re-examines
  that post, and a channel post is re-broadcast into every new session on the repo
  for its whole 30-day TTL. `Loopctl.Workers.ChannelPostRescanWorker` closes that
  gap by re-scanning live posts with the CURRENT pattern set.

  Three columns, all set PROGRAMMATICALLY (never castable):

    * `quarantined_at` — NULL = live. A non-NULL stamp means the rescan flagged the
      post; every coordination READ excludes it, so it stops being injected into new
      sessions. The row is DELIBERATELY retained (not hard-deleted): the denylist is a
      prefix HEURISTIC, so a false positive that silently destroyed a coordination post
      would be worse than a flagged one. Redaction stays the explicit operator action
      (`Loopctl.Coordination.delete_post/5`).
    * `quarantine_reason` — a BOUNDED marker naming the offending FIELD names only
      (e.g. `"secret_denylist: body,refs"`). It must NEVER carry the matched value or
      any post content — that would copy the leaked credential into a second column.
    * `rescanned_at` — the resumable cursor. A run stamps every post it scanned, so
      successive bounded runs advance instead of re-scanning the same head batch, and a
      denylist revision bump (`SecretDenylist.revision/0`) makes every previously
      scanned row eligible again — that retroactivity is the whole point of #499.

  `CREATE INDEX CONCURRENTLY` outside a DDL transaction (migration lock disabled) so
  the build takes no ACCESS EXCLUSIVE lock on `channel_posts`, the hottest write
  table — the repo's documented convention (20260720120000, 20260719120000).

  RLS: `channel_posts` already has ROW LEVEL SECURITY ENABLED; added columns inherit
  the existing policies and need nothing extra.
  """

  def up do
    alter table(:channel_posts) do
      add :quarantined_at, :utc_datetime_usec
      add :quarantine_reason, :text
      add :rescanned_at, :utc_datetime_usec
    end

    # Serves the rescan worker's bounded candidate scan: live (non-quarantined) rows
    # ordered oldest-scan-first (never-scanned rows lead), tie-broken by the monotonic
    # `seq` so a batch boundary is stable across runs.
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS channel_posts_rescan_idx
    ON channel_posts (rescanned_at ASC NULLS FIRST, seq ASC)
    WHERE quarantined_at IS NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS channel_posts_rescan_idx")

    alter table(:channel_posts) do
      remove :rescanned_at
      remove :quarantine_reason
      remove :quarantined_at
    end
  end
end
