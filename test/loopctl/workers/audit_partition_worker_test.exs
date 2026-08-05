defmodule Loopctl.Workers.AuditPartitionWorkerTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Repo
  alias Loopctl.Workers.AuditPartitionWorker

  @both "autovacuum_analyze_scale_factor, autovacuum_vacuum_insert_scale_factor"

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

    test "#579: every retained partition carries the tuning, and the stamp is SELF-HEALING" do
      # `CREATE TABLE ... PARTITION OF` does NOT inherit reloptions, and a partitioned parent
      # cannot hold storage autovacuum params at all — so an unstamped partition is created
      # with the global defaults. That is how the corpus went un-analyzed: autoanalyze had
      # never run on the four largest tables, and `n_live_tup` read 358 for a table with
      # 85,053 rows.
      #
      # Loopctl.Repo throughout, because that is the repo the WORKER writes through. Repo and
      # AdminRepo hold separate sandbox transactions, so a RESET issued on one is invisible to
      # the other — and reading the assertion back through AdminRepo would only ever observe
      # the stamp test_helper committed, staying green with the worker's stamp deleted.
      #
      # Stripping EVERY leaf rather than one arbitrary `LIMIT 1` row: it covers the retained
      # PAST months (which the create loop never revisits) as well as the create window, and
      # it cannot land on a partition this same run drops as expired.
      for [name, _] <- partitions(), do: Repo.query!("ALTER TABLE #{name} RESET (#{@both})")

      for [name, reloptions] <- partitions() do
        refute reloptions =~ "autovacuum_",
               "the RESET on #{name} did not take, so the repair below is unobservable"
      end

      assert :ok = AuditPartitionWorker.perform(%Oban.Job{})

      retained = partitions()
      assert retained != [], "no audit_log partitions found — the assertions below are vacuous"

      for [name, reloptions] <- retained do
        assert reloptions =~ "autovacuum_analyze_scale_factor=0.05",
               "partition #{name} was left untuned: #{inspect(reloptions)}"

        assert reloptions =~ "autovacuum_vacuum_insert_scale_factor=0.1",
               "partition #{name} is missing the insert-driven vacuum trigger"
      end
    end

    test "#579: a partition that lost only the insert factor is re-stamped" do
      # The already-tuned guard has to key on BOTH reloptions. Keying on the analyze factor
      # alone reads this half-stamped partition as tuned and never restores the insert-driven
      # trigger — the knob this change exists for. The CURRENT month, derived the way the
      # worker derives it, so the target is always a partition the worker is specified to
      # visit and never one it drops as expired.
      now = DateTime.utc_now()
      name = "audit_log_y#{now.year}m#{String.pad_leading("#{now.month}", 2, "0")}"

      Repo.query!("ALTER TABLE #{name} SET (autovacuum_analyze_scale_factor = 0.05)")
      Repo.query!("ALTER TABLE #{name} RESET (autovacuum_vacuum_insert_scale_factor)")

      assert :ok = AuditPartitionWorker.perform(%Oban.Job{})

      %{rows: [[reloptions]]} =
        Repo.query!(
          "SELECT coalesce(array_to_string(reloptions, ','), '') FROM pg_class WHERE oid = to_regclass($1)",
          [name]
        )

      assert reloptions =~ "autovacuum_vacuum_insert_scale_factor=0.1",
             "#{name} kept the analyze factor, so the guard skipped the missing insert factor"
    end
  end

  defp partitions do
    %{rows: rows} =
      Repo.query!("""
      SELECT c.relname, coalesce(array_to_string(c.reloptions, ','), '')
        FROM pg_inherits i
        JOIN pg_class p ON p.oid = i.inhparent
        JOIN pg_class c ON c.oid = i.inhrelid
       WHERE p.relname = 'audit_log' AND c.relkind = 'r'
      """)

    rows
  end
end
