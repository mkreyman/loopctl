defmodule LoopctlRunner.ClaimEndedTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.{ClaimEnded, RunState, Session}
  import LoopctlRunner.TestSupport

  setup do
    {:ok, runs_dir: tmp_dir!("claim-ended")}
  end

  test "one marker per claim, found by name, for its own epoch only", %{runs_dir: runs_dir} do
    id = Session.uuid4()
    refute ClaimEnded.ended?(runs_dir, id, 3)

    assert :ok = ClaimEnded.record(runs_dir, id, 3, "stage", "stale_claim_epoch")
    assert ClaimEnded.ended?(runs_dir, id, 3)
    assert ClaimEnded.ended?(runs_dir, %{"dispatch_id" => id, "claim_epoch" => 3})
    refute ClaimEnded.ended?(runs_dir, id, 4)
    refute ClaimEnded.ended?(runs_dir, Session.uuid4(), 3)
    refute ClaimEnded.ended?(runs_dir, %{})
    assert ClaimEnded.all(runs_dir) == [{id, 3}]
  end

  test "written whether or not a run of the claim has a directory, and invisible to runs",
       %{runs_dir: runs_dir} do
    id = Session.uuid4()
    assert RunState.all(runs_dir) == []
    assert :ok = ClaimEnded.record(runs_dir, id, 0, "trace", "unknown_dispatch")
    assert ClaimEnded.ended?(runs_dir, id, 0)
    assert RunState.all(runs_dir) == []
  end

  test "an id or epoch from the wire that names no claim writes and finds nothing",
       %{runs_dir: runs_dir} do
    for {id, epoch} <- [{"../escape", 1}, {"not-a-uuid", 1}, {Session.uuid4(), -1}, {nil, 1}] do
      assert {:error, :not_a_claim} = ClaimEnded.record(runs_dir, id, epoch, "stage", "x")
      refute ClaimEnded.ended?(runs_dir, id, epoch)
    end

    assert ClaimEnded.all(runs_dir) == []
  end

  test "prune removes markers older than the age it is given, and only those" do
    runs = tmp_dir!("claims-prune")
    old = "5b1c7a52-6a4c-4f7e-9d7b-1a2b3c4d5e6f"
    fresh = "6b1c7a52-6a4c-4f7e-9d7b-1a2b3c4d5e6f"
    :ok = ClaimEnded.record(runs, old, 1, "trace", "stale_claim_epoch")
    :ok = ClaimEnded.record(runs, fresh, 1, "trace", "stale_claim_epoch")
    now = System.os_time(:second)
    File.touch!(Path.join([runs, ".claims", "#{old}-1"]), now - 10_000)

    assert ClaimEnded.prune(runs, now, 3_600) == 1
    refute ClaimEnded.ended?(runs, old, 1)
    assert ClaimEnded.ended?(runs, fresh, 1)
  end
end
