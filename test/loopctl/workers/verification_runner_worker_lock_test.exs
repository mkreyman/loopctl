defmodule Loopctl.Workers.VerificationRunnerWorkerLockTest do
  @moduledoc """
  US-26.4.6 through `VerificationRunnerWorker.perform/1` when loopctl's OWN database is the
  obstacle: a lock another connection holds on the run row, on `story_stages` or on
  `runner_dispatches`. Each is a wait on the database cadence that counts no forge fault and
  changes nothing, never a verdict or `internal_error`.

  `async: false`, with COMMITTED rows, because the subject is a lock held by a SECOND
  connection: a `verification_runs` row held `FOR UPDATE`, or `story_stages` /
  `runner_dispatches` held `ACCESS EXCLUSIVE`. A lock cannot be held against the test's own
  connection and another session cannot see a sandboxed row; a table lock on those shared
  tables would also stall every async test writing them. Every other forge path is in the
  async `Loopctl.Workers.VerificationRunnerWorkerIntegrationTest`.

  Cleanup deletes ONLY what this module created: each test's own tenant, by id, on exit
  (`purge/1`, then `sweep_committed_tenants/1`). Never the `committed-runner-%` slug sweep,
  which deletes every committed runner tenant in the database, not only this test's.
  """

  use ExUnit.Case, async: false

  import Loopctl.Fixtures
  import Loopctl.Test.VerificationRunnerForge
  import Mox

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.ForgeRepo
  alias Loopctl.MockPullRequestSource
  alias Loopctl.MockVerificationCredential
  alias Loopctl.Repo
  alias Loopctl.Test.RowLock
  alias Loopctl.Test.VerificationRunnerForge

  @repo VerificationRunnerForge.repo()
  @branch VerificationRunnerForge.branch()
  @sha VerificationRunnerForge.sha()
  @short VerificationRunnerForge.short()

  # How long a table-lock holder keeps its lock with nobody releasing it.
  @holder_ttl_ms 60_000

  setup :verify_on_exit!

  setup do
    Loopctl.DataCase.stub_all_defaults()

    tenant = fixture(:committed_tenant, %{})
    # AdminRepo runs on Repo's connection in test, so this one checkout carries both.
    :ok = Sandbox.checkout(Repo, sandbox: false)

    on_exit(fn ->
      purge(tenant.id)
      sweep_committed_tenants([tenant.id])
    end)

    setup_story!(tenant.id)
  end

  describe "the change check, once per run" do
    setup ctx do
      fixture(:story_stage, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story_id,
        stage: :implementing,
        branch: @branch
      })

      :ok
    end

    # Round 4, finding 4: a check that passed but could not be RECORDED is loopctl's database,
    # not a verdict: a wait that leaves the fault streak alone, and the next poll checks again.
    test "a passed check loopctl cannot record is a wait, never internal_error", ctx do
      run = fixture(:verification_run, Map.put(ctx, :ci_forge_faults, 2))

      # The run row is locked AFTER the run started and before the stamp is written.
      stub_forge(ctx, %{
        compare: fn ->
          lock_run_once!(run)
          {:ok, build(:forge_comparison, %{files: ["lib/widgets/thing.ex"]})}
        end,
        evidence: build(:forge_evidence)
      })

      assert {:snooze, 60} = perform_busy(ctx, run)
      release_run_lock!()

      reloaded = reload(ctx, run)
      assert reloaded.status == "running"
      assert reloaded.change_checked_at == nil
      assert reloaded.ci_forge_faults == 2
      assert_received {:compare, @sha}
      refute_received {:evidence, _}

      # Released: the next poll checks again, records it, and is judged.
      assert :ok = perform(ctx, run)
      assert_received {:compare, @sha}
      assert %{status: "pass", change_checked_at: %DateTime{}} = reload(ctx, run)
    end

    test "a stage row loopctl cannot read is a wait, not a verdict", ctx do
      stub_forge(ctx, %{evidence: build(:forge_evidence)})
      run = fixture(:verification_run, Map.put(ctx, :ci_forge_faults, 2))
      hold_table_lock!("story_stages")

      assert {:snooze, 60} = perform(ctx, run)

      reloaded = reload(ctx, run)
      assert reloaded.status == "running"
      assert reloaded.ci_forge_faults == 2
      refute_received {:credential_asked, _, _}
      refute_received {:compare, _}
    end
  end

  describe "transient waits" do
    setup ctx do
      fixture(:story_stage, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story_id,
        stage: :implementing,
        branch: @branch
      })

      :ok
    end

    # Review round 1, finding 3(b): the dispatch ledger is loopctl's own database, not the
    # forge. Contention there snoozes without touching the fault streak, and reads nothing.
    test "database contention resolving the branch is not a forge fault", ctx do
      stub_forge(ctx, %{evidence: build(:forge_evidence)})
      run = fixture(:verification_run, Map.put(ctx, :ci_forge_faults, 2))
      hold_ledger_lock!()

      assert {:snooze, 60} = perform(ctx, run)

      reloaded = reload(ctx, run)
      assert reloaded.status == "running"
      assert reloaded.ci_forge_faults == 2
      refute_received {:compare, _}
      refute_received {:credential_asked, _, _}
    end

    test "database contention past the age window records database_busy", ctx do
      stub_forge(ctx, %{evidence: build(:forge_evidence)})
      run = fixture(:verification_run, Map.put(ctx, :age_seconds, 25 * 60 * 60))
      hold_ledger_lock!()

      assert :ok = perform(ctx, run)

      assert reload(ctx, run).ac_results == %{
               "source" => "ci",
               "ci_unavailable_reason" => "database_busy"
             }
    end
  end

  # -- every write the runner makes to its run ------------------------------------------------

  # Round 5: every write the worker makes to its own run is bounded, and one it cannot make is
  # a snooze on the database cadence with the run EXACTLY as it was (`updated_at` included):
  # never `internal_error`, never a forge fault counted. Each test locks the run from inside
  # the read just before the write under test; the run is already started and change-checked
  # (`ready!/1`), so that write is the only one the poll makes. Released, the next poll redoes
  # the work and records it.
  describe "a write loopctl cannot make to its run is a wait, and changes nothing" do
    setup ctx do
      fixture(:story_stage, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story_id,
        stage: :implementing,
        branch: @branch
      })

      :ok
    end

    test "starting the run", ctx do
      stub_forge(ctx, %{evidence: build(:forge_evidence)})
      run = fixture(:verification_run, ctx)
      before = snapshot(ctx, run)
      lock_run_once!(run)

      assert {:snooze, 60} = perform_busy(ctx, run)
      assert snapshot(ctx, run) == before
      refute_received {:credential_asked, _, _}

      release_run_lock!()
      assert :ok = perform(ctx, run)
      assert reload(ctx, run).status == "pass"
    end

    test "retiring a stale run", ctx do
      run =
        fixture(:verification_run, Map.merge(ctx, %{age_seconds: 25 * 60 * 60, started: false}))

      before = snapshot(ctx, run)
      lock_run_once!(run)

      assert {:snooze, 900} = perform_busy(ctx, run)
      assert snapshot(ctx, run) == before

      release_run_lock!()
      assert {:cancel, :stale_run} = perform(ctx, run)
      assert reload(ctx, run).status == "skipped"
    end

    test "recording the resolved SHA", ctx do
      stub_forge(ctx, %{evidence: build(:forge_evidence)})
      run = fixture(:verification_run, Map.merge(ctx, %{commit_sha: @short, ready: true}))
      before = snapshot(ctx, run)

      expect(MockPullRequestSource, :resolve_commit, 2, fn %ForgeRepo{full_name: @repo}, @short ->
        lock_run_once!(run)
        {:ok, @sha}
      end)

      assert {:snooze, 60} = perform_busy(ctx, run)
      assert snapshot(ctx, run) == before
      refute_received {:evidence, _}

      release_run_lock!()
      assert :ok = perform(ctx, run)
      assert %{status: "pass", resolved_commit_sha: @sha} = reload(ctx, run)
    end

    test "recording a pass", ctx do
      run = fixture(:verification_run, Map.put(ctx, :ready, true))
      stub_forge(ctx, %{evidence: locking(run, build(:forge_evidence))})
      before = snapshot(ctx, run)

      assert {:snooze, 60} = perform_busy(ctx, run)
      assert snapshot(ctx, run) == before

      release_run_lock!()
      assert :ok = perform(ctx, run)
      assert reload(ctx, run).status == "pass"
    end

    test "recording a fail", ctx do
      run = fixture(:verification_run, Map.put(ctx, :ready, true))
      failed = build(:forge_evidence, %{status: "completed", conclusion: "failure"})
      stub_forge(ctx, %{evidence: locking(run, failed)})
      before = snapshot(ctx, run)

      assert {:snooze, 60} = perform_busy(ctx, run)
      assert snapshot(ctx, run) == before

      release_run_lock!()
      assert :ok = perform(ctx, run)
      assert reload(ctx, run).status == "fail"
    end

    # The fault is not counted, and the snooze is the database's, not the streak's backoff.
    test "counting a forge fault", ctx do
      run = fixture(:verification_run, Map.merge(ctx, %{ready: true, ci_forge_faults: 2}))
      stub_forge(ctx, %{evidence: locking(run, {:error, {:github_api_error, 503}})})
      before = snapshot(ctx, run)

      assert {:snooze, 60} = perform_busy(ctx, run)
      assert snapshot(ctx, run) == before

      release_run_lock!()
      assert {:snooze, 240} = perform(ctx, run)
      assert reload(ctx, run).ci_forge_faults == 3
    end

    test "resetting the fault streak on an answered wait", ctx do
      run = fixture(:verification_run, Map.merge(ctx, %{ready: true, ci_forge_faults: 2}))
      pending = build(:forge_evidence, %{status: "queued", conclusion: nil})
      stub_forge(ctx, %{evidence: locking(run, pending)})
      before = snapshot(ctx, run)

      assert {:snooze, 60} = perform_busy(ctx, run)
      assert snapshot(ctx, run) == before

      release_run_lock!()
      assert {:snooze, 60} = perform(ctx, run)
      assert reload(ctx, run).ci_forge_faults == 0
    end

    test "recording a no-verdict", ctx do
      run = fixture(:verification_run, Map.put(ctx, :ready, true))
      stub_forge(ctx, %{evidence: locking(run, {:error, {:github_api_error, 404}})})
      before = snapshot(ctx, run)

      assert {:snooze, 60} = perform_busy(ctx, run)
      assert snapshot(ctx, run) == before

      release_run_lock!()
      assert :ok = perform(ctx, run)

      assert %{status: "error", ac_results: %{"ci_unavailable_reason" => "forge_not_found"}} =
               reload(ctx, run)
    end

    test "recording internal_error after a crash", ctx do
      run = fixture(:verification_run, Map.put(ctx, :ready, true))

      stub(MockVerificationCredential, :for_read, fn _tenant_id, _repo ->
        lock_run_once!(run)
        raise "boom"
      end)

      before = snapshot(ctx, run)

      {result, log} = ExUnit.CaptureLog.with_log(fn -> perform(ctx, run) end)
      assert result == {:snooze, 60}
      assert log =~ "crashed"
      assert busy_warnings(ctx, log) == 1
      assert snapshot(ctx, run) == before

      release_run_lock!()
      {result, _log} = ExUnit.CaptureLog.with_log(fn -> perform(ctx, run) end)
      assert result == {:cancel, :internal_error}
      assert reload(ctx, run).ac_results["ci_unavailable_reason"] == "internal_error"
    end
  end

  # Review round 1, finding 10: this module's cleanup deletes its own tenant and nothing of
  # another suite's, which shares the test database from another worktree.
  test "cleanup deletes only the tenants it names", ctx do
    other = fixture(:committed_tenant, %{})
    on_exit(fn -> sweep_committed_tenants([other.id]) end)

    # Both calls run unboxed, which gives up this process's AdminRepo checkout.
    :ok = sweep_committed_tenants([Ecto.UUID.generate()])
    checkout_admin()

    assert AdminRepo.get(Loopctl.Tenants.Tenant, other.id)
    assert AdminRepo.get(Loopctl.Tenants.Tenant, ctx.tenant_id)

    :ok = sweep_committed_tenants([other.id])
    checkout_admin()
    refute AdminRepo.get(Loopctl.Tenants.Tenant, other.id)
  end

  # -- plumbing ------------------------------------------------------------------------------

  defp checkout_admin do
    case Sandbox.checkout(Loopctl.Repo, sandbox: false) do
      :ok -> :ok
      {:already, :owner} -> :ok
    end
  end

  # `verification_runs` and `api_keys` reference the tenant without a cascade, so they go
  # before `sweep_committed_tenants/1` can delete it. By this test's tenant id only.
  defp purge(tenant_id) do
    checkout_admin()
    raw = Ecto.UUID.dump!(tenant_id)
    AdminRepo.query!("DELETE FROM verification_runs WHERE tenant_id = $1", [raw])
    AdminRepo.query!("DELETE FROM api_keys WHERE tenant_id = $1", [raw])
  end

  # A lock on the dispatch ledger held by another connection until the test ends: the
  # route read waits out its lock_timeout and answers `:busy` (as in the merge gate's own
  # integration test).
  defp hold_ledger_lock!, do: hold_table_lock!("runner_dispatches")

  # A poll whose write waits out its lock_timeout, answered as a wait: ONE busy warning, naming
  # 55P03 (lock_not_available, so the bounded wait and not the query timeout's lost connection),
  # and no crash. A write that raised instead would reach the rescue arm, log the crash, and
  # try its `internal_error` write against the same lock: a second warning.
  defp perform_busy(ctx, run) do
    {result, log} = ExUnit.CaptureLog.with_log(fn -> perform(ctx, run) end)
    assert busy_warnings(ctx, log) == 1
    refute log =~ "crashed"
    result
  end

  defp busy_warnings(ctx, log) do
    ~r/gave up waiting: tenant_id=#{ctx.tenant_id} error="55P03"/ |> Regex.scan(log) |> length()
  end

  # An evidence answer that locks the run first, once.
  defp locking(run, answer) do
    fn ->
      lock_run_once!(run)
      answer
    end
  end

  # Locks the run on the FIRST call only, so the poll after `release_run_lock!/0` writes
  # freely. A row lock on one verification run, held by another connection
  # (`Loopctl.Test.RowLock`) until released or the test ends: the run's next write waits out
  # its lock_timeout.
  defp lock_run_once!(run) do
    unless Process.get(:run_lock),
      do: Process.put(:run_lock, RowLock.hold!("verification_runs", run.id))

    :ok
  end

  defp release_run_lock!, do: RowLock.release(Process.get(:run_lock))

  # A table lock held by another connection until released or the test ends. The release is
  # registered BEFORE waiting for the lock, so a holder that is slow to report still gets
  # it, and the holder gives up by itself after `@holder_ttl_ms`: it is unlinked, and a
  # receive with no timeout would keep the lock, and its connection, past a test that died
  # without running its `on_exit`.
  defp hold_table_lock!(table) do
    test_pid = self()

    holder =
      spawn(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        Repo.transaction(fn ->
          Repo.query!("LOCK TABLE #{table} IN ACCESS EXCLUSIVE MODE")
          send(test_pid, :held)

          receive do
            :release -> :ok
          after
            @holder_ttl_ms -> :ok
          end
        end)

        Sandbox.checkin(Repo)
      end)

    on_exit(fn -> send(holder, :release) end)
    assert_receive :held, 5_000
    holder
  end
end
