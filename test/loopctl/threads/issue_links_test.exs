defmodule Loopctl.Threads.IssueLinksTest do
  @moduledoc """
  US-45.7 (AC-45.7.4): the outbox that links a story's intake issue to its thread page — the
  intent written in the first checkpoint's transaction (`record_in/3`, on the RLS `Repo`), the
  migration's one-time backfill of threads that already had one, and the drain (`attempt/2`, on
  `AdminRepo`).
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Intake.Record
  alias Loopctl.Intake.Source
  alias Loopctl.Repo
  alias Loopctl.Test.MigrationFile
  alias Loopctl.Threads
  alias Loopctl.Threads.IssueLink
  alias Loopctl.Threads.IssueLinks
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  @url "https://loopctl.test/threads/x"

  @epoch 2
  @tree String.duplicate("c", 40)

  # A claimed story on the RLS `Repo`, where `Loopctl.Threads` records its checkpoints.
  defp claimed_story do
    story = fixture(:stage_story, %{claim_epoch: @epoch, agent_status: :implementing})
    agent = fixture(:stage_agent, %{tenant_id: story.tenant_id})
    update_story(story, assigned_agent_id: agent.id)
    %{story: story, agent: agent, tenant_id: story.tenant_id}
  end

  defp update_story(story, fields) do
    {:ok, _} =
      Repo.with_tenant(story.tenant_id, fn ->
        from(s in Story, where: s.id == ^story.id) |> Repo.update_all(set: fields)
      end)
  end

  defp link_intake(ctx, attrs \\ %{}) do
    record =
      fixture(:intake_record, Map.merge(%{tenant_id: ctx.tenant_id, issue_number: 77}, attrs))

    update_story(ctx.story, intake_record_id: record.id)
    record
  end

  defp checkpoint(ctx, n) do
    Threads.record_checkpoint(ctx.tenant_id, ctx.story.id,
      agent_id: ctx.agent.id,
      claim_epoch: @epoch,
      commit_sha: n |> Integer.to_string(16) |> String.pad_leading(40, "0"),
      tree_sha: @tree,
      author_principal: "agent:#{ctx.agent.id}",
      actor_lineage: []
    )
  end

  defp repo_links(ctx) do
    {:ok, rows} =
      Repo.with_tenant(ctx.tenant_id, fn ->
        Repo.all(from l in IssueLink, where: l.story_id == ^ctx.story.id)
      end)

    rows
  end

  describe "record_in/3, in the first checkpoint's transaction" do
    test "an intake story's first checkpoint records ONE link; later ones add none" do
      ctx = claimed_story()
      link_intake(ctx)

      assert {:ok, _, :created} = checkpoint(ctx, 1)
      assert [%IssueLink{status: :pending, issue_number: 77}] = repo_links(ctx)

      assert {:ok, _, :created} = checkpoint(ctx, 2)
      assert [_one] = repo_links(ctx)
    end

    test "an authored story, a revoked source, or a closed issue: no link" do
      authored = claimed_story()
      assert {:ok, _, :created} = checkpoint(authored, 1)
      assert [] == repo_links(authored)

      revoked = claimed_story()
      record = link_intake(revoked)

      {:ok, _} =
        Repo.with_tenant(revoked.tenant_id, fn ->
          from(s in Source, where: s.id == ^record.source_id)
          |> Repo.update_all(set: [revoked_at: DateTime.utc_now()])
        end)

      assert {:ok, _, :created} = checkpoint(revoked, 1)
      assert [] == repo_links(revoked)

      closed = claimed_story()
      record = link_intake(closed)

      {:ok, _} =
        Repo.with_tenant(closed.tenant_id, fn ->
          from(r in Record, where: r.id == ^record.id)
          |> Repo.update_all(set: [issue_state: "closed"])
        end)

      assert {:ok, _, :created} = checkpoint(closed, 1)
      assert [] == repo_links(closed)
    end

    test "tenant isolation: another tenant's story records nothing" do
      ctx = claimed_story()
      link_intake(ctx)
      other = fixture(:stage_tenant, %{})

      {:ok, result} =
        Repo.with_tenant(other.id, fn -> IssueLinks.record_in(Repo, other.id, ctx.story.id) end)

      assert result == :no_link
      assert [] == repo_links(ctx)
    end
  end

  # The one-time backfill in the migration that added the table, run here as the migration runs
  # it. An intake story on `AdminRepo` with a checkpoint and a stage.
  defp backfill_candidate(attrs) do
    tenant = fixture(:tenant)
    story = fixture(:story, %{tenant_id: tenant.id})

    record =
      fixture(:intake_record, %{
        tenant_id: tenant.id,
        repo: AdminRepo,
        repo_full_name: "acme/widgets",
        issue_number: 55
      })

    AdminRepo.update_all(from(s in Story, where: s.id == ^story.id),
      set: [intake_record_id: record.id]
    )

    if state = Map.get(attrs, :issue_state) do
      AdminRepo.update_all(from(r in Record, where: r.id == ^record.id),
        set: [issue_state: state]
      )
    end

    fixture(:thread_checkpoint, %{
      repo: AdminRepo,
      tenant_id: tenant.id,
      story_id: story.id,
      seq: 1,
      kind: Map.get(attrs, :kind, :checkpoint),
      commit_sha: String.duplicate("a", 40)
    })

    fixture(:story_stage, %{
      repo: AdminRepo,
      tenant_id: tenant.id,
      story_id: story.id,
      stage: Map.fetch!(attrs, :stage)
    })

    story
  end

  defp admin_links(story),
    do: AdminRepo.all(from l in IssueLink, where: l.story_id == ^story.id)

  describe "the migration's one-time backfill" do
    test "links in-flight threads only, and never a closed issue or a base_update-only thread" do
      # The migration module is not compiled with the app: load it once, and name it at
      # runtime, since the compiler cannot see a module that `priv/` defines.
      migration = Module.concat(Loopctl.Repo.Migrations, "AddThreadPage")

      MigrationFile.require!(migration, 20_260_927_120_000)

      backfill = migration.backfill_sql()

      in_flight =
        for stage <- StageMachine.in_flight_stages(),
            do: backfill_candidate(%{stage: stage})

      done = backfill_candidate(%{stage: :done})
      merged = backfill_candidate(%{stage: :merged})
      closed = backfill_candidate(%{stage: :implementing, issue_state: "closed"})
      base_only = backfill_candidate(%{stage: :implementing, kind: :base_update})

      AdminRepo.query!(backfill)
      AdminRepo.query!(backfill)

      for story <- in_flight, do: assert([%IssueLink{issue_number: 55}] = admin_links(story))
      for story <- [done, merged, closed, base_only], do: assert([] == admin_links(story))
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
