defmodule Loopctl.Workers.AuditPartitionWorkerTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Repo
  alias Loopctl.Workers.AuditPartitionWorker

  describe "perform/1" do
    test "creates future partitions and succeeds" do
      # The worker should run without error — partitions already exist
      # from the migration, so it should handle "already exists" gracefully
      assert :ok = AuditPartitionWorker.perform(%Oban.Job{})
    end

    test "is idempotent — running twice does not error" do
      assert :ok = AuditPartitionWorker.perform(%Oban.Job{})
      assert :ok = AuditPartitionWorker.perform(%Oban.Job{})
    end

    test "#579: every partition it manages carries the autovacuum tuning" do
      # `CREATE TABLE ... PARTITION OF` does NOT inherit reloptions, and a partitioned parent
      # cannot hold storage autovacuum params at all — so an unstamped partition is created
      # with the global defaults. That is how the corpus went un-analyzed: autoanalyze had
      # never run on the four largest tables, and `n_live_tup` read 358 for a table with
      # 85,053 rows.
      assert :ok = AuditPartitionWorker.perform(%Oban.Job{})

      %{rows: rows} =
        AdminRepo.query!("""
        SELECT c.relname, coalesce(array_to_string(c.reloptions, ','), '')
          FROM pg_inherits i
          JOIN pg_class p ON p.oid = i.inhparent
          JOIN pg_class c ON c.oid = i.inhrelid
         WHERE p.relname = 'audit_log' AND c.relkind = 'r'
        """)

      assert rows != [], "no audit_log partitions found — the assertion below would be vacuous"

      for [name, reloptions] <- rows do
        assert reloptions =~ "autovacuum_analyze_scale_factor=0.05",
               "partition #{name} was created untuned: #{inspect(reloptions)}"

        assert reloptions =~ "autovacuum_vacuum_insert_scale_factor=0.1",
               "partition #{name} is missing the insert-driven vacuum trigger"
      end
    end

    test "#579: the stamp is SELF-HEALING — it re-tunes a partition that lost its reloptions" do
      # Covers the two ways a partition ends up untuned despite this code existing: created
      # before it did, and created during a deploy window. A table REBUILD also silently drops
      # reloptions. So the stamp must repair, not just apply-on-create.
      # Loopctl.Repo throughout, because that is the repo the WORKER writes through. Repo and
      # AdminRepo hold separate sandbox transactions, so a RESET issued on one is invisible to
      # the other — the repair would look like it never happened when in fact the test never
      # observed it.
      %{rows: [[name] | _]} =
        Repo.query!("""
        SELECT c.relname FROM pg_inherits i
          JOIN pg_class p ON p.oid = i.inhparent
          JOIN pg_class c ON c.oid = i.inhrelid
         WHERE p.relname = 'audit_log' AND c.relkind = 'r' LIMIT 1
        """)

      Repo.query!(
        "ALTER TABLE #{name} RESET (autovacuum_analyze_scale_factor, autovacuum_vacuum_insert_scale_factor)"
      )

      %{rows: [[stripped]]} =
        Repo.query!(
          "SELECT coalesce(array_to_string(reloptions, ','), '') FROM pg_class WHERE relname = $1",
          [name]
        )

      refute stripped =~ "autovacuum_analyze_scale_factor",
             "the RESET did not take, so this test cannot observe the repair"

      assert :ok = AuditPartitionWorker.perform(%Oban.Job{})

      %{rows: [[repaired]]} =
        Repo.query!(
          "SELECT coalesce(array_to_string(reloptions, ','), '') FROM pg_class WHERE relname = $1",
          [name]
        )

      assert repaired =~ "autovacuum_analyze_scale_factor=0.05",
             "#{name} was not re-tuned — the stamp only applies on create, not on repair"
    end
  end
end
