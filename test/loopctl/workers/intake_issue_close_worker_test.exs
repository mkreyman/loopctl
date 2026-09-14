defmodule Loopctl.Workers.IntakeIssueCloseWorkerTest do
  @moduledoc """
  The drainer (#805): it must close what is due, halt on a rate limit, respect its wall
  clock, and — the property that matters most — never close anything twice.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Intake.IssueClosure
  alias Loopctl.Intake.IssueClosures
  alias Loopctl.MockPullRequestSource
  alias Loopctl.Workers.IntakeIssueCloseWorker

  setup :verify_on_exit!

  setup do
    %{tenant: fixture(:tenant)}
  end

  test "closes a due closure end to end", ctx do
    closure = closure(ctx, :shipped)

    stub_full_close()

    assert :ok = IntakeIssueCloseWorker.perform(%Oban.Job{args: %{}})
    assert %IssueClosure{status: :closed} = AdminRepo.get(IssueClosure, closure.id)
  end

  test "a second run closes nothing a second time", ctx do
    closure = closure(ctx, :shipped)

    # EXACTLY one of each WRITE across BOTH runs. A second close would fail this by count,
    # which is the assertion that actually guards the reporter's inbox. Two READS, because
    # the closer re-reads the state immediately before the irreversible act.
    expect(MockPullRequestSource, :issue, 2, fn _r, _n -> {:ok, %{state: "open", labels: []}} end)
    expect(MockPullRequestSource, :label_issue, fn _r, _n, _l -> :ok end)
    expect(MockPullRequestSource, :comment_issue, fn _r, _n, _b -> :ok end)
    expect(MockPullRequestSource, :close_issue, fn _r, _n, _s -> :ok end)

    assert :ok = IntakeIssueCloseWorker.perform(%Oban.Job{args: %{}})
    assert :ok = IntakeIssueCloseWorker.perform(%Oban.Job{args: %{}})

    assert %IssueClosure{status: :closed} = AdminRepo.get(IssueClosure, closure.id)
  end

  test "a story with no closure row is not a candidate", ctx do
    # Nothing to drain, so not one forge call — the default stubs are all `:not_stubbed`
    # errors, so a call would abandon a row and the assertion below would see it.
    assert :ok = IntakeIssueCloseWorker.perform(%Oban.Job{args: %{}})
    assert IssueClosures.list(ctx.tenant.id) == []
  end

  test "a rate limit halts the run before the next candidate", ctx do
    first = closure(ctx, :shipped)
    second = closure(ctx, :shipped)

    # ONE issue read. If the run carried on to the second candidate there would be two, and
    # the second would spend a call against a forge that just said it is out of quota.
    expect(MockPullRequestSource, :issue, fn _r, _n ->
      {:error, {:github_rate_limited, 403, 60}}
    end)

    assert :ok = IntakeIssueCloseWorker.perform(%Oban.Job{args: %{}})

    # The first backed off; the second was never touched.
    assert %IssueClosure{attempts: 1} = AdminRepo.get(IssueClosure, first.id)
    assert %IssueClosure{attempts: 0} = AdminRepo.get(IssueClosure, second.id)
  end

  test "the wall-clock budget is checked BEFORE a candidate, not after", ctx do
    closure = closure(ctx, :shipped)

    # A deadline already in the past. Checked afterwards, this run would still make four
    # outward calls for the first candidate; checked before, it makes none — and the default
    # stubs would abandon the row if it did.
    past = System.monotonic_time(:millisecond) - 1

    assert IntakeIssueCloseWorker.sweep(IssueClosures.due(10), past) == []
    assert %IssueClosure{status: :pending, attempts: 0} = AdminRepo.get(IssueClosure, closure.id)
  end

  test "a backed-off closure is not picked up until its time", ctx do
    closure =
      fixture(:issue_closure, %{
        tenant_id: ctx.tenant.id,
        story_id: fixture(:story, %{tenant_id: ctx.tenant.id}).id,
        intake_record: fixture(:intake_record, %{tenant_id: ctx.tenant.id, repo: AdminRepo}),
        next_attempt_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    assert :ok = IntakeIssueCloseWorker.perform(%Oban.Job{args: %{}})
    assert %IssueClosure{status: :pending, attempts: 0} = AdminRepo.get(IssueClosure, closure.id)
  end

  test "an abandoned closure is never picked up again", ctx do
    closure = closure(ctx, :shipped)

    {:ok, _row} =
      IssueClosures.mark_abandoned(ctx.tenant.id, closure.id, :closed_by_other, :human)

    assert :ok = IntakeIssueCloseWorker.perform(%Oban.Job{args: %{}})

    assert %IssueClosure{status: :abandoned, attempts: 0} =
             AdminRepo.get(IssueClosure, closure.id)
  end

  test "one candidate that RAISES does not kill the run", ctx do
    raiser = closure(ctx, :shipped)
    survivor = closure(ctx, :shipped)

    # `due/1` reads oldest-first, so the raiser is first. An exception propagating out of
    # `perform/1` would skip every remaining candidate, burn an Oban attempt, and — since the
    # raiser stays at the head — do it again on every sweep, stalling closures fleet-wide.
    parent = self()

    stub(MockPullRequestSource, :issue, fn _repo, number ->
      if number == raiser.issue_number do
        raise "the forge adapter blew up"
      else
        send(parent, {:reached, number})
        {:ok, %{state: "open", labels: []}}
      end
    end)

    stub(MockPullRequestSource, :label_issue, fn _r, _n, _l -> :ok end)
    stub(MockPullRequestSource, :comment_issue, fn _r, _n, _b -> :ok end)
    stub(MockPullRequestSource, :close_issue, fn _r, _n, _s -> :ok end)

    assert :ok = IntakeIssueCloseWorker.perform(%Oban.Job{args: %{}})

    # The batch continued and the survivor closed.
    assert_received {:reached, _}
    assert %IssueClosure{status: :closed} = AdminRepo.get(IssueClosure, survivor.id)

    # And the raiser is not left at the head of the queue: `claim_attempt/2` scheduled it
    # forward before anything outward ran, so a crash behaves like a transient failure and is
    # still bounded by the attempt counter.
    raised = AdminRepo.get(IssueClosure, raiser.id)
    assert raised.status == :pending
    assert raised.attempts == 1
    assert %DateTime{} = raised.next_attempt_at
    refute raised.id in Enum.map(IssueClosures.due(50), & &1.id)
  end

  test "a whole batch erroring is a FAILED job, not a clean run", ctx do
    for _n <- 1..2, do: closure(ctx, :shipped)

    # A pool outage, a dead adapter, a bad deploy: every candidate fails. The per-candidate
    # rescue is right for one bad row and wrong for a bad world — swallowing all of them made
    # `perform/1` return `:ok`, so Oban recorded a clean run, `max_attempts` never fired,
    # nothing reached `discarded`, and the only trace was log lines nobody was watching.
    stub(MockPullRequestSource, :issue, fn _r, _n -> raise "everything is on fire" end)

    assert {:error, {:all_candidates_errored, 2}} =
             IntakeIssueCloseWorker.perform(%Oban.Job{args: %{}})
  end

  test "an EXIT is caught too, not just a raise", ctx do
    survivor = closure(ctx, :shipped)
    exiter = closure(ctx, :shipped)

    # Rescue alone missed the class this containment was written for: a Finch pool checkout,
    # a GenServer.call timeout and a DBConnection ownership failure all EXIT rather than
    # raise, so each still killed the batch while the rescue looked like it covered them.
    stub(MockPullRequestSource, :issue, fn _repo, number ->
      if number == exiter.issue_number do
        exit({:timeout, {GenServer, :call, [:some_pool, :checkout, 5_000]}})
      else
        {:ok, %{state: "open", labels: []}}
      end
    end)

    stub(MockPullRequestSource, :label_issue, fn _r, _n, _l -> :ok end)
    stub(MockPullRequestSource, :comment_issue, fn _r, _n, _b -> :ok end)
    stub(MockPullRequestSource, :close_issue, fn _r, _n, _s -> :ok end)

    assert :ok = IntakeIssueCloseWorker.perform(%Oban.Job{args: %{}})

    assert %IssueClosure{status: :closed} = AdminRepo.get(IssueClosure, survivor.id)
    assert %IssueClosure{status: :pending, attempts: 1} = AdminRepo.get(IssueClosure, exiter.id)
  end

  test "some errors alongside progress is still a successful run", ctx do
    survivor = closure(ctx, :shipped)
    raiser = closure(ctx, :shipped)

    # The one-bad-row case the rescue exists for. Failing the job here would retry the whole
    # batch for a row whose own attempt counter already bounds it.
    stub(MockPullRequestSource, :issue, fn _repo, number ->
      if number == raiser.issue_number,
        do: raise("one bad row"),
        else: {:ok, %{state: "open", labels: []}}
    end)

    stub(MockPullRequestSource, :label_issue, fn _r, _n, _l -> :ok end)
    stub(MockPullRequestSource, :comment_issue, fn _r, _n, _b -> :ok end)
    stub(MockPullRequestSource, :close_issue, fn _r, _n, _s -> :ok end)

    assert :ok = IntakeIssueCloseWorker.perform(%Oban.Job{args: %{}})
    assert %IssueClosure{status: :closed} = AdminRepo.get(IssueClosure, survivor.id)
  end

  test "an empty run is :ok, not an error" do
    assert :ok = IntakeIssueCloseWorker.perform(%Oban.Job{args: %{}})
  end

  test "the worker is scheduled on the crontab" do
    entries =
      Loopctl.ObanConfig.plugins() |> Keyword.get(Oban.Plugins.Cron) |> Keyword.get(:crontab)

    assert Enum.any?(entries, fn
             {_schedule, IntakeIssueCloseWorker} -> true
             {_schedule, IntakeIssueCloseWorker, _opts} -> true
             _other -> false
           end)
  end

  # A DISTINCT intake record per closure. `intake_issue_closures_record_uidx` allows exactly
  # one closure per record (#826 review, finding 3), so a test that needs two candidates needs
  # two records — which is also what production looks like.
  defp closure(ctx, verdict) do
    fixture(:issue_closure, %{
      tenant_id: ctx.tenant.id,
      story_id: fixture(:story, %{tenant_id: ctx.tenant.id}).id,
      intake_record: fixture(:intake_record, %{tenant_id: ctx.tenant.id, repo: AdminRepo}),
      verdict: verdict
    })
  end

  defp stub_full_close do
    stub(MockPullRequestSource, :issue, fn _r, _n -> {:ok, %{state: "open", labels: []}} end)
    stub(MockPullRequestSource, :label_issue, fn _r, _n, _l -> :ok end)
    stub(MockPullRequestSource, :comment_issue, fn _r, _n, _b -> :ok end)
    stub(MockPullRequestSource, :close_issue, fn _r, _n, _s -> :ok end)
  end
end
