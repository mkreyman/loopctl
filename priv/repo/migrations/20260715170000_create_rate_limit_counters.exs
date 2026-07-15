defmodule Loopctl.Repo.Migrations.CreateRateLimitCounters do
  use Ecto.Migration

  # GLOBAL (non-tenant) windowed-counter store backing the cluster-global
  # Postgres RateLimiter (US-38.2, Epic 38, GH #353). One row per
  # `(bucket, window_start)` bucket holds an atomically-incremented request
  # count for a fixed time window. Selected via config (`:rate_limiter`); when
  # UNSELECTED (the default) this table is simply never written to and the
  # limiter stays node-local ETS/Hammer — exactly today's behaviour.
  #
  # ## Access path (mirrors `system_configs`)
  #
  # No `tenant_id` — tenant/key isolation lives entirely in the `bucket` STRING
  # (e.g. `"key:<uuid>"`, `"tenant:<uuid>"`, `"provider_admission:embedding:<uuid>"`).
  # The limiter runs CROSS-TENANT (one shared counter store for all tenants), so
  # like `system_configs` ALL access goes through `Loopctl.AdminRepo` (BYPASSRLS
  # in prod, table owner in dev/test) — NEVER `Loopctl.Repo`. Per CLAUDE.md RLS
  # rule 4 we ENABLE (never FORCE) Row Level Security with deliberately NO
  # tenant_isolation policy: RLS simply denies the low-privilege `Loopctl.Repo`
  # role, which never touches this table, while `AdminRepo` bypasses it.
  #
  # The table is brand-new and empty, so the indexes are created inline (no
  # CONCURRENTLY needed — that is only required for an ONLINE index on an
  # existing hot table).

  def change do
    create table(:rate_limit_counters, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :bucket, :string, null: false
      add :window_start, :bigint, null: false
      add :count, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    # The ON CONFLICT target for the atomic increment-and-check upsert AND the
    # single indexed lookup per check (no scan): every `check_rate/3` touches
    # exactly one `(bucket, window_start)` row.
    create unique_index(:rate_limit_counters, [:bucket, :window_start])

    # Cheap pruning: RateLimitCounterCleanupWorker deletes whole expired windows
    # with `WHERE window_start < <threshold>`; a btree on `window_start` alone
    # keeps that a bounded index range delete rather than a full table scan.
    create index(:rate_limit_counters, [:window_start])

    execute(
      "ALTER TABLE rate_limit_counters ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE rate_limit_counters DISABLE ROW LEVEL SECURITY"
    )
  end
end
