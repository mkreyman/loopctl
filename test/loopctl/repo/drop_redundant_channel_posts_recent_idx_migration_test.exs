defmodule Loopctl.Repo.DropRedundantChannelPostsRecentIdxMigrationTest do
  @moduledoc """
  US-40.A3 — the write-amplification cleanup migration
  `DropRedundantChannelPostsRecentIdx` drops the redundant recency btree
  `channel_posts_recent_idx` (a strict PREFIX of the kept
  `channel_posts_recent_seq_idx`), so every insert maintains one recency index
  instead of two.

  ## How the migration is driven

  The migration file under `priv/repo/migrations` is not compiled into the app, so
  it is loaded here at runtime (`Code.require_file`) and driven with
  `Ecto.Migration.Runner.run/8` DIRECTLY — the same entry point
  `Ecto.Migrator.attempt/7` uses — rather than via `Ecto.Migrator.up`. `Runner.run`
  performs the DDL in THIS process, so it executes inside the sandbox transaction
  (and is rolled back on exit) instead of a spawned Task under its own
  transaction/lock that could not check out the sandbox-owned connection. This
  exercises the SHIPPED `up/0`/`down/0` verbatim (single source of truth), so a
  defect edited into the migration file WILL fail this test.
  """
  use Loopctl.DataCase, async: true

  alias Ecto.Migration.Runner
  alias Loopctl.AdminRepo
  alias Loopctl.Coordination

  @migration_version 20_260_718_130_000
  @migration_file Path.wildcard(
                    Path.join([
                      File.cwd!(),
                      "priv",
                      "repo",
                      "migrations",
                      "#{@migration_version}_*.exs"
                    ])
                  )
                  |> hd()

  Code.require_file(@migration_file)

  alias Loopctl.Repo.Migrations.DropRedundantChannelPostsRecentIdx

  # Drive the real migration's up/0 in THIS process (mirrors Ecto.Migrator.attempt/7
  # for an explicit up/0 running :forward), so the DDL runs inside the sandbox
  # transaction.
  defp run_migration_up do
    Runner.run(
      AdminRepo,
      AdminRepo.config(),
      @migration_version,
      DropRedundantChannelPostsRecentIdx,
      :forward,
      :up,
      :up,
      log: false
    )
  end

  # Drive the real migration's down/0 in THIS process (recreates the old index).
  defp run_migration_down do
    Runner.run(
      AdminRepo,
      AdminRepo.config(),
      @migration_version,
      DropRedundantChannelPostsRecentIdx,
      :forward,
      :down,
      :down,
      log: false
    )
  end

  # True if an index of the given name exists on channel_posts.
  defp index_present?(name) do
    %{rows: rows} =
      AdminRepo.query!(
        "SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'channel_posts' AND indexname = $1",
        [name]
      )

    rows != []
  end

  # TC-40.A3.1 — after up/0, the old prefix index is gone and the kept superset
  # (seq) index remains.
  #
  # NOTE ON BASELINE: this migration is part of the applied set, so it ALREADY ran
  # at ecto.setup — `channel_posts_recent_idx` is dropped in the committed test DB
  # (final post-cleanup state). To exercise up/0 meaningfully we first re-establish
  # the PRE-migration state inside the sandbox transaction by running the shipped
  # down/0 (which recreates the old index), then run up/0 and assert it is dropped.
  # This mirrors how the reshape migration test artificially recreates old-shape
  # rows before driving up/0.
  test "up/0 drops channel_posts_recent_idx, leaving channel_posts_recent_seq_idx" do
    # Re-establish the pre-cleanup state: old index present alongside the keeper.
    assert :ok = run_migration_down()
    assert index_present?("channel_posts_recent_idx")
    assert index_present?("channel_posts_recent_seq_idx")

    assert :ok = run_migration_up()

    refute index_present?("channel_posts_recent_idx")
    assert index_present?("channel_posts_recent_seq_idx")
    # The keyed-slot unique index is untouched by this cleanup.
    assert index_present?("channel_posts_session_key_uidx")
  end

  # TC-40.A3.1 idempotent-safe — up/0 uses drop_if_exists, so running it again
  # (old index already absent) does not raise.
  test "up/0 is idempotent-safe when the old index is already absent" do
    assert :ok = run_migration_up()
    refute index_present?("channel_posts_recent_idx")

    # Second run: nothing to drop, must still succeed.
    assert :ok = run_migration_up()
    refute index_present?("channel_posts_recent_idx")
  end

  # TC-40.A3.2 — recent read still returns newest-first after the drop. Seed 3
  # posts stamped to the SAME microsecond `inserted_at` with differing `seq`
  # (bigserial, increasing per insert); ordering must be `inserted_at DESC` then
  # `seq DESC` — served by channel_posts_recent_seq_idx, identical to
  # pre-migration.
  test "recent/3 stays newest-first (inserted_at DESC, seq DESC) after the drop" do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    agent = fixture(:agent, %{tenant_id: tenant.id})

    {:ok, p1} = Coordination.create_post(tenant.id, project.id, agent.id, %{"body" => "one"})
    {:ok, p2} = Coordination.create_post(tenant.id, project.id, agent.id, %{"body" => "two"})
    {:ok, p3} = Coordination.create_post(tenant.id, project.id, agent.id, %{"body" => "three"})

    # Force identical inserted_at across all three so ordering depends on the seq
    # tie-break (the sole remaining recency btree's second key).
    same_ts = ~U[2026-07-18 00:00:00.000000Z]

    %{num_rows: 3} =
      AdminRepo.query!(
        "UPDATE channel_posts SET inserted_at = $1 WHERE id = ANY($2)",
        [same_ts, Enum.map([p1, p2, p3], &Ecto.UUID.dump!(&1.id))]
      )

    assert :ok = run_migration_up()

    ordered_ids = tenant.id |> Coordination.recent(project.id) |> Enum.map(& &1.id)

    # p3 inserted last → highest seq → first; p1 first → lowest seq → last.
    assert ordered_ids == [p3.id, p2.id, p1.id]
  end

  # TC-40.A3.3 — down/0 recreates the old index cleanly (reversible), no error.
  test "down/0 recreates channel_posts_recent_idx" do
    assert :ok = run_migration_up()
    refute index_present?("channel_posts_recent_idx")

    assert :ok = run_migration_down()

    assert index_present?("channel_posts_recent_idx")
    assert index_present?("channel_posts_recent_seq_idx")
  end
end
