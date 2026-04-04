defmodule Loopctl.Workers.TokenDataArchivalWorkerTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Workers.TokenDataArchivalWorker

  describe "perform/1" do
    test "processes tenants with retention policy: runs all three passes" do
      tenant = fixture(:tenant)
      # Set retention policy
      tenant
      |> Ecto.Changeset.change(token_data_retention_days: 90)
      |> Loopctl.AdminRepo.update!()

      tenant_id = tenant.id

      expect(Loopctl.MockTokenArchival, :hard_delete_expired_reports, fn tid ->
        assert tid == tenant_id
        {:ok, 5}
      end)

      expect(Loopctl.MockTokenArchival, :soft_delete_old_reports, fn tid, days ->
        assert tid == tenant_id
        assert days == 90
        {:ok, 10}
      end)

      expect(Loopctl.MockTokenArchival, :archive_old_anomalies, fn tid, days ->
        assert tid == tenant_id
        assert days == 90
        {:ok, 3}
      end)

      assert :ok = TokenDataArchivalWorker.perform(%Oban.Job{args: %{}})
    end

    test "processes tenants without retention policy: only runs hard-delete" do
      tenant = fixture(:tenant)
      # No retention policy (nil)
      assert tenant.token_data_retention_days == nil

      tenant_id = tenant.id

      # Hard-delete still runs for all tenants
      expect(Loopctl.MockTokenArchival, :hard_delete_expired_reports, fn tid ->
        assert tid == tenant_id
        {:ok, 0}
      end)

      # Soft-delete and anomaly archive should NOT be called for tenants without policy
      # (default stubs return {:ok, 0} but verify_on_exit! would catch unexpected calls)

      assert :ok = TokenDataArchivalWorker.perform(%Oban.Job{args: %{}})
    end

    test "skips suspended tenants entirely" do
      _suspended = fixture(:tenant, %{status: :suspended})
      _active = fixture(:tenant)

      # Hard-delete only called for the active tenant
      expect(Loopctl.MockTokenArchival, :hard_delete_expired_reports, fn _tid ->
        {:ok, 0}
      end)

      assert :ok = TokenDataArchivalWorker.perform(%Oban.Job{args: %{}})
    end

    test "handles multiple tenants" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      # Set retention on both
      tenant_a
      |> Ecto.Changeset.change(token_data_retention_days: 60)
      |> Loopctl.AdminRepo.update!()

      tenant_b
      |> Ecto.Changeset.change(token_data_retention_days: 120)
      |> Loopctl.AdminRepo.update!()

      # All three passes for both tenants
      expect(Loopctl.MockTokenArchival, :hard_delete_expired_reports, 2, fn _tid -> {:ok, 0} end)

      expect(Loopctl.MockTokenArchival, :soft_delete_old_reports, 2, fn _tid, _days ->
        {:ok, 0}
      end)

      expect(Loopctl.MockTokenArchival, :archive_old_anomalies, 2, fn _tid, _days -> {:ok, 0} end)

      assert :ok = TokenDataArchivalWorker.perform(%Oban.Job{args: %{}})
    end

    test "handles archival service errors gracefully" do
      tenant = fixture(:tenant)

      tenant
      |> Ecto.Changeset.change(token_data_retention_days: 90)
      |> Loopctl.AdminRepo.update!()

      expect(Loopctl.MockTokenArchival, :hard_delete_expired_reports, fn _tid ->
        {:error, "timeout"}
      end)

      expect(Loopctl.MockTokenArchival, :soft_delete_old_reports, fn _tid, _days ->
        {:error, "connection refused"}
      end)

      expect(Loopctl.MockTokenArchival, :archive_old_anomalies, fn _tid, _days ->
        {:error, "timeout"}
      end)

      # Should not raise — errors are logged and swallowed
      assert :ok = TokenDataArchivalWorker.perform(%Oban.Job{args: %{}})
    end

    test "writes audit log entries for tenants with archival activity" do
      tenant = fixture(:tenant)

      tenant
      |> Ecto.Changeset.change(token_data_retention_days: 90)
      |> Loopctl.AdminRepo.update!()

      expect(Loopctl.MockTokenArchival, :hard_delete_expired_reports, fn _tid -> {:ok, 5} end)
      expect(Loopctl.MockTokenArchival, :soft_delete_old_reports, fn _tid, _days -> {:ok, 10} end)
      expect(Loopctl.MockTokenArchival, :archive_old_anomalies, fn _tid, _days -> {:ok, 3} end)

      assert :ok = TokenDataArchivalWorker.perform(%Oban.Job{args: %{}})

      # Verify audit log entry was created
      import Ecto.Query

      log_entry =
        Loopctl.AdminRepo.one(
          from a in Loopctl.Audit.AuditLog,
            where: a.tenant_id == ^tenant.id and a.action == "archival_run",
            where: a.entity_type == "token_data_archival"
        )

      assert log_entry != nil
      assert log_entry.new_state["reports_soft_deleted"] == 10
      assert log_entry.new_state["reports_hard_deleted"] == 5
      assert log_entry.new_state["anomalies_archived"] == 3
      assert log_entry.new_state["retention_days"] == 90
    end

    test "tenant isolation: each tenant processed independently" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      tenant_a
      |> Ecto.Changeset.change(token_data_retention_days: 30)
      |> Loopctl.AdminRepo.update!()

      # tenant_b has no retention policy

      # Use unique table name per test invocation to avoid async conflicts
      table_name = :"archival_received_#{System.unique_integer([:positive])}"
      received_ids = :ets.new(table_name, [:set, :public])

      expect(Loopctl.MockTokenArchival, :hard_delete_expired_reports, 2, fn tid ->
        :ets.insert(received_ids, {{tid, :hard_delete}, true})
        {:ok, 0}
      end)

      expect(Loopctl.MockTokenArchival, :soft_delete_old_reports, fn tid, _days ->
        :ets.insert(received_ids, {{tid, :soft_delete}, true})
        {:ok, 0}
      end)

      expect(Loopctl.MockTokenArchival, :archive_old_anomalies, fn tid, _days ->
        :ets.insert(received_ids, {{tid, :archive}, true})
        {:ok, 0}
      end)

      assert :ok = TokenDataArchivalWorker.perform(%Oban.Job{args: %{}})

      # tenant_a (with policy) should get all three passes
      assert :ets.member(received_ids, {tenant_a.id, :hard_delete})
      assert :ets.member(received_ids, {tenant_a.id, :soft_delete})
      assert :ets.member(received_ids, {tenant_a.id, :archive})

      # tenant_b (no policy) should only get hard_delete
      assert :ets.member(received_ids, {tenant_b.id, :hard_delete})
      refute :ets.member(received_ids, {tenant_b.id, :soft_delete})
      refute :ets.member(received_ids, {tenant_b.id, :archive})

      :ets.delete(received_ids)
    end
  end
end
