defmodule Loopctl.Intake.IssueClosuresTest do
  @moduledoc """
  The issue-closure outbox (#805): the at-most-once record that loopctl closed, or will
  close, the GitHub issue a story came from.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Intake.IssueClosure
  alias Loopctl.Intake.IssueClosures

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant)
    record = fixture(:intake_record, %{tenant_id: tenant.id, repo: AdminRepo, issue_number: 41})
    story = fixture(:story, %{tenant_id: tenant.id})

    %{tenant: tenant, record: record, story: story}
  end

  describe "record_in/5" do
    test "records the target from the record and its source", ctx do
      assert :ok =
               IssueClosures.record_in(
                 AdminRepo,
                 ctx.tenant.id,
                 ctx.story.id,
                 ctx.record.id,
                 :shipped
               )

      assert %IssueClosure{} = closure = IssueClosures.get(ctx.tenant.id, ctx.story.id)
      assert closure.verdict == :shipped
      assert closure.status == :pending
      assert closure.issue_number == 41
      assert closure.repo_full_name == "mkreyman/home_care_billing"
      assert closure.intake_record_id == ctx.record.id
      assert closure.attempts == 0
    end

    test "a story with no intake link records nothing and is not an error", ctx do
      assert :no_link =
               IssueClosures.record_in(AdminRepo, ctx.tenant.id, ctx.story.id, nil, :shipped)

      assert IssueClosures.get(ctx.tenant.id, ctx.story.id) == nil
    end

    test "a replay leaves exactly one row", ctx do
      for _replay <- 1..3 do
        assert :ok =
                 IssueClosures.record_in(
                   AdminRepo,
                   ctx.tenant.id,
                   ctx.story.id,
                   ctx.record.id,
                   :shipped
                 )
      end

      assert [%IssueClosure{}] = IssueClosures.list(ctx.tenant.id)
    end

    test "a second verdict for the same story does not overwrite the first", ctx do
      :ok =
        IssueClosures.record_in(AdminRepo, ctx.tenant.id, ctx.story.id, ctx.record.id, :shipped)

      :ok =
        IssueClosures.record_in(
          AdminRepo,
          ctx.tenant.id,
          ctx.story.id,
          ctx.record.id,
          :not_actionable
        )

      assert %IssueClosure{verdict: :shipped} = IssueClosures.get(ctx.tenant.id, ctx.story.id)
    end

    test "a conflict on the RECORD index is absorbed, not raised", ctx do
      other_story = fixture(:story, %{tenant_id: ctx.tenant.id})

      :ok =
        IssueClosures.record_in(AdminRepo, ctx.tenant.id, ctx.story.id, ctx.record.id, :shipped)

      # A DIFFERENT story naming the SAME record. `stories_intake_record_uidx` normally makes
      # this impossible, which is exactly why the record-level closure index is insurance for
      # the day it does not hold — and insurance that RAISES is worse than none: `record_in/5`
      # is deliberately uncaught, so the exception would roll the verdict transition back and
      # leave that story permanently un-advanceable.
      #
      # A `conflict_target` names ONE index, so a conflict on the other one raised. Untargeted
      # `ON CONFLICT DO NOTHING` covers both.
      assert :ok =
               IssueClosures.record_in(
                 AdminRepo,
                 ctx.tenant.id,
                 other_story.id,
                 ctx.record.id,
                 :not_actionable
               )

      # One closure for the record, and it is the FIRST verdict — the reporter is told once.
      assert [%IssueClosure{verdict: :shipped}] = IssueClosures.list(ctx.tenant.id)
      assert IssueClosures.get(ctx.tenant.id, other_story.id) == nil
    end

    test "a record-index conflict is LOGGED, not silently identical to a replay", ctx do
      other_story = fixture(:story, %{tenant_id: ctx.tenant.id})

      :ok =
        IssueClosures.record_in(AdminRepo, ctx.tenant.id, ctx.story.id, ctx.record.id, :shipped)

      # Untargeted ON CONFLICT makes both conflicts return zero rows, so absorbing them
      # identically left the second case with no trace anywhere: no closure exists for THIS
      # story, the transition still commits, and the reporter is never told.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   IssueClosures.record_in(
                     AdminRepo,
                     ctx.tenant.id,
                     other_story.id,
                     ctx.record.id,
                     :not_actionable
                   )
        end)

      assert log =~ "intake closure NOT recorded"
      assert log =~ other_story.id
      assert log =~ "[error]"
    end

    test "an ordinary REPLAY is absorbed silently — it is not the same thing", ctx do
      :ok =
        IssueClosures.record_in(AdminRepo, ctx.tenant.id, ctx.story.id, ctx.record.id, :shipped)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   IssueClosures.record_in(
                     AdminRepo,
                     ctx.tenant.id,
                     ctx.story.id,
                     ctx.record.id,
                     :shipped
                   )
        end)

      refute log =~ "intake closure NOT recorded"
    end

    test "a REVOKED source records nothing at all", ctx do
      # Revoking an intake source is a tenant disconnecting a repository. Refusing HERE is the
      # smaller of the two windows: no row is written, so there is nothing for the drainer to
      # pick up and no write to that repo can ever be attempted. `IssueCloser` covers the
      # other window, a source revoked after the verdict was recorded.
      {1, _} =
        AdminRepo.update_all(
          from(s in Loopctl.Intake.Source, where: s.id == ^ctx.record.source_id),
          set: [revoked_at: DateTime.utc_now()]
        )

      assert :no_link =
               IssueClosures.record_in(
                 AdminRepo,
                 ctx.tenant.id,
                 ctx.story.id,
                 ctx.record.id,
                 :shipped
               )

      assert IssueClosures.get(ctx.tenant.id, ctx.story.id) == nil
    end

    test "a record whose source is gone is :no_link, not a crash", ctx do
      AdminRepo.delete_all(from s in Loopctl.Intake.Source, where: s.id == ^ctx.record.source_id)

      assert :no_link =
               IssueClosures.record_in(
                 AdminRepo,
                 ctx.tenant.id,
                 ctx.story.id,
                 ctx.record.id,
                 :shipped
               )
    end
  end

  describe "the state machine" do
    setup ctx do
      closure =
        fixture(:issue_closure, %{
          tenant_id: ctx.tenant.id,
          story_id: ctx.story.id,
          intake_record: ctx.record
        })

      %{closure: closure}
    end

    test "claim_attempt is MUTUAL EXCLUSION: the second claimer is refused", ctx do
      assert {:ok, %IssueClosure{attempts: 1}} =
               IssueClosures.claim_attempt(ctx.tenant.id, ctx.closure.id)

      # THE ROUND-2 H1 REGRESSION TEST, and this file previously asserted the opposite.
      #
      # A claim leaves the row `:pending`, so a predicate testing only the status matched both
      # callers: two drainers each got `{:ok, claimed}` and each went on to label, COMMENT and
      # close — two resolution comments on one reporter's ticket. The claim also pushes
      # `next_attempt_at` forward and tests it, which is what makes it a compare-and-set.
      assert {:error, :not_pending} = IssueClosures.claim_attempt(ctx.tenant.id, ctx.closure.id)

      assert %IssueClosure{attempts: 1} = IssueClosures.get(ctx.tenant.id, ctx.story.id)
    end

    test "a claim is possible again once the backoff has elapsed", ctx do
      {:ok, _first} = IssueClosures.claim_attempt(ctx.tenant.id, ctx.closure.id)

      # Exclusion, not a one-shot lock: a genuinely retryable row comes back when its wait is
      # over, which is the whole retry mechanism.
      make_due(ctx.closure.id)

      assert {:ok, %IssueClosure{attempts: 2}} =
               IssueClosures.claim_attempt(ctx.tenant.id, ctx.closure.id)
    end

    test "a claim is refused once the row is terminal", ctx do
      {:ok, _} = IssueClosures.mark_closed(ctx.tenant.id, ctx.closure.id)

      assert {:error, :not_pending} = IssueClosures.claim_attempt(ctx.tenant.id, ctx.closure.id)
    end

    test "mark_closed is terminal and cannot be undone by a later marker", ctx do
      {:ok, closed} = IssueClosures.mark_closed(ctx.tenant.id, ctx.closure.id)
      assert closed.status == :closed
      assert %DateTime{} = closed.closed_at

      assert {:error, :not_pending} = IssueClosures.mark_labelled(ctx.tenant.id, ctx.closure.id)
      assert {:error, :not_pending} = IssueClosures.mark_closed(ctx.tenant.id, ctx.closure.id)

      assert {:error, :not_pending} =
               IssueClosures.mark_abandoned(ctx.tenant.id, ctx.closure.id, :closed_by_other)

      assert %IssueClosure{status: :closed} = IssueClosures.get(ctx.tenant.id, ctx.story.id)
    end

    test "mark_abandoned is terminal and records why", ctx do
      {:ok, row} =
        IssueClosures.mark_abandoned(ctx.tenant.id, ctx.closure.id, :closed_by_other, :whatever)

      assert row.status == :abandoned
      assert row.abandoned_reason == "closed_by_other"
      assert {:error, :not_pending} = IssueClosures.mark_closed(ctx.tenant.id, ctx.closure.id)
    end

    test "a transient failure backs off and stays pending until the bound", ctx do
      closure = spend_attempts(ctx.tenant.id, ctx.closure, IssueClosures.max_attempts() - 1)

      {:ok, deferred} =
        IssueClosures.mark_transient_failure(ctx.tenant.id, closure, {:github_api_error, 500})

      assert deferred.status == :pending
      assert %DateTime{} = deferred.next_attempt_at
      assert DateTime.compare(deferred.next_attempt_at, DateTime.utc_now()) == :gt
      assert deferred.last_error =~ "github_api_error"
    end

    test "a transient failure at the bound abandons with retries_exhausted", ctx do
      closure = spend_attempts(ctx.tenant.id, ctx.closure, IssueClosures.max_attempts())

      {:ok, row} =
        IssueClosures.mark_transient_failure(ctx.tenant.id, closure, {:github_api_error, 500})

      assert row.status == :abandoned
      assert row.abandoned_reason == "retries_exhausted"
      assert row.next_attempt_at == nil
    end
  end

  describe "due/1" do
    test "returns pending rows whose backoff has elapsed, and nothing else", ctx do
      pending =
        fixture(:issue_closure, %{
          tenant_id: ctx.tenant.id,
          story_id: ctx.story.id,
          intake_record: ctx.record
        })

      # A DISTINCT record per closure: `intake_issue_closures_record_uidx` allows exactly one
      # closure per intake record, which is the finding-3 invariant.
      backed_off =
        fixture(:issue_closure, %{
          tenant_id: ctx.tenant.id,
          story_id: fixture(:story, %{tenant_id: ctx.tenant.id}).id,
          intake_record: other_record(ctx),
          next_attempt_at: DateTime.add(DateTime.utc_now(), 600, :second)
        })

      closed =
        fixture(:issue_closure, %{
          tenant_id: ctx.tenant.id,
          story_id: fixture(:story, %{tenant_id: ctx.tenant.id}).id,
          intake_record: other_record(ctx),
          status: :closed,
          closed_at: DateTime.utc_now()
        })

      due = IssueClosures.due(50) |> Enum.map(& &1.id)

      assert pending.id in due
      refute backed_off.id in due
      refute closed.id in due
    end
  end

  describe "wait_seconds/2 — the schedule, asserted directly" do
    test "zero attempts made yields the SHORTEST delay, not the longest", _ctx do
      first = IssueClosures.wait_seconds(1, nil)

      # `Enum.at(list, -1)` treats -1 as "from the end", so an unguarded index returned the
      # 48-minute LAST entry as the first backoff. Unreachable through `close/1`, which always
      # claims before it can fail — but this function is public precisely so the schedule can
      # be asserted without driving a closure, and a helper that lies about its own first
      # entry is worse than no helper.
      assert IssueClosures.wait_seconds(0, nil) == first
      assert IssueClosures.wait_seconds(0, nil) < List.last(schedule())
    end

    test "the schedule is monotonic and never returns the tail early", _ctx do
      assert schedule() == Enum.sort(schedule())
      assert Enum.uniq(schedule()) == schedule()
    end

    test "past the end it holds at the longest delay", _ctx do
      longest = List.last(schedule())

      assert IssueClosures.wait_seconds(IssueClosures.max_attempts() + 10, nil) == longest
    end
  end

  describe "requeue_abandoned/1 — the operator's way back" do
    setup ctx do
      closure =
        fixture(:issue_closure, %{
          tenant_id: ctx.tenant.id,
          story_id: ctx.story.id,
          intake_record: ctx.record
        })

      %{closure: closure}
    end

    test "re-drives a permanent forge failure, the deploy-misconfiguration case", ctx do
      # The likeliest mass abandonment: a GITHUB_TOKEN without `issues: write` 403s every
      # closure in the window. Before this existed nothing in lib/ could move a non-pending
      # row, so fixing the secret left the backlog dead with no reporter ever told.
      {:ok, _} =
        IssueClosures.mark_abandoned(
          ctx.tenant.id,
          ctx.closure.id,
          {:permanent_forge_failure, {:github_api_error, 403}},
          {:github_api_error, 403}
        )

      window = [abandoned_after: DateTime.add(DateTime.utc_now(), -60, :second)]

      # DRY RUN first: counts, writes nothing. That is the shape FLY_SECRETS tells an operator
      # to use, because the act is outward and they should see the size before they take it.
      assert {:ok, 1} = IssueClosures.requeue_abandoned(window ++ [dry_run: true])
      assert %IssueClosure{status: :abandoned} = IssueClosures.get(ctx.tenant.id, ctx.story.id)

      assert {:ok, 1} = IssueClosures.requeue_abandoned(window ++ [tenant_id: ctx.tenant.id])

      row = IssueClosures.get(ctx.tenant.id, ctx.story.id)
      assert row.status == :pending
      assert row.abandoned_reason == nil
      assert row.attempts == 0
      assert row.next_attempt_at == nil

      # And it is a candidate again.
      assert row.id in Enum.map(IssueClosures.due(50), & &1.id)
    end

    test "an UNBOUNDED requeue is refused", ctx do
      {:ok, _} =
        IssueClosures.mark_abandoned(ctx.tenant.id, ctx.closure.id, :retries_exhausted, :timeout)

      # A closure abandoned months ago by an unrelated outage still names a live issue. Waking
      # it puts a fresh label, comment and close on a ticket the reporter has moved on from,
      # carrying a verdict about work nobody remembers — so the bare call is a refusal.
      assert {:error, :bound_required} = IssueClosures.requeue_abandoned()

      # A tenant is NOT a bound: one tenant's whole history is exactly the blast radius.
      assert {:error, :bound_required} =
               IssueClosures.requeue_abandoned(tenant_id: ctx.tenant.id)

      assert %IssueClosure{status: :abandoned} = IssueClosures.get(ctx.tenant.id, ctx.story.id)

      # Three things bound it, and each is the operator saying so out loud.
      for opts <- [
            [id: ctx.closure.id],
            [abandoned_after: DateTime.add(DateTime.utc_now(), -60, :second)],
            [unbounded: true]
          ] do
        assert {:ok, 1} = IssueClosures.requeue_abandoned(opts ++ [dry_run: true])
      end
    end

    test "dry_run fails SAFE on a value that is not the atom true", ctx do
      {:ok, _} =
        IssueClosures.mark_abandoned(ctx.tenant.id, ctx.closure.id, :retries_exhausted, :timeout)

      # `== true` meant a copy-pasted `dry_run: "true"`, or a typo, performed the REAL requeue
      # on live reporter tickets — while `unbounded` fails the other way, leaving the call
      # refused. Two guards on one function must not fail in opposite directions.
      for value <- [true, "true", 1, :yes] do
        assert {:ok, 1} = IssueClosures.requeue_abandoned(unbounded: true, dry_run: value)
        assert %IssueClosure{status: :abandoned} = IssueClosures.get(ctx.tenant.id, ctx.story.id)
      end

      # Absent, or explicitly false, still performs the requeue — the flag is opt-in.
      assert {:ok, 1} = IssueClosures.requeue_abandoned(unbounded: true, dry_run: false)
      assert %IssueClosure{status: :pending} = IssueClosures.get(ctx.tenant.id, ctx.story.id)
    end

    test "a row abandoned BEFORE the window is left alone", ctx do
      {:ok, _} =
        IssueClosures.mark_abandoned(ctx.tenant.id, ctx.closure.id, :retries_exhausted, :timeout)

      future = DateTime.add(DateTime.utc_now(), 60, :second)

      assert {:ok, 0} = IssueClosures.requeue_abandoned(abandoned_after: future)
      assert %IssueClosure{status: :abandoned} = IssueClosures.get(ctx.tenant.id, ctx.story.id)
    end

    test "re-drives an exhausted retry budget", ctx do
      {:ok, _} =
        IssueClosures.mark_abandoned(ctx.tenant.id, ctx.closure.id, :retries_exhausted, :timeout)

      assert {:ok, 1} = IssueClosures.requeue_abandoned(id: ctx.closure.id)
      assert %IssueClosure{status: :pending} = IssueClosures.get(ctx.tenant.id, ctx.story.id)
    end

    test "NEVER re-drives an issue a human already closed", ctx do
      {:ok, _} =
        IssueClosures.mark_abandoned(ctx.tenant.id, ctx.closure.id, :closed_by_other, nil)

      # Re-driving this is the duplicate close the whole module exists to prevent, and no
      # amount of fixing a token makes it right.
      assert {:ok, 0} = IssueClosures.requeue_abandoned(unbounded: true)
      assert {:ok, 0} = IssueClosures.requeue_abandoned(id: ctx.closure.id)

      row = IssueClosures.get(ctx.tenant.id, ctx.story.id)
      assert row.status == :abandoned
      assert row.abandoned_reason == "closed_by_other"
    end

    test "leaves a CLOSED row alone — it is done, not stuck", ctx do
      {:ok, _} = IssueClosures.mark_closed(ctx.tenant.id, ctx.closure.id)

      assert {:ok, 0} = IssueClosures.requeue_abandoned(unbounded: true)
      assert %IssueClosure{status: :closed} = IssueClosures.get(ctx.tenant.id, ctx.story.id)
    end

    test "scoped to one tenant leaves another tenant's backlog alone", ctx do
      other = fixture(:tenant)
      other_story = fixture(:story, %{tenant_id: other.id})

      other_closure =
        fixture(:issue_closure, %{
          tenant_id: other.id,
          story_id: other_story.id,
          intake_record: fixture(:intake_record, %{tenant_id: other.id, repo: AdminRepo})
        })

      for {tid, cid} <- [{ctx.tenant.id, ctx.closure.id}, {other.id, other_closure.id}] do
        {:ok, _} = IssueClosures.mark_abandoned(tid, cid, :retries_exhausted, :timeout)
      end

      assert {:ok, 1} =
               IssueClosures.requeue_abandoned(unbounded: true, tenant_id: ctx.tenant.id)

      assert %IssueClosure{status: :pending} = IssueClosures.get(ctx.tenant.id, ctx.story.id)
      assert %IssueClosure{status: :abandoned} = IssueClosures.get(other.id, other_story.id)
    end
  end

  describe "the stored reason is bounded in CODE POINTS" do
    test "an abandon reason full of multi-code-point graphemes still writes", ctx do
      closure =
        fixture(:issue_closure, %{
          tenant_id: ctx.tenant.id,
          story_id: ctx.story.id,
          intake_record: ctx.record
        })

      # A FLAG emoji is one grapheme and two code points, and `inspect/1` leaves it intact —
      # so a grapheme-counting slice at 1,900 yields 3,790 code points against a
      # 2,000-code-point CHECK. The CHECK then raised inside the very write that says "never
      # retry this", leaving the row pending at the head of an oldest-first queue: one issue
      # wedging the drainer for every tenant.
      #
      # The emoji matters. A ZWJ family emoji does NOT reproduce it — `inspect/1` escapes
      # that one into ASCII, so graphemes and code points come out equal and the two bounding
      # strategies agree. `bin/mutate.sh` returned exit 1 on the first version of this test
      # for exactly that reason, which is the tool refusing to certify a check that cannot
      # fail.
      decorated = String.duplicate("🇺🇸", 2_000)

      assert {:ok, row} =
               IssueClosures.mark_abandoned(
                 ctx.tenant.id,
                 closure.id,
                 {:permanent_forge_failure, {:label, decorated}},
                 {:label, decorated}
               )

      assert row.status == :abandoned

      # CODE POINTS, which is what Postgres `char_length` counts and what the CHECK caps.
      assert codepoints(row.last_error) <= 2_000
      assert codepoints(row.abandoned_reason) <= 2_000
    end

    test "a combining-mark reason writes too", ctx do
      closure =
        fixture(:issue_closure, %{
          tenant_id: ctx.tenant.id,
          story_id: ctx.story.id,
          intake_record: ctx.record
        })

      combining = String.duplicate("é", 2_000)

      assert {:ok, row} =
               IssueClosures.mark_transient_failure(
                 ctx.tenant.id,
                 closure,
                 {:unreadable, combining}
               )

      assert codepoints(row.last_error) <= 2_000
    end
  end

  describe "tenant isolation" do
    test "another tenant's closure is unreachable by every read and every write", ctx do
      other = fixture(:tenant)

      closure =
        fixture(:issue_closure, %{
          tenant_id: ctx.tenant.id,
          story_id: ctx.story.id,
          intake_record: ctx.record
        })

      assert IssueClosures.get(other.id, ctx.story.id) == nil
      assert IssueClosures.list(other.id) == []
      assert {:error, :not_pending} = IssueClosures.claim_attempt(other.id, closure.id)
      assert {:error, :not_pending} = IssueClosures.mark_closed(other.id, closure.id)
      assert {:error, :not_pending} = IssueClosures.mark_labelled(other.id, closure.id)

      assert {:error, :not_pending} =
               IssueClosures.mark_abandoned(other.id, closure.id, :closed_by_other)

      # Untouched by every one of those.
      assert %IssueClosure{status: :pending, attempts: 0} =
               IssueClosures.get(ctx.tenant.id, ctx.story.id)
    end

    test "a story cannot link to another tenant's intake record", ctx do
      other = fixture(:tenant)
      other_story = fixture(:story, %{tenant_id: other.id})

      # The database refuses it, not just the context: `stories_intake_record_fkey` is a
      # COMPOSITE key on (tenant_id, intake_record_id), so a story of one tenant naming a
      # record of another matches no row in `intake_records`.
      assert_raise Ecto.ConstraintError, ~r/stories_intake_record_fkey/, fn ->
        other_story
        |> Ecto.Changeset.change(intake_record_id: ctx.record.id)
        |> AdminRepo.update!()
      end
    end
  end

  # The waits an attempt actually takes, in order, read through the public function rather
  # than the private list.
  defp schedule do
    Enum.map(1..(IssueClosures.max_attempts() - 1), &IssueClosures.wait_seconds(&1, nil))
  end

  # What Postgres `char_length` counts, and therefore what the CHECK caps — NOT graphemes,
  # which is the distinction the whole bound turns on.
  defp codepoints(nil), do: 0
  defp codepoints(text), do: length(String.to_charlist(text))

  # Makes a claimed row DUE again. Production waits out the backoff; a test that spent it in
  # real time would take minutes.
  defp make_due(id) do
    {1, _} =
      AdminRepo.update_all(from(c in IssueClosure, where: c.id == ^id),
        set: [next_attempt_at: nil]
      )

    :ok
  end

  defp other_record(ctx) do
    fixture(:intake_record, %{tenant_id: ctx.tenant.id, repo: AdminRepo})
  end

  # Drives `attempts` up through the real claim path rather than writing the column, so the
  # bound is exercised against the counter the production path actually moves. Each claim now
  # schedules the row forward — that is the mutual exclusion — so the wait is cleared between
  # them, exactly as elapsed time would.
  defp spend_attempts(tenant_id, closure, n) do
    Enum.reduce(1..n, closure, fn _i, acc ->
      :ok = make_due(acc.id)
      {:ok, next} = IssueClosures.claim_attempt(tenant_id, acc.id)
      next
    end)
  end
end
