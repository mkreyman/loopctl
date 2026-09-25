defmodule Loopctl.Repo.Migrations.AddStoriesLeaseReclaimFailedAt do
  @moduledoc """
  When the reclaim sweep last failed to release this story's expired lease (#877 review round
  3). `Loopctl.Workers.ReclaimExpiredClaimsWorker` ranks a stamped lease behind every unstamped
  one in its tenant, so a tenant with more failing leases than its share of a batch still
  reaches its healthy ones. Written only by the worker and cleared by every release.

  Nullable, no default, no backfill and no manual step: every existing row starts NULL, which
  reads as "never failed", and an old instance still serving during the rolling deploy neither
  reads nor writes it. No new policy: `stories`' row-level policies apply to every column.
  """

  use Ecto.Migration

  def change do
    alter table(:stories) do
      add :lease_reclaim_failed_at, :utc_datetime_usec, null: true
    end
  end
end
