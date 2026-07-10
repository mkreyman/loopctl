defmodule Loopctl.Workers.SessionMemoryPruneWorkerTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Memory.SessionMemory
  alias Loopctl.Workers.SessionMemoryPruneWorker

  # --- TC-28.2.8: prune deletes expired, keeps live ---

  describe "perform/1" do
    test "deletes session memories past expires_at and leaves live ones" do
      tenant = fixture(:tenant)

      expired =
        fixture(:session_memory, %{
          tenant_id: tenant.id,
          subject_id: "s",
          session_id: "s1",
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      live =
        fixture(:session_memory, %{
          tenant_id: tenant.id,
          subject_id: "s",
          session_id: "s1",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      assert :ok = SessionMemoryPruneWorker.perform(%Oban.Job{args: %{}})

      assert is_nil(AdminRepo.get(SessionMemory, expired.id))
      refute is_nil(AdminRepo.get(SessionMemory, live.id))
    end
  end
end
