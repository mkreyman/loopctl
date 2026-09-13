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
    tenant = fixture(:tenant)
    record = fixture(:intake_record, %{tenant_id: tenant.id, repo: AdminRepo})
    %{tenant: tenant, record: record}
  end

  test "closes a due closure end to end", ctx do
    closure = closure(ctx, :shipped)

    stub_full_close()

    assert :ok = IntakeIssueCloseWorker.perform(%Oban.Job{args: %{}})
    assert %IssueClosure{status: :closed} = AdminRepo.get(IssueClosure, closure.id)
  end

  test "a second run closes nothing a second time", ctx do
    closure = closure(ctx, :shipped)

    # EXACTLY one of each write across BOTH runs. A second close would fail this by count,
    # which is the assertion that actually guards the reporter's inbox.
    expect(MockPullRequestSource, :issue, fn _r, _n -> {:ok, %{state: "open", labels: []}} end)
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
        intake_record: ctx.record,
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

  test "the worker is scheduled on the crontab" do
    entries =
      Loopctl.ObanConfig.plugins() |> Keyword.get(Oban.Plugins.Cron) |> Keyword.get(:crontab)

    assert Enum.any?(entries, fn
             {_schedule, IntakeIssueCloseWorker} -> true
             {_schedule, IntakeIssueCloseWorker, _opts} -> true
             _other -> false
           end)
  end

  defp closure(ctx, verdict) do
    fixture(:issue_closure, %{
      tenant_id: ctx.tenant.id,
      story_id: fixture(:story, %{tenant_id: ctx.tenant.id}).id,
      intake_record: ctx.record,
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
