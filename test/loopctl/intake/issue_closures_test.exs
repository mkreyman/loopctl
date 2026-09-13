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

    test "claim_attempt bumps attempts and is refused once the row is terminal", ctx do
      assert {:ok, %IssueClosure{attempts: 1}} =
               IssueClosures.claim_attempt(ctx.tenant.id, ctx.closure.id)

      assert {:ok, %IssueClosure{attempts: 2}} =
               IssueClosures.claim_attempt(ctx.tenant.id, ctx.closure.id)

      {:ok, _closed} = IssueClosures.mark_closed(ctx.tenant.id, ctx.closure.id)

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

      assert {:ok, 1} = IssueClosures.requeue_abandoned(tenant_id: ctx.tenant.id)

      row = IssueClosures.get(ctx.tenant.id, ctx.story.id)
      assert row.status == :pending
      assert row.abandoned_reason == nil
      assert row.attempts == 0
      assert row.next_attempt_at == nil

      # And it is a candidate again.
      assert row.id in Enum.map(IssueClosures.due(50), & &1.id)
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
      assert {:ok, 0} = IssueClosures.requeue_abandoned()
      assert {:ok, 0} = IssueClosures.requeue_abandoned(tenant_id: ctx.tenant.id)
      assert {:ok, 0} = IssueClosures.requeue_abandoned(id: ctx.closure.id)

      row = IssueClosures.get(ctx.tenant.id, ctx.story.id)
      assert row.status == :abandoned
      assert row.abandoned_reason == "closed_by_other"
    end

    test "leaves a CLOSED row alone — it is done, not stuck", ctx do
      {:ok, _} = IssueClosures.mark_closed(ctx.tenant.id, ctx.closure.id)

      assert {:ok, 0} = IssueClosures.requeue_abandoned()
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

      assert {:ok, 1} = IssueClosures.requeue_abandoned(tenant_id: ctx.tenant.id)

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

  # What Postgres `char_length` counts, and therefore what the CHECK caps — NOT graphemes,
  # which is the distinction the whole bound turns on.
  defp codepoints(nil), do: 0
  defp codepoints(text), do: length(String.to_charlist(text))

  defp other_record(ctx) do
    fixture(:intake_record, %{tenant_id: ctx.tenant.id, repo: AdminRepo})
  end

  # Drives `attempts` up through the real claim path rather than writing the column, so the
  # bound is exercised against the counter the production path actually moves.
  defp spend_attempts(tenant_id, closure, n) do
    Enum.reduce(1..n, closure, fn _i, acc ->
      {:ok, next} = IssueClosures.claim_attempt(tenant_id, acc.id)
      next
    end)
  end
end
