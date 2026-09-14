defmodule Loopctl.Delivery.IssueCloserTest do
  @moduledoc """
  The outward half of #805: closing a reporter's GitHub issue with the resolution its
  verdict implies, at most once, and never for an escalation.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

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

    test "a close carrying the OTHER verdict's label is NOT ours", ctx do
      closure = closure(ctx, :not_actionable)

      # A maintainer labelled a not-actionable story's issue `resolution-shipped` and closed
      # it. The reporting system has already sent the SHIPPED text for work nobody did.
      # Reading "some loopctl label" as our own close recorded `:closed`, never posted the
      # not-actionable text, and left that wrong message standing — the exact #805 failure,
      # reached through the check meant to prevent it.
      expect(MockPullRequestSource, :issue, fn _repo, _number ->
        {:ok, %{state: "closed", labels: [@shipped_label]}}
      end)

      assert {:abandoned, nil} = IssueCloser.close(closure)

      row = reload(ctx)
      assert row.status == :abandoned
      assert row.abandoned_reason == "closed_by_other"
      assert row.closed_at == nil
    end

    test "a close carrying BOTH loopctl labels is ambiguous, not ours", ctx do
      closure = closure(ctx, :shipped)

      # `own_label in labels` accepted this. The reporting system resolves such a close by the
      # order IT sees, which may not be ours — so the reporter may have been sent the
      # not-actionable text while loopctl recorded the shipped closure as delivered.
      expect(MockPullRequestSource, :issue, fn _repo, _number ->
        {:ok, %{state: "closed", labels: [@not_actionable_label, @shipped_label]}}
      end)

      assert {:abandoned, nil} = IssueCloser.close(closure)

      row = reload(ctx)
      assert row.status == :abandoned
      assert row.abandoned_reason == "closed_by_other"
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

    test "PATHOLOGICAL label names do not stop the abandon from being recorded", ctx do
      closure = closure(ctx, :shipped)

      # A label name is unbounded REMOTE data, and `abandoned_reason`/`last_error` are
      # length-CHECKed columns. Echoing the names into the reason let a decorated label make
      # the abandon write itself raise — the one write that says "never retry this" — so the
      # row stayed pending at the head of an oldest-first queue and stalled the drainer for
      # every tenant. The reason carries the label COUNT instead.
      labels = for _n <- 1..200, do: String.duplicate("🇺🇸", 200)

      expect(MockPullRequestSource, :issue, fn _repo, _number ->
        {:ok, %{state: "closed", labels: labels}}
      end)

      assert {:abandoned, nil} = IssueCloser.close(closure)

      row = reload(ctx)
      assert row.status == :abandoned
      assert row.abandoned_reason == "closed_by_other"

      # And nothing of the label TEXT reached the row.
      refute row.last_error =~ "🇺🇸"
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

    test "a human close landing MID-SEQUENCE is detected instead of PATCHed over", ctx do
      closure = closure(ctx, :shipped)

      parent = self()

      # Read 1: open. We label and comment. Then a human closes it — their close fired the
      # reporting system's webhook with no loopctl label on the issue yet, so the reporter
      # already got the default shipped text.
      expect(MockPullRequestSource, :issue, fn _r, _n ->
        {:ok, %{state: "open", labels: []}}
      end)

      expect(MockPullRequestSource, :label_issue, fn _r, _n, _l -> :ok end)
      expect(MockPullRequestSource, :comment_issue, fn _r, _n, _b -> :ok end)

      # Read 2, immediately before the irreversible act: it moved — AND IT CARRIES OUR LABEL,
      # because step 2 POSTed it and GitHub accepts a label on a closed issue.
      #
      # This is the state GitHub can actually return, and the first version of this test
      # omitted it (`labels: ["wontfix"]`), which is why the check passed while being INERT:
      # re-running step 1's classifier on the real state finds our label, calls it
      # `already_closed_by_loopctl`, and records the human's close as ours. What decides it is
      # that read 1 saw the issue OPEN and nothing since calls `close_issue/3`.
      expect(MockPullRequestSource, :issue, fn _r, _n ->
        send(parent, :rechecked)
        {:ok, %{state: "closed", labels: ["wontfix", @shipped_label]}}
      end)

      # No `close_issue` expectation: PATCHing an already-closed issue is answered 200 by
      # GitHub, so without the re-read the close "succeeded", `closed_by_other` was never
      # recorded, and nothing told the operator the reporter had been misinformed.
      assert {:abandoned, nil} = IssueCloser.close(closure)

      assert_received :rechecked
      row = reload(ctx)
      assert row.status == :abandoned
      assert row.abandoned_reason == "closed_by_other"
      assert row.closed_at == nil
    end

    test "a mid-attempt close is closed_by_other even with NO label on the issue", ctx do
      closure = closure(ctx, :shipped)

      # The other real shape: the human's close landed before our label POST was visible. The
      # verdict is the same, because what decides it is that read 1 saw the issue OPEN — not
      # the labels, which by this point we have written to ourselves.
      expect(MockPullRequestSource, :issue, fn _r, _n ->
        {:ok, %{state: "open", labels: []}}
      end)

      expect(MockPullRequestSource, :label_issue, fn _r, _n, _l -> :ok end)
      expect(MockPullRequestSource, :comment_issue, fn _r, _n, _b -> :ok end)

      expect(MockPullRequestSource, :issue, fn _r, _n ->
        {:ok, %{state: "closed", labels: []}}
      end)

      assert {:abandoned, nil} = IssueCloser.close(closure)
      assert %IssueClosure{status: :abandoned, abandoned_reason: "closed_by_other"} = reload(ctx)
    end

    test "a REVOKED intake source stops every write, before the issue is even read", ctx do
      closure = closure(ctx, :shipped)

      # The tenant disconnected the repository. No `issue` expectation is set, so ANY forge
      # call — including the read — fails this test: with the write scope this feature added,
      # loopctl must not touch a repo a tenant has disconnected.
      {1, _} =
        AdminRepo.update_all(
          from(s in Loopctl.Intake.Source, where: s.id == ^ctx.record.source_id),
          set: [revoked_at: DateTime.utc_now()]
        )

      assert {:abandoned, nil} = IssueCloser.close(closure)

      row = reload(ctx)
      assert row.status == :abandoned
      assert row.abandoned_reason == "source_revoked"
      assert row.closed_at == nil
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

    test "the forge's retry_after is HONOURED, not just reported", ctx do
      closure = closure(ctx, :shipped)

      # A PRIMARY rate limit: GitHub's hourly window, and it says when it reopens. The local
      # backoff for attempt 1 is minutes; scheduling from that alone spent every attempt
      # inside one window the forge had already told us the end of, and abandoned a closure
      # with the reporter never notified.
      hour = 3_600

      expect(MockPullRequestSource, :issue, fn _repo, _number ->
        {:error, {:github_rate_limited, 403, hour}}
      end)

      before = DateTime.utc_now()
      assert {:deferred, ^hour} = IssueCloser.close(closure)

      row = reload(ctx)
      waited = DateTime.diff(row.next_attempt_at, before, :second)

      assert waited >= hour - 5,
             "expected the wait to honour the forge's #{hour}s, got #{waited}s"
    end

    test "a retry_after SHORTER than the local backoff does not shorten the wait", ctx do
      closure = closure(ctx, :shipped)

      # `max`, in both directions: the forge's number wins when it is longer, and the local
      # schedule wins when the forge asks for a token gesture that would hammer it.
      expect(MockPullRequestSource, :issue, fn _repo, _number ->
        {:error, {:github_rate_limited, 403, 1}}
      end)

      before = DateTime.utc_now()
      assert {:deferred, 1} = IssueCloser.close(closure)

      waited = DateTime.diff(reload(ctx).next_attempt_at, before, :second)
      assert waited >= IssueClosures.wait_seconds(1, nil) - 5
    end

    test "the first backoff is longer than the drainer's cron interval", _ctx do
      # A backoff at or under the interval is not backoff: the row is due again on the very
      # next sweep, and a struggling forge is hit at full cadence for the attempts that
      # matter most.
      interval = 120

      assert IssueClosures.wait_seconds(1, nil) > interval

      # And the whole schedule exceeds GitHub's hourly primary window even when the forge
      # says nothing, which is the claim the moduledoc now makes.
      total =
        Enum.reduce(1..(IssueClosures.max_attempts() - 1), 0, fn n, acc ->
          acc + IssueClosures.wait_seconds(n, nil)
        end)

      assert total > 3_600, "the whole retry schedule spans #{total}s, inside an hourly window"
    end

    test "the comment is not repeated on the retry", ctx do
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

      # Attempt 2, with the label STILL ON the issue: one read, one close, and — the one that
      # matters — NO SECOND COMMENT on the reporter's ticket. No `comment_issue` expectation
      # is set, so a call to it fails this test.
      expect_open_issue(labels: ["bug", @shipped_label])
      expect(MockPullRequestSource, :close_issue, fn _r, _n, _s -> :ok end)

      assert {:closed, nil} = IssueCloser.close(due(ctx))
      assert %IssueClosure{status: :closed} = reload(ctx)
    end

    test "the label is RE-APPLIED when a maintainer removed it between attempts", ctx do
      closure = closure(ctx, :shipped)

      # Attempt 1: label and comment land, the close 502s.
      expect_open_issue()
      expect(MockPullRequestSource, :label_issue, fn _r, _n, _l -> :ok end)
      expect(MockPullRequestSource, :comment_issue, fn _r, _n, _b -> :ok end)

      expect(MockPullRequestSource, :close_issue, fn _r, _n, _s ->
        {:error, {:github_api_error, 502}}
      end)

      assert {:deferred, nil} = IssueCloser.close(closure)
      assert %DateTime{} = reload(ctx).labelled_at

      # A maintainer removes the loopctl label. The MARKER still says we applied it, and
      # trusting the marker here is what closed the issue unlabelled — at which point the
      # reporting system falls back to its default text and tells the reporter a fix shipped.
      # So the live list decides, and the label goes back on.
      parent = self()
      expect_open_issue(labels: ["bug"])

      expect(MockPullRequestSource, :label_issue, fn _r, _n, label ->
        send(parent, {:relabelled, label})
        :ok
      end)

      expect(MockPullRequestSource, :close_issue, fn _r, _n, _s ->
        send(parent, :closed)
        :ok
      end)

      assert {:closed, nil} = IssueCloser.close(due(ctx))

      assert_received {:relabelled, @shipped_label}
      assert_received :closed
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

  # The closer reads the issue TWICE on any path that reaches the close: once for the replay
  # check, and once immediately before the irreversible act (#826 round 2, finding 8). `times`
  # is 2 by default for that reason; a test that stops earlier says so.
  defp expect_open_issue(opts \\ []) do
    labels = Keyword.get(opts, :labels, ["bug"])
    times = Keyword.get(opts, :times, 2)

    expect(MockPullRequestSource, :issue, times, fn _repo, _number ->
      {:ok, %{state: "open", labels: labels}}
    end)
  end

  defp reload(ctx), do: IssueClosures.get(ctx.tenant.id, ctx.story.id)

  defp due(ctx) do
    row = reload(ctx)
    :ok = make_due(row.id)
    reload(ctx)
  end

  # Drains the mailbox in arrival order, which IS the order the closer made its calls in.
  defp receive_order(acc \\ []) do
    receive do
      step -> receive_order([step | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The bound test drives attempts back to back; production waits out the backoff instead.
  #
  # Cleared in the DATABASE, not on the struct: since #826 round 2 the claim is a
  # compare-and-set on the row being DUE, so an in-memory nil would be refused — which is the
  # mutual exclusion working.
  defp clear_backoff(ctx) do
    row = reload(ctx)
    :ok = make_due(row.id)
    reload(ctx)
  end

  defp make_due(id) do
    {1, _} =
      AdminRepo.update_all(from(c in IssueClosure, where: c.id == ^id),
        set: [next_attempt_at: nil]
      )

    :ok
  end
end
