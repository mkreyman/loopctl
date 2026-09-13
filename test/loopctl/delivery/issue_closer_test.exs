defmodule Loopctl.Delivery.IssueCloserTest do
  @moduledoc """
  The outward half of #805: closing a reporter's GitHub issue with the resolution its
  verdict implies, at most once, and never for an escalation.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.IssueCloser
  alias Loopctl.Delivery.Resolution
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Intake.IssueClosure
  alias Loopctl.Intake.IssueClosures
  alias Loopctl.MockPullRequestSource

  setup :verify_on_exit!

  @shipped_label "loopctl:resolution-shipped"
  @not_actionable_label "loopctl:resolution-not-actionable"

  setup do
    tenant = fixture(:tenant)
    record = fixture(:intake_record, %{tenant_id: tenant.id, repo: AdminRepo, issue_number: 77})
    story = fixture(:story, %{tenant_id: tenant.id})

    %{tenant: tenant, record: record, story: story}
  end

  describe "a shipped verdict" do
    test "closes with the shipped text and label, and with neither the skip label nor not_planned",
         ctx do
      closure = closure(ctx, :shipped)

      expect_open_issue()

      parent = self()

      expect(MockPullRequestSource, :label_issue, fn repo, number, label ->
        send(parent, {:labelled, repo, number, label})
        :ok
      end)

      expect(MockPullRequestSource, :comment_issue, fn _repo, _number, body ->
        send(parent, {:commented, body})
        :ok
      end)

      expect(MockPullRequestSource, :close_issue, fn _repo, _number, state_reason ->
        send(parent, {:closed, state_reason})
        :ok
      end)

      assert {:closed, nil} = IssueCloser.close(closure)

      assert_received {:labelled, "mkreyman/home_care_billing", 77, @shipped_label}
      assert_received {:commented, body}
      assert body == Resolution.for_verdict(:shipped).resolution_notes
      assert_received {:closed, :completed}

      # The label the reporting system skips on is NOT the one a shipped close carries.
      refute body =~ "no change was made"
      assert %IssueClosure{status: :closed} = reload(ctx)
    end

    test "the LABEL goes on before the CLOSE, which is the whole point of #805", ctx do
      closure = closure(ctx, :shipped)

      expect_open_issue()

      parent = self()

      expect(MockPullRequestSource, :label_issue, fn _r, _n, _l ->
        send(parent, :label)
        :ok
      end)

      expect(MockPullRequestSource, :comment_issue, fn _r, _n, _b ->
        send(parent, :comment)
        :ok
      end)

      expect(MockPullRequestSource, :close_issue, fn _r, _n, _s ->
        send(parent, :close)
        :ok
      end)

      assert {:closed, nil} = IssueCloser.close(closure)

      # The reporting system's webhook fires ON THE CLOSE and picks its resolution text by
      # the label it finds. A close that lands first is read with the default text — "Our
      # team has shipped a fix for this issue" — which for a reject is the exact message this
      # change exists to prevent. So the order is load-bearing, not incidental.
      assert receive_order() == [:label, :comment, :close]
    end
  end

  describe "a not_actionable verdict" do
    test "closes with the not-actionable text AND the skip label, as not_planned", ctx do
      closure = closure(ctx, :not_actionable)

      expect_open_issue()

      parent = self()

      expect(MockPullRequestSource, :label_issue, fn _repo, _number, label ->
        send(parent, {:labelled, label})
        :ok
      end)

      expect(MockPullRequestSource, :comment_issue, fn _repo, _number, body ->
        send(parent, {:commented, body})
        :ok
      end)

      expect(MockPullRequestSource, :close_issue, fn _repo, _number, state_reason ->
        send(parent, {:closed, state_reason})
        :ok
      end)

      assert {:closed, nil} = IssueCloser.close(closure)

      assert_received {:labelled, @not_actionable_label}
      assert_received {:commented, body}
      assert body == Resolution.for_verdict(:not_actionable).resolution_notes

      # The failure this whole change exists to prevent: a reject must never say a fix
      # shipped, because the reporting system's default text on an unlabelled close does.
      refute body =~ "shipped a fix"
      assert body =~ "no change was made"
      assert_received {:closed, :not_planned}
    end
  end

  describe "an escalated verdict" do
    test "closes nothing, because no closure row can exist for one" do
      # `:escalated` resolves to `close?: false`, so it is not in the storable set at all.
      # The guarantee is structural rather than a branch in the closer: there is no row for
      # an escalated story, so there is nothing for the drainer to pick up.
      refute :escalated in IssueClosure.verdicts()
      refute Resolution.for_verdict(:escalated).close?
      assert Resolution.for_verdict(:escalated).label == nil

      assert Enum.sort(IssueClosure.verdicts()) == [:not_actionable, :shipped]
    end

    test "no escalating transition produces a resolution" do
      escalating =
        Enum.filter(StageMachine.transitions(), fn {_f, to, _e} ->
          to == :escalated
        end)

      assert escalating != []

      for transition <- escalating do
        assert StageMachine.resolution_verdict(transition) == nil
      end
    end
  end

  describe "a replay" do
    test "closes nothing a second time once the row is closed", ctx do
      closure = closure(ctx, :shipped)

      expect_open_issue()
      expect(MockPullRequestSource, :label_issue, fn _r, _n, _l -> :ok end)
      expect(MockPullRequestSource, :comment_issue, fn _r, _n, _b -> :ok end)
      expect(MockPullRequestSource, :close_issue, fn _r, _n, _s -> :ok end)

      assert {:closed, nil} = IssueCloser.close(closure)

      # Not one further forge call: the row is terminal, so the claim is refused before any
      # of the mocks above could be reached a second time (and they were `expect`ed once).
      assert {:skipped, nil} = IssueCloser.close(reload(ctx))
      assert {:skipped, nil} = IssueCloser.close(closure)
    end

    test "an issue already closed carrying our label is recorded closed, not closed again",
         ctx do
      closure = closure(ctx, :shipped)

      # The crash window: the close landed, the record of it did not. The only evidence is
      # GitHub's own state, so that is what is read.
      expect(MockPullRequestSource, :issue, fn _repo, _number ->
        {:ok, %{state: "closed", labels: ["bug", @shipped_label]}}
      end)

      assert {:closed, nil} = IssueCloser.close(closure)
      assert %IssueClosure{status: :closed} = reload(ctx)
    end
  end

  describe "a permanent failure" do
    test "an issue closed by a human is abandoned, never reopened or re-closed", ctx do
      closure = closure(ctx, :shipped)

      expect(MockPullRequestSource, :issue, fn _repo, _number ->
        {:ok, %{state: "closed", labels: ["duplicate"]}}
      end)

      assert {:abandoned, nil} = IssueCloser.close(closure)

      row = reload(ctx)
      assert row.status == :abandoned
      assert row.abandoned_reason == "closed_by_other"
      assert row.closed_at == nil
    end

    test "a 404 is abandoned on the first attempt and never retried", ctx do
      closure = closure(ctx, :shipped)

      expect(MockPullRequestSource, :issue, fn _repo, _number ->
        {:error, {:github_api_error, 404}}
      end)

      assert {:abandoned, nil} = IssueCloser.close(closure)

      row = reload(ctx)
      assert row.status == :abandoned
      assert row.abandoned_reason =~ "permanent_forge_failure"
      assert row.last_error =~ "404"

      # And it is out of the drainer's candidate set for good.
      refute row.id in Enum.map(IssueClosures.due(50), & &1.id)
    end

    test "a 403 the headers do not call a rate limit is permanent", ctx do
      closure = closure(ctx, :shipped)

      expect_open_issue()
      expect(MockPullRequestSource, :label_issue, fn _r, _n, _l -> :ok end)
      expect(MockPullRequestSource, :comment_issue, fn _r, _n, _b -> :ok end)

      expect(MockPullRequestSource, :close_issue, fn _r, _n, _s ->
        {:error, {:github_api_error, 403}}
      end)

      assert {:abandoned, nil} = IssueCloser.close(closure)
      assert %IssueClosure{status: :abandoned} = reload(ctx)
    end
  end

  describe "a transient failure" do
    test "is retried: the row stays pending and backs off", ctx do
      closure = closure(ctx, :shipped)

      expect(MockPullRequestSource, :issue, fn _repo, _number ->
        {:error, {:github_unreachable, :timeout}}
      end)

      assert {:deferred, nil} = IssueCloser.close(closure)

      row = reload(ctx)
      assert row.status == :pending
      assert row.attempts == 1
      assert %DateTime{} = row.next_attempt_at
      assert row.last_error =~ "github_unreachable"
    end

    test "a rate limit reports its retry_after, so the caller can halt the batch", ctx do
      closure = closure(ctx, :shipped)

      expect(MockPullRequestSource, :issue, fn _repo, _number ->
        {:error, {:github_rate_limited, 403, 90}}
      end)

      assert {:deferred, 90} = IssueCloser.close(closure)
      assert %IssueClosure{status: :pending} = reload(ctx)
    end

    test "a step that already succeeded is not repeated on the retry", ctx do
      closure = closure(ctx, :shipped)

      # Attempt 1: label and comment land, the close does not.
      expect_open_issue()
      expect(MockPullRequestSource, :label_issue, fn _r, _n, _l -> :ok end)
      expect(MockPullRequestSource, :comment_issue, fn _r, _n, _b -> :ok end)

      expect(MockPullRequestSource, :close_issue, fn _r, _n, _s ->
        {:error, {:github_api_error, 502}}
      end)

      assert {:deferred, nil} = IssueCloser.close(closure)

      after_first = reload(ctx)
      assert %DateTime{} = after_first.labelled_at
      assert %DateTime{} = after_first.commented_at

      # Attempt 2: ONE issue read and ONE close. No second label and — the one that matters —
      # NO SECOND COMMENT on the reporter's ticket. `expect/3` with no label_issue or
      # comment_issue expectation means a call to either fails this test.
      expect_open_issue()
      expect(MockPullRequestSource, :close_issue, fn _r, _n, _s -> :ok end)

      assert {:closed, nil} = IssueCloser.close(%{after_first | next_attempt_at: nil})
      assert %IssueClosure{status: :closed} = reload(ctx)
    end

    test "the transient path is bounded: it abandons rather than retrying for ever", ctx do
      _closure = closure(ctx, :shipped)

      max = IssueClosures.max_attempts()

      expect(MockPullRequestSource, :issue, max, fn _repo, _number ->
        {:error, {:github_api_error, 500}}
      end)

      outcomes =
        Enum.map(1..max, fn _attempt ->
          {outcome, _retry} = IssueCloser.close(clear_backoff(ctx))
          outcome
        end)

      assert List.last(outcomes) == :abandoned
      assert Enum.take(outcomes, max - 1) == List.duplicate(:deferred, max - 1)

      row = reload(ctx)
      assert row.status == :abandoned
      assert row.abandoned_reason == "retries_exhausted"
    end
  end

  describe "tenant isolation" do
    test "a closure is only ever acted on with its own tenant's scope", ctx do
      other = fixture(:tenant)
      closure = closure(ctx, :shipped)

      # Every write the closer makes goes through the tenant on the ROW, so a caller cannot
      # substitute another tenant's scope to reach it.
      assert {:error, :not_pending} = IssueClosures.claim_attempt(other.id, closure.id)
      assert IssueClosures.due(50) |> Enum.map(& &1.tenant_id) |> Enum.uniq() == [ctx.tenant.id]
    end
  end

  defp closure(ctx, verdict) do
    fixture(:issue_closure, %{
      tenant_id: ctx.tenant.id,
      story_id: ctx.story.id,
      intake_record: ctx.record,
      verdict: verdict
    })
  end

  defp expect_open_issue do
    expect(MockPullRequestSource, :issue, fn _repo, _number ->
      {:ok, %{state: "open", labels: ["bug"]}}
    end)
  end

  defp reload(ctx), do: IssueClosures.get(ctx.tenant.id, ctx.story.id)

  # Drains the mailbox in arrival order, which IS the order the closer made its calls in.
  defp receive_order(acc \\ []) do
    receive do
      step -> receive_order([step | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The bound test drives attempts back to back; production waits out the backoff instead.
  defp clear_backoff(ctx) do
    row = reload(ctx)
    %{row | next_attempt_at: nil}
  end
end
