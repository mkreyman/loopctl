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

      backed_off_story = fixture(:story, %{tenant_id: ctx.tenant.id})

      backed_off =
        fixture(:issue_closure, %{
          tenant_id: ctx.tenant.id,
          story_id: backed_off_story.id,
          intake_record: ctx.record,
          next_attempt_at: DateTime.add(DateTime.utc_now(), 600, :second)
        })

      closed_story = fixture(:story, %{tenant_id: ctx.tenant.id})

      closed =
        fixture(:issue_closure, %{
          tenant_id: ctx.tenant.id,
          story_id: closed_story.id,
          intake_record: ctx.record,
          status: :closed,
          closed_at: DateTime.utc_now()
        })

      due = IssueClosures.due(50) |> Enum.map(& &1.id)

      assert pending.id in due
      refute backed_off.id in due
      refute closed.id in due
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

  # Drives `attempts` up through the real claim path rather than writing the column, so the
  # bound is exercised against the counter the production path actually moves.
  defp spend_attempts(tenant_id, closure, n) do
    Enum.reduce(1..n, closure, fn _i, acc ->
      {:ok, next} = IssueClosures.claim_attempt(tenant_id, acc.id)
      next
    end)
  end
end
