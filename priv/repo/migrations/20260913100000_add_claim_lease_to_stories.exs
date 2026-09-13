defmodule Loopctl.Repo.Migrations.AddClaimLeaseToStories do
  use Ecto.Migration

  # The ADD COLUMNs are catalog-only (a nullable column, and an integer with a CONSTANT
  # default, which Postgres 11+ records without rewriting a row), but the index is built
  # CONCURRENTLY so `stories` — the hottest table — is never write-locked for its scan.
  # CONCURRENTLY cannot run inside a transaction. Same pattern as
  # 20260807153000_add_lifecycle_entered_at_to_stories.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  A story claim gets a lease and a fence (#803).

  - `claimed_until` — when the claim's lease runs out. Set by `Progress.claim_story/3`,
    extended by `Progress.renew_claim/3`, cleared by every path that releases the claim.
    NULL on every story claimed before this migration, and the reclaimer IGNORES a NULL
    lease: nothing renews those claims, so giving them a lease retroactively would release
    in-flight work on the first sweep after deploy.
  - `claim_epoch` — bumped by every claim AND every release, so a message carrying the
    epoch its sender was given stops matching the moment that claim ends.

  Neither column is in any changeset `cast` list; only `Progress` writes them.

  The partial index matches `Loopctl.Workers.ReclaimExpiredClaimsWorker`'s predicate, so
  the sweep reads only claimed rows that carry a lease.
  """

  def up do
    alter table(:stories) do
      add_if_not_exists :claimed_until, :utc_datetime_usec
      add_if_not_exists :claim_epoch, :integer, null: false, default: 0
    end

    flush()

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS stories_claimed_until_leased_idx
      ON stories (claimed_until)
      WHERE claimed_until IS NOT NULL AND agent_status IN ('assigned', 'implementing')
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS stories_claimed_until_leased_idx")

    alter table(:stories) do
      remove_if_exists :claim_epoch, :integer
      remove_if_exists :claimed_until, :utc_datetime_usec
    end
  end
end
