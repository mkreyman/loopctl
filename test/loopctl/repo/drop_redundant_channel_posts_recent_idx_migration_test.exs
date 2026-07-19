defmodule Loopctl.Repo.DropRedundantChannelPostsRecentIdxMigrationTest do
  @moduledoc """
  US-40.A3 — the write-amplification cleanup migration
  `DropRedundantChannelPostsRecentIdx` drops the redundant recency btree
  `channel_posts_recent_idx` (a strict PREFIX of the kept
  `channel_posts_recent_seq_idx`), so every insert maintains one recency index
  instead of two.

  ## How the migration is driven — CONCURRENTLY, so OUTSIDE the sandbox

  The migration builds/drops the index with `DROP INDEX CONCURRENTLY` /
  `CREATE INDEX CONCURRENTLY` (so the deploy does not take an ACCESS EXCLUSIVE /
  SHARE lock on the hot `channel_posts` table — see the migration's own comment).
  `CONCURRENTLY` is illegal inside a transaction block, and the Ecto SQL sandbox
  wraps every test in one, so the shipped `up/0`/`down/0` CANNOT be driven inside
  the sandbox transaction.

  Instead, the index-DDL tests run the shipped `up/0`/`down/0` verbatim through
  `Sandbox.unboxed_run/2`, which checks out a REAL (non-sandboxed) connection
  where statements auto-commit — exactly the committed connection the production
  migrator uses. `Ecto.Migration.Runner.run/8` (the same entry point
  `Ecto.Migrator.attempt/7` uses for an explicit `up/0`/`down/0`) does NOT open
  its own transaction — the DDL-transaction wrapper lives in `Ecto.Migrator`,
  which `@disable_ddl_transaction true` disables in production — so under
  `unboxed_run/2` the `CONCURRENTLY` statement runs with no surrounding
  transaction, just as it does at deploy. This exercises the SHIPPED `up/0`/`down/0`
  verbatim (single source of truth), so a defect edited into the migration file
  WILL fail these tests.

  Because these tests commit real index changes to the SHARED `channel_posts`
  catalog, an `on_exit` restores the canonical post-migration state (redundant
  index ABSENT) after every test, and the module is `async: false` (below).
  """
  # async: false (the documented global-state-coupling exception to async-everywhere):
  # the index-DDL tests commit real CREATE/DROP INDEX against the SHARED
  # channel_posts catalog via unboxed_run (bypassing the per-test sandbox
  # rollback). Running in ExUnit's sync phase serializes that committed catalog
  # mutation and keeps it off the timeline of the async siblings
  # (coordination_test / channel_post_controller_test) that INSERT into
  # channel_posts, at near-zero cost. (CONCURRENTLY itself takes only a
  # SHARE UPDATE EXCLUSIVE lock that does not block those inserts — the sync
  # phase is about the committed global-state mutation, not lock conflict.)
  use Loopctl.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
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

  # Restore the canonical post-migration state after every test: the applied
  # migration leaves channel_posts_recent_idx ABSENT, and any DDL test that
  # committed a CREATE (down/0) must not leak the redundant index into the shared
  # DB. DROP ... CONCURRENTLY IF EXISTS is a no-op when it is already absent.
  setup do
    on_exit(fn ->
      Sandbox.unboxed_run(AdminRepo, fn ->
        AdminRepo.query!("DROP INDEX CONCURRENTLY IF EXISTS channel_posts_recent_idx")
      end)
    end)

    :ok
  end

  # Run a real (non-sandboxed) committed connection where CONCURRENTLY is legal.
  defp with_unboxed(fun), do: Sandbox.unboxed_run(AdminRepo, fun)

  # Drive the real migration's up/0 in THIS process (mirrors Ecto.Migrator.attempt/7
  # for an explicit up/0 running :forward). MUST be called inside with_unboxed/1 so
  # the CONCURRENTLY DDL runs on a committed, non-transactional connection.
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
  # MUST be called inside with_unboxed/1 (see run_migration_up/0).
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
  # the PRE-migration state by running the shipped down/0 (which recreates the old
  # index), then run up/0 and assert it is dropped. All committed on a single
  # unboxed connection; the on_exit restores the absent-index baseline.
  test "up/0 drops channel_posts_recent_idx, leaving channel_posts_recent_seq_idx" do
    with_unboxed(fn ->
      # Re-establish the pre-cleanup state: old index present alongside the keeper.
      assert :ok = run_migration_down()
      assert index_present?("channel_posts_recent_idx")
      assert index_present?("channel_posts_recent_seq_idx")

      assert :ok = run_migration_up()

      refute index_present?("channel_posts_recent_idx")
      assert index_present?("channel_posts_recent_seq_idx")
      # The keyed-slot unique index is untouched by this cleanup.
      assert index_present?("channel_posts_session_key_uidx")
    end)
  end

  # TC-40.A3.1 idempotent-safe — up/0 uses DROP INDEX CONCURRENTLY IF EXISTS, so
  # running it again (old index already absent) does not raise.
  test "up/0 is idempotent-safe when the old index is already absent" do
    with_unboxed(fn ->
      assert :ok = run_migration_up()
      refute index_present?("channel_posts_recent_idx")

      # Second run: nothing to drop, must still succeed.
      assert :ok = run_migration_up()
      refute index_present?("channel_posts_recent_idx")
    end)
  end

  # TC-40.A3.2 — recent read still returns newest-first in the POST-DROP state.
  #
  # This is a behaviour test over Coordination + fixtures, so it stays INSIDE the
  # sandbox (rows roll back, async-safe) and does NOT drive the migration DDL: the
  # committed test DB is ALREADY in the post-migration state (channel_posts_recent_idx
  # dropped at ecto.setup, channel_posts_recent_seq_idx present), so seeding and
  # asserting ordering here exercises exactly the "after the drop" query path.
  #
  # Seed 3 posts stamped to the SAME microsecond `inserted_at` with differing `seq`
  # (bigserial, increasing per insert); ordering must be `inserted_at DESC` then
  # `seq DESC` — served by channel_posts_recent_seq_idx.
  test "recent/3 stays newest-first (inserted_at DESC, seq DESC) in the post-drop state" do
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

    ordered_ids = tenant.id |> Coordination.recent(project.id) |> Enum.map(& &1.id)

    # p3 inserted last → highest seq → first; p1 first → lowest seq → last.
    assert ordered_ids == [p3.id, p2.id, p1.id]
  end

  # TC-40.A3.3 — down/0 recreates the old index cleanly (reversible), no error.
  # The on_exit drops the recreated index, restoring the absent-index baseline.
  test "down/0 recreates channel_posts_recent_idx" do
    with_unboxed(fn ->
      assert :ok = run_migration_up()
      refute index_present?("channel_posts_recent_idx")

      assert :ok = run_migration_down()

      assert index_present?("channel_posts_recent_idx")
      assert index_present?("channel_posts_recent_seq_idx")
    end)
  end
end
