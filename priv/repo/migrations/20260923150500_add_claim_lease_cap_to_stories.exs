defmodule Loopctl.Repo.Migrations.AddClaimLeaseCapToStories do
  use Ecto.Migration

  @moduledoc """
  A claim taken for a runner dispatch gets a lease CAPPED at the dispatch's deadline (#879,
  US-44.5).

  - `claim_lease_cap` — the latest instant the claim's lease may ever reach. Written by
    `Loopctl.Progress.claim_story/3` when a caller passes `lease_until:`, which only
    `Loopctl.Delivery.Placement` does (placed_at + the dispatch's `wall_clock_seconds` +
    `DISPATCH_LEASE_GRACE_SECONDS`). `renew_claim/3` and `grant_renewal_grace/2` never move
    `claimed_until` past it, and every release clears it. NULL on every other claim, which
    keeps the global `STORY_CLAIM_LEASE_SECONDS` lease exactly as before.

  - `runner_dispatches.wall_clock_seconds_max` — the longest `wall_clock_seconds` any winning
    push of the dispatch carried (`Loopctl.Runners.DispatchLedger`). The runner's acceptance
    moves the claim's cap forward on it rather than on the latest push's clock, which a resume
    may have shortened while an earlier session still runs. NULL until the first push; a
    nullable column with no default, so adding it rewrites nothing.

  A COLUMN and never a `metadata` key, because `metadata` is cast and replaced wholesale by
  `PATCH /api/v1/stories/:id` — a cap one ordinary request could erase is not a cap. It is in
  no changeset `cast` list; only `Progress` writes it.

  The CHECK makes "absolute" a database fact rather than a property of three code paths: a
  lease never runs past its cap, whoever writes it. Added `NOT VALID` and then `VALIDATE`d so
  it never takes an ACCESS EXCLUSIVE full scan of `stories`, the hottest table (the repo's
  online-constraint pattern, as in `20260724170001`). Every existing row has a NULL cap, so it
  validates trivially.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    alter table(:stories) do
      add_if_not_exists :claim_lease_cap, :utc_datetime_usec
    end

    alter table(:runner_dispatches) do
      add_if_not_exists :wall_clock_seconds_max, :integer
    end

    flush()

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'stories_claim_lease_within_cap'
      ) THEN
        ALTER TABLE stories
          ADD CONSTRAINT stories_claim_lease_within_cap
          CHECK (claim_lease_cap IS NULL OR claimed_until IS NULL OR claimed_until <= claim_lease_cap)
          NOT VALID;
      END IF;
    END $$;
    """)

    execute("ALTER TABLE stories VALIDATE CONSTRAINT stories_claim_lease_within_cap")
  end

  def down do
    execute("ALTER TABLE stories DROP CONSTRAINT IF EXISTS stories_claim_lease_within_cap")

    alter table(:runner_dispatches) do
      remove_if_exists :wall_clock_seconds_max, :integer
    end

    alter table(:stories) do
      remove_if_exists :claim_lease_cap, :utc_datetime_usec
    end
  end
end
