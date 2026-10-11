defmodule Loopctl.Threads.ThreadReviewsRollbackTest do
  @moduledoc """
  US-45.3: the DOWN path of the `thread_reviews` migration. It refuses, and drops nothing,
  while any review exists — a `thread_reviews` row or a review-kind `runner_dispatches` row —
  and with none it drops `thread_reviews` and `up` restores it.

  Driven the way `Loopctl.ContextRetriever.EntityDefinitionsRollbackTest` drives its
  migration: the file is loaded at runtime and run with `Ecto.Migration.Runner.run/9` in THIS
  process, inside a manual sandbox owner, so every statement lives in one transaction that is
  rolled back on exit and the suite's schema is untouched.

  `async: false` because the subject is DDL on the SHARED `thread_reviews` table: `down` drops
  it and `up` recreates it, and the DROP holds ACCESS EXCLUSIVE on `thread_reviews` until the
  test's transaction rolls back, so every concurrent test reading or writing a review would
  wait on it.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migration.Runner
  alias Loopctl.AdminRepo

  @version 20_260_926_160_000

  alias Loopctl.Repo.Migrations.CreateThreadReviews
  alias Loopctl.Test.MigrationFile

  MigrationFile.require!(CreateThreadReviews, @version)

  setup do
    pid = Sandbox.start_owner!(Loopctl.Repo)
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  defp migrate(direction) do
    Runner.run(
      AdminRepo,
      AdminRepo.config(),
      @version,
      CreateThreadReviews,
      :forward,
      direction,
      direction,
      log: false
    )
  end

  defp table_exists?(name) do
    %{rows: [[exists]]} =
      AdminRepo.query!("SELECT to_regclass($1) IS NOT NULL", ["public." <> name])

    exists
  end

  defp reviews do
    %{rows: [[count]]} = AdminRepo.query!("SELECT count(*) FROM thread_reviews")
    count
  end

  # A review row with no parents: foreign-key triggers are off for this transaction only
  # (`SET LOCAL`), because the question is what `down` does with a review present, not
  # whether one can be placed.
  defp insert_review do
    AdminRepo.query!("SET LOCAL session_replication_role = replica")

    AdminRepo.query!("""
    INSERT INTO thread_reviews
      (tenant_id, story_id, dispatch_id, runner_id, agent_id, claim_epoch, checkpoint_id,
       round, placed_at_seq, placed_by, inserted_at)
    VALUES
      (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
       gen_random_uuid(), 1, gen_random_uuid(), 1, 1, 'test', now())
    """)

    AdminRepo.query!("SET LOCAL session_replication_role = origin")
  end

  test "down refuses while a review exists, and drops nothing" do
    insert_review()

    assert_raise Ecto.MigrationError, ~r/review row\(s\) exist/, fn -> migrate(:down) end

    assert table_exists?("thread_reviews")
    assert reviews() == 1
  end

  test "with no review, down drops thread_reviews and up restores it" do
    assert reviews() == 0

    migrate(:down)
    refute table_exists?("thread_reviews")

    migrate(:up)
    assert table_exists?("thread_reviews")
  end
end
