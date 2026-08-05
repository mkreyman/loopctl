defmodule Loopctl.Workers.AuditPartitionWorkerTest do
  # DELIBERATELY sync: not coupled to global STATE, but holding DDL LOCKS. The strip below
  # takes SHARE UPDATE EXCLUSIVE on every audit_log leaf for the whole test transaction and
  # `perform/1` then escalates to ACCESS EXCLUSIVE on the parent to drop expired partitions,
  # while any async peer inserting an audit row holds ROW EXCLUSIVE — a circular wait. ExUnit
  # runs sync modules after the async ones, so no peer holds those locks.
  use Loopctl.DataCase, async: false

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Workers.AuditPartitionWorker

  @analyze "autovacuum_analyze_scale_factor"
  @insert "autovacuum_vacuum_insert_scale_factor"
  @both "#{@analyze}, #{@insert}"

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
      # cannot hold them at all — so an unstamped partition runs on the global defaults, which
      # is how the corpus went un-analyzed (`n_live_tup` read 358 for 85,053 rows).
      #
      # AdminRepo throughout, because that is the repo the WORKER writes through (it owns the
      # partitions; `loopctl_app` may not ALTER them) and the two repos hold separate sandbox
      # transactions — a RESET issued on one is invisible to the other, and asserting through
      # the other would only ever observe the stamp test_helper committed.
      #
      # Stripping EVERY leaf rather than one arbitrary `LIMIT 1` row: it covers the retained
      # PAST months (which the create loop never revisits) as well as the create window, and
      # it cannot land on a partition this same run drops as expired.
      for [name, _] <- partitions(), do: AdminRepo.query!("ALTER TABLE #{name} RESET (#{@both})")

      for [name, reloptions] <- partitions() do
        refute reloptions =~ ~r/#{@analyze}|#{@insert}/,
               "the RESET on #{name} did not take, so the repair below is unobservable"
      end

      assert :ok = AuditPartitionWorker.perform(%Oban.Job{})

      retained = partitions()
      assert retained != [], "no audit_log partitions found — the assertions below are vacuous"

      # Only a RETAINED partition before the current month exercises the sweep-only stamp path
      # (fixed-width zero-padded names, so a string compare orders them).
      assert Enum.any?(retained, fn [name, _] -> name < current_partition() end),
             "every retained partition is in the create window — the sweep stamp is untested"

      for [name, reloptions] <- retained do
        assert reloptions =~ "#{@analyze}=0.05", "#{name} left untuned: #{inspect(reloptions)}"
        assert reloptions =~ "#{@insert}=0.1", "#{name} lost the insert-driven vacuum trigger"
      end
    end

    test "#579: a partition that lost only the insert factor is re-stamped" do
      # The already-tuned guard has to key on BOTH reloptions: keying on the analyze factor
      # alone reads this half-stamped partition as tuned and never restores the insert-driven
      # trigger. The CURRENT month, so the target is one the worker visits and never drops.
      name = current_partition()

      AdminRepo.query!("ALTER TABLE #{name} SET (#{@analyze} = 0.05)")
      AdminRepo.query!("ALTER TABLE #{name} RESET (#{@insert})")

      # Prove the half-stamped state first, or a guard that checks only the analyze factor
      # passes on an insert factor the setup never removed.
      half_stamped = reloptions(name)
      assert half_stamped =~ "#{@analyze}=0.05"
      refute half_stamped =~ @insert, "the RESET on #{name} did not take — guard unobservable"

      assert :ok = AuditPartitionWorker.perform(%Oban.Job{})

      assert reloptions(name) =~ "#{@insert}=0.1",
             "#{name} kept the analyze factor, so the guard skipped the missing insert factor"
    end
  end

  defp current_partition do
    now = DateTime.utc_now()
    "audit_log_y#{now.year}m#{String.pad_leading("#{now.month}", 2, "0")}"
  end

  defp reloptions(name) do
    %{rows: [[reloptions]]} =
      AdminRepo.query!(
        "SELECT coalesce(array_to_string(reloptions, ','), '') FROM pg_class WHERE oid = to_regclass($1)",
        [name]
      )

    reloptions
  end

  defp partitions do
    %{rows: rows} =
      AdminRepo.query!("""
      SELECT c.relname, coalesce(array_to_string(c.reloptions, ','), '')
        FROM pg_inherits i
        JOIN pg_class p ON p.oid = i.inhparent
        JOIN pg_class c ON c.oid = i.inhrelid
       WHERE p.relname = 'audit_log' AND c.relkind = 'r'
      """)

    rows
  end
end
