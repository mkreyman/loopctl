defmodule LoopctlRunner.CheckpointStreamTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.CheckpointStream
  import LoopctlRunner.TestSupport

  @dispatch "7c9e6679-7425-40de-944b-e07fc1f90ae7"
  @commit String.duplicate("a", 40)
  @tree String.duplicate("b", 40)

  setup do
    runs_dir = tmp_dir!("checkpoints")
    run_dir = Path.join(runs_dir, "run-1")
    File.mkdir_p!(run_dir)

    File.write!(
      Path.join(run_dir, "state.json"),
      JSON.encode!(%{"dispatch_id" => @dispatch, "claim_epoch" => 3, "status" => "running"})
    )

    {:ok, runs_dir: runs_dir, run_dir: run_dir}
  end

  defp log!(run_dir, text), do: File.write!(CheckpointStream.log_path(run_dir), text)

  test "a run with an unsent line is found, and its payload binds the dispatch", ctx do
    log!(ctx.run_dir, "#{@commit} #{@tree}\n")
    assert [run] = CheckpointStream.runs(ctx.runs_dir)
    assert %{dispatch_id: @dispatch, claim_epoch: 3, sent: 0} = run

    assert {:ok,
            %{
              "dispatch_id" => @dispatch,
              "claim_epoch" => 3,
              "commit_sha" => @commit,
              "tree_sha" => @tree
            }, %{line: 82, later?: false}} = CheckpointStream.next(run)
  end

  test "a half-written last line waits for the next read", ctx do
    log!(ctx.run_dir, "#{@commit} #{@tree}")
    assert [run] = CheckpointStream.runs(ctx.runs_dir)
    assert CheckpointStream.next(run) == :none
    refute CheckpointStream.unsettled?(ctx.run_dir)
  end

  test "settled lines are not sent again, and a stopped run is never found again", ctx do
    log!(ctx.run_dir, "#{@commit} #{@tree}\n#{String.duplicate("c", 40)} #{@tree}\n")
    [run] = CheckpointStream.runs(ctx.runs_dir)
    assert CheckpointStream.unsettled?(ctx.run_dir)
    {:ok, _payload, %{later?: true} = run} = CheckpointStream.next(run)
    :ok = CheckpointStream.settle(run)

    assert [%{sent: 1, bytes: 82} = run] = CheckpointStream.runs(ctx.runs_dir)
    assert {:ok, %{"commit_sha" => "cccc" <> _}, run} = CheckpointStream.next(run)

    :ok = CheckpointStream.settle(run)
    assert CheckpointStream.runs(ctx.runs_dir) == []
    refute CheckpointStream.unsettled?(ctx.run_dir)

    log!(ctx.run_dir, "#{@commit} #{@tree}\n#{@commit} #{@tree}\n#{@commit} #{@tree}\n")
    assert [run] = CheckpointStream.runs(ctx.runs_dir)
    :ok = CheckpointStream.stop(run, "not_claimant")
    assert CheckpointStream.runs(ctx.runs_dir) == []
  end

  test "a log shorter than what is settled is read as new, from its start", ctx do
    three = String.duplicate("#{@commit} #{@tree}\n", 3)
    log!(ctx.run_dir, three)

    for _ <- 1..3 do
      [run] = CheckpointStream.runs(ctx.runs_dir)
      {:ok, _payload, run} = CheckpointStream.next(run)
      :ok = CheckpointStream.settle(run)
    end

    refute CheckpointStream.unsettled?(ctx.run_dir)

    fresh = String.duplicate("c", 40)
    log!(ctx.run_dir, "#{fresh} #{@tree}\n")
    assert CheckpointStream.unsettled?(ctx.run_dir)
    assert [%{sent: 0, bytes: 0} = run] = CheckpointStream.runs(ctx.runs_dir)
    assert {:ok, %{"commit_sha" => ^fresh}, run} = CheckpointStream.next(run)
    :ok = CheckpointStream.settle(run)
    refute CheckpointStream.unsettled?(ctx.run_dir)
  end

  test "lines past a read block's end are read whole", ctx do
    # A first line ending just inside the first 4096-byte block, and a real one ending in the next:
    # each is read complete, and the first knows the second follows.
    long = String.duplicate("x", 4_089)
    log!(ctx.run_dir, "#{long}\n#{@commit} #{@tree}\n")
    [run] = CheckpointStream.runs(ctx.runs_dir)
    assert {:skip, _why, %{line: 4_090, later?: true} = run} = CheckpointStream.next(run)
    :ok = CheckpointStream.settle(run)

    [run] = CheckpointStream.runs(ctx.runs_dir)
    assert {:ok, %{"commit_sha" => @commit}, %{later?: false}} = CheckpointStream.next(run)
  end

  test "a run bound to no dispatch holds no end report", ctx do
    File.write!(Path.join(ctx.run_dir, "state.json"), JSON.encode!(%{"status" => "failed"}))
    log!(ctx.run_dir, "#{@commit} #{@tree}\n")
    refute CheckpointStream.unsettled?(ctx.run_dir)
  end

  test "a line loop-push never writes is skipped, never sent", ctx do
    log!(ctx.run_dir, "not a sha\n")
    [run] = CheckpointStream.runs(ctx.runs_dir)
    assert {:skip, why, %{line: 10}} = CheckpointStream.next(run)
    assert why =~ "line 1"
  end

  test "a log too big to be loop-push's is found, and next says to stop", ctx do
    log!(ctx.run_dir, String.duplicate("x", 4 * 1024 * 1024 + 1))
    assert [run] = CheckpointStream.runs(ctx.runs_dir)
    assert {:stop, why} = CheckpointStream.next(run)
    assert why =~ "more than loop-push ever writes"
  end

  test "a log that cannot be read is found, and next says why", ctx do
    log!(ctx.run_dir, "#{@commit} #{@tree}\n")
    File.chmod!(CheckpointStream.log_path(ctx.run_dir), 0o000)
    on_exit(fn -> File.chmod(CheckpointStream.log_path(ctx.run_dir), 0o644) end)

    assert [run] = CheckpointStream.runs(ctx.runs_dir)
    assert {:error, why} = CheckpointStream.next(run)
    assert why =~ "cannot read"
  end

  test "a run whose claim is recorded over reports nothing", ctx do
    log!(ctx.run_dir, "#{@commit} #{@tree}\n")
    :ok = LoopctlRunner.ClaimEnded.record(ctx.runs_dir, @dispatch, 3, "stage", "not_claimant")
    assert CheckpointStream.runs(ctx.runs_dir) == []
  end

  test "a run bound to no dispatch reports nothing", ctx do
    File.write!(Path.join(ctx.run_dir, "state.json"), JSON.encode!(%{"status" => "running"}))
    log!(ctx.run_dir, "#{@commit} #{@tree}\n")
    assert CheckpointStream.runs(ctx.runs_dir) == []
  end

  test "each reply is classified by the vendored contract" do
    assert CheckpointStream.classify({:ok, %{"replayed" => true}}) == :recorded

    assert CheckpointStream.classify({:error, %{"reason" => "not_claimant"}}) ==
             {:claim_over, "not_claimant"}

    assert CheckpointStream.classify({:error, %{"reason" => "dispatch_not_accepted"}}) ==
             {:not_accepted, "dispatch_not_accepted"}

    assert CheckpointStream.classify({:error, %{"reason" => "checkpoint_conflict"}}) ==
             {:refused, "checkpoint_conflict"}

    assert CheckpointStream.classify(
             {:error, %{"reason" => "rate_limited", "min_interval_ms" => 250}}
           ) == {:rate_limited, %{"reason" => "rate_limited", "min_interval_ms" => 250}}

    assert CheckpointStream.classify({:error, %{"reason" => "internal_error"}}) ==
             {:transient, "internal_error"}

    # A lapsed lease may be renewed: waited on, never settled unsent.
    assert CheckpointStream.classify({:error, %{"reason" => "claim_not_live"}}) ==
             {:transient, "claim_not_live"}
  end
end
