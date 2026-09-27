defmodule Loopctl.Threads.IssueLinksTest do
  @moduledoc """
  US-45.7 (AC-45.7.4): the outbox that links a story's intake issue to its thread page — the
  intent derived from durable state (`record_due/1`) and the drain (`attempt/2`), both on
  `AdminRepo`. The worker that runs them in order is `Loopctl.Workers.ThreadIssueLinkWorkerTest`.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Intake.Source
  alias Loopctl.Threads.IssueLink
  alias Loopctl.Threads.IssueLinks
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  @url "https://loopctl.test/threads/x"

  # An intake story on `AdminRepo`, where the sweep reads: its record, its source, and — when
  # `checkpoint?` — a checkpoint of kind `kind`.
  defp intake_story(attrs \\ %{}) do
    tenant = Map.get_lazy(attrs, :tenant, fn -> fixture(:tenant) end)
    story = fixture(:story, %{tenant_id: tenant.id})

    record =
      fixture(:intake_record, %{
        tenant_id: tenant.id,
        repo: AdminRepo,
        repo_full_name: "acme/widgets",
        issue_number: Map.get(attrs, :issue_number, 77)
      })

    AdminRepo.update_all(from(s in Story, where: s.id == ^story.id),
      set: [intake_record_id: record.id]
    )

    if Map.get(attrs, :checkpoint?, true) do
      fixture(:thread_checkpoint, %{
        repo: AdminRepo,
        tenant_id: tenant.id,
        story_id: story.id,
        seq: 1,
        kind: Map.get(attrs, :kind, :checkpoint),
        commit_sha: String.duplicate("a", 40)
      })
    end

    %{tenant: tenant, story: story, record: record}
  end

  defp links(story_id),
    do: AdminRepo.all(from l in IssueLink, where: l.story_id == ^story_id)

  describe "record_due/1, the intent" do
    test "an intake story whose thread has a checkpoint gets ONE link; a second sweep adds none" do
      %{story: story} = intake_story()

      assert IssueLinks.record_due(50) >= 1

      assert [%IssueLink{status: :pending, issue_number: 77, repo_full_name: "acme/widgets"}] =
               links(story.id)

      IssueLinks.record_due(50)
      assert [_one] = links(story.id)
    end

    test "threads that predate the worker are linked the same way (the backfill)" do
      # Nothing but durable state: a checkpoint row, no link, nothing written beside it.
      %{story: story} = intake_story()
      assert [] == links(story.id)
      IssueLinks.record_due(50)
      assert [_one] = links(story.id)
    end

    test "no checkpoint, only a base_update, an authored story, or a revoked source: no link" do
      %{story: none} = intake_story(%{checkpoint?: false})
      %{story: base_only} = intake_story(%{kind: :base_update})
      %{story: revoked, record: record} = intake_story()

      AdminRepo.update_all(from(s in Source, where: s.id == ^record.source_id),
        set: [revoked_at: DateTime.utc_now()]
      )

      authored_tenant = fixture(:tenant)
      authored = fixture(:story, %{tenant_id: authored_tenant.id})

      fixture(:thread_checkpoint, %{
        repo: AdminRepo,
        tenant_id: authored_tenant.id,
        story_id: authored.id,
        seq: 1,
        commit_sha: String.duplicate("b", 40)
      })

      IssueLinks.record_due(50)

      for story <- [none, base_only, revoked, authored], do: assert([] == links(story.id))
    end

    test "tenant isolation: a link is written for the story's own tenant only" do
      %{story: story, tenant: tenant} = intake_story()
      IssueLinks.record_due(50)

      assert [%IssueLink{tenant_id: tid}] = links(story.id)
      assert tid == tenant.id
      assert IssueLinks.get(fixture(:tenant).id, story.id) == nil
    end
  end

  describe "attempt/2, the drain" do
    setup do
      tenant = fixture(:tenant)
      story = fixture(:story, %{tenant_id: tenant.id})

      fixture(:intake_record, %{
        tenant_id: tenant.id,
        repo: Loopctl.AdminRepo,
        repo_full_name: "acme/widgets"
      })

      link =
        fixture(:thread_issue_link, %{
          tenant_id: tenant.id,
          story_id: story.id,
          repo_full_name: "acme/widgets",
          issue_number: 9
        })

      %{tenant: tenant, story: story, link: link}
    end

    test "posts one comment carrying the URL, then is terminal", ctx do
      expect(Loopctl.MockPullRequestSource, :comment_issue, fn "acme/widgets", 9, body ->
        assert body =~ @url
        :ok
      end)

      assert {:commented, nil} = IssueLinks.attempt(ctx.link, @url)

      assert %IssueLink{status: :commented, commented_at: %DateTime{}} =
               IssueLinks.get(ctx.tenant.id, ctx.story.id)

      # A second drainer holding the same stale candidate posts nothing.
      assert {:skipped, nil} = IssueLinks.attempt(ctx.link, @url)
      assert [] == IssueLinks.due(50) |> Enum.filter(&(&1.id == ctx.link.id))
    end

    test "a transient failure backs off and stays pending; a permanent one abandons", ctx do
      expect(Loopctl.MockPullRequestSource, :comment_issue, fn _, _, _ ->
        {:error, {:github_rate_limited, 403, 900}}
      end)

      assert {:deferred, 900} = IssueLinks.attempt(ctx.link, @url)
      link = IssueLinks.get(ctx.tenant.id, ctx.story.id)
      assert link.status == :pending and link.attempts == 1
      assert DateTime.diff(link.next_attempt_at, DateTime.utc_now()) > 800
      refute Enum.any?(IssueLinks.due(50), &(&1.id == link.id))

      other_story = fixture(:story, %{tenant_id: ctx.tenant.id})

      permanent =
        fixture(:thread_issue_link, %{
          tenant_id: ctx.tenant.id,
          story_id: other_story.id,
          repo_full_name: "acme/widgets"
        })

      expect(Loopctl.MockPullRequestSource, :comment_issue, fn _, _, _ ->
        {:error, {:github_api_error, 404}}
      end)

      assert {:abandoned, nil} = IssueLinks.attempt(permanent, @url)
      assert %IssueLink{status: :abandoned} = IssueLinks.get(ctx.tenant.id, other_story.id)
    end

    test "a link whose source was revoked since is abandoned without a forge call", ctx do
      expect(Loopctl.MockPullRequestSource, :comment_issue, 0, fn _, _, _ -> :ok end)

      Loopctl.AdminRepo.update_all(
        from(s in Source, where: s.tenant_id == ^ctx.tenant.id),
        set: [revoked_at: DateTime.utc_now()]
      )

      assert {:abandoned, nil} = IssueLinks.attempt(ctx.link, @url)
    end

    test "the transient retries are bounded", ctx do
      stub(Loopctl.MockPullRequestSource, :comment_issue, fn _, _, _ ->
        {:error, {:github_unreachable, :timeout}}
      end)

      Loopctl.AdminRepo.update_all(from(l in IssueLink, where: l.id == ^ctx.link.id),
        set: [attempts: IssueLinks.max_attempts() - 1]
      )

      link = IssueLinks.get(ctx.tenant.id, ctx.story.id)
      assert {:abandoned, nil} = IssueLinks.attempt(link, @url)
    end

    test "tenant isolation: get/2 does not see another tenant's link", ctx do
      other = fixture(:tenant)
      assert IssueLinks.get(other.id, ctx.story.id) == nil
      assert %IssueLink{} = IssueLinks.get(ctx.tenant.id, ctx.story.id)
    end
  end
end
