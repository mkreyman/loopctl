defmodule Loopctl.Workers.AuditPartitionWorkerTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

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
  end
end
