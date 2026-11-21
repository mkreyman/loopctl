defmodule Loopctl.WorkItems.OpenTest do
  @moduledoc """
  US-52.18: an interactive session's branch becomes a work item it holds. One item per
  (project, branch); the caller's own item and an unheld item come back, another holder's is
  `branch_held`, and the caller's one unbranched item takes the branch.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Holders
  alias Loopctl.Holders.Holder
  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.WorkItems

  setup :verify_on_exit!

  @repo "https://github.com/mkreyman/chg"

  defp holder(tenant_id, agent_id, session_id) do
    attrs = %{"kind" => "interactive", "session_id" => session_id, "host" => "minis"}
    {:ok, %{holder: holder}} = Holders.register(tenant_id, agent_id, attrs)
    holder
  end

  defp opener(holder),
    do: %{api_key_id: Ecto.UUID.generate(), agent_id: holder.agent_id, holder_id: holder.id}

  # A project whose live intake source targets epic E: the enrolment claims the repo.
  defp setup_project(_ctx) do
    agent = fixture(:agent, %{})
    tenant_id = agent.tenant_id
    project = fixture(:project, %{tenant_id: tenant_id, repo_url: nil})
    epic = fixture(:epic, %{tenant_id: tenant_id, project_id: project.id, number: 3})

    fixture(:intake_source, %{
      tenant_id: tenant_id,
      project_id: project.id,
      repo_full_name: "mkreyman/chg",
      target_epic_id: epic.id
    })

    %{
      agent: agent,
      tenant_id: tenant_id,
      project: project,
      epic: epic,
      h: holder(tenant_id, agent.id, "session-a"),
      h2: holder(tenant_id, agent.id, "session-b")
    }
  end

  defp open(ctx, holder, attrs) do
    WorkItems.open_interactive(
      ctx.tenant_id,
      opener(holder),
      Map.merge(%{"repo_url" => @repo}, attrs)
    )
  end

  defp events(tenant_id, story_id, event) do
    AdminRepo.all(
      from e in StageEvent,
        where: e.tenant_id == ^tenant_id and e.story_id == ^story_id and e.event == ^event,
        order_by: [asc: e.inserted_at]
    )
  end

  defp story_count(tenant_id),
    do: AdminRepo.aggregate(from(s in Story, where: s.tenant_id == ^tenant_id), :count)

  describe "open_interactive/4 creates the item" do
    setup :setup_project

    # TC-52.18.1
    test "a held, implementing item with its stage row and events", ctx do
      assert {:ok, :created, story} = open(ctx, ctx.h, %{"branch" => "fix/gate-lock"})

      assert story.epic_id == ctx.epic.id
      assert story.project_id == ctx.project.id
      assert story.title == "fix/gate-lock"
      assert story.agent_status == :implementing
      assert story.assigned_holder_id == ctx.h.id
      assert story.assigned_agent_id == ctx.agent.id
      assert %DateTime{} = story.claimed_until
      assert %DateTime{} = story.lifecycle_entered_at

      row = Stages.get(ctx.tenant_id, story.id)
      assert row.stage == :implementing
      assert row.branch == "fix/gate-lock"
      assert row.claim_epoch == story.claim_epoch

      reason = "interactive work started on fix/gate-lock"

      for event <- ["opened", "effect_recorded", "claimed"] do
        assert [e] = events(ctx.tenant_id, story.id, event)
        assert e.reason == reason
        assert e.actor_holder_id == ctx.h.id
      end
    end

    test "the title is the caller's when given", ctx do
      assert {:ok, :created, story} =
               open(ctx, ctx.h, %{"branch" => "fix/x", "title" => "  Tighten the gate  "})

      assert story.title == "Tighten the gate"
    end

    test "a key with no holder is holder_credential_required", ctx do
      opener = %{api_key_id: Ecto.UUID.generate(), agent_id: ctx.agent.id, holder_id: nil}

      assert {:error, :holder_credential_required} =
               WorkItems.open_interactive(ctx.tenant_id, opener, %{
                 "repo_url" => @repo,
                 "branch" => "fix/x"
               })
    end

    test "an ended holder is holder_ended", ctx do
      {1, _} =
        AdminRepo.update_all(
          from(h in Holder, where: h.id == ^ctx.h.id),
          set: [ended_at: DateTime.utc_now(), ended_reason: :ended]
        )

      assert {:error, :holder_ended} = open(ctx, ctx.h, %{"branch" => "fix/x"})
    end

    test "US-52.19: a lapsed holder opens nothing; a live one's item takes its lease", ctx do
      {:ok, :created, story} = open(ctx, ctx.h, %{"branch" => "fix/live"})
      assert story.claimed_until == AdminRepo.get!(Holder, ctx.h.id).lease_until
      assert is_nil(story.claim_lease_cap)

      {1, _} =
        AdminRepo.update_all(
          from(h in Holder, where: h.id == ^ctx.h2.id),
          set: [lease_until: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      assert {:error, :holder_lease_expired} = open(ctx, ctx.h2, %{"branch" => "fix/y"})
    end

    test "a branch that is not a branch name is refused", ctx do
      for branch <- ["", "HEAD", "two words", "tab\there", String.duplicate("b", 256), 7] do
        assert {:error, :invalid_branch} = open(ctx, ctx.h, %{"branch" => branch})
      end

      assert story_count(ctx.tenant_id) == 0
    end
  end

  describe "epic resolution (AC-52.18.2)" do
    setup do
      agent = fixture(:agent, %{})
      tenant_id = agent.tenant_id

      project =
        fixture(:project, %{tenant_id: tenant_id, repo_url: "https://github.com/mkreyman/chg"})

      e2 = fixture(:epic, %{tenant_id: tenant_id, project_id: project.id, number: 7})
      fixture(:story, %{tenant_id: tenant_id, epic_id: e2.id, number: "7.4"})
      x = fixture(:epic, %{tenant_id: tenant_id})

      %{
        tenant_id: tenant_id,
        project: project,
        e2: e2,
        x: x,
        h: holder(tenant_id, agent.id, "session-a")
      }
    end

    # TC-52.18.2
    test "no intake source and no epic_id is no_target_epic", ctx do
      assert {:error, :no_target_epic} = open(ctx, ctx.h, %{"branch" => "fix/a"})
    end

    test "epic_id places the item, numbered after the epic's last story", ctx do
      assert {:ok, :created, story} =
               open(ctx, ctx.h, %{"branch" => "fix/a", "epic_id" => ctx.e2.id})

      assert story.epic_id == ctx.e2.id
      assert story.number == "7.5"
    end

    test "an epic of another project, or no epic at all, is epic_not_found", ctx do
      assert {:error, :epic_not_found} =
               open(ctx, ctx.h, %{"branch" => "fix/a", "epic_id" => ctx.x.id})

      assert {:error, :epic_not_found} =
               open(ctx, ctx.h, %{"branch" => "fix/a", "epic_id" => "not-a-uuid"})
    end
  end

  describe "re-open (AC-52.18.4, AC-52.18.5, AC-52.18.6)" do
    setup :setup_project

    # TC-52.18.3, first half
    test "the caller's own item comes back and no second item is made", ctx do
      {:ok, :created, story} = open(ctx, ctx.h, %{"branch" => "fix/b1"})
      assert {:ok, :existing, again} = open(ctx, ctx.h, %{"branch" => "fix/b1"})
      assert again.id == story.id
      assert story_count(ctx.tenant_id) == 1
      assert [_] = events(ctx.tenant_id, story.id, "claimed")
    end

    test "another holder's open item is branch_held", ctx do
      {:ok, :created, story} = open(ctx, ctx.h, %{"branch" => "fix/b1"})

      assert {:error, {:branch_held, story_id, holder_id}} =
               open(ctx, ctx.h2, %{"branch" => "fix/b1"})

      assert story_id == story.id
      assert holder_id == ctx.h.id
    end

    test "the same branch in another project is another item", ctx do
      other =
        fixture(:project, %{
          tenant_id: ctx.tenant_id,
          repo_url: "https://github.com/mkreyman/other"
        })

      epic = fixture(:epic, %{tenant_id: ctx.tenant_id, project_id: other.id, number: 4})
      {:ok, :created, first} = open(ctx, ctx.h, %{"branch" => "fix/b1"})

      assert {:ok, :created, second} =
               WorkItems.open_interactive(ctx.tenant_id, opener(ctx.h2), %{
                 "repo_url" => "https://github.com/mkreyman/other",
                 "branch" => "fix/b1",
                 "epic_id" => epic.id
               })

      refute first.id == second.id
    end

    # TC-52.18.3, second half
    test "an unheld item is taken back with a claimed event", ctx do
      {:ok, :created, story} = open(ctx, ctx.h, %{"branch" => "fix/b1"})

      {:ok, released} =
        Progress.unclaim_story(ctx.tenant_id, story.id,
          agent_id: ctx.agent.id,
          holder_id: ctx.h.id
        )

      assert released.assigned_holder_id == nil

      assert {:ok, :claimed, taken} = open(ctx, ctx.h2, %{"branch" => "fix/b1"})
      assert taken.id == story.id
      assert taken.assigned_holder_id == ctx.h2.id
      assert taken.agent_status == :implementing
      assert taken.claim_epoch > released.claim_epoch

      row = Stages.get(ctx.tenant_id, story.id)
      assert row.stage == :implementing
      assert row.claim_epoch == taken.claim_epoch
      assert row.branch == "fix/b1"

      assert [_, second] = events(ctx.tenant_id, story.id, "claimed")
      assert second.actor_holder_id == ctx.h2.id
      assert story_count(ctx.tenant_id) == 1
    end

    test "an unheld escalated item is story_held", ctx do
      {:ok, :created, story} = open(ctx, ctx.h, %{"branch" => "fix/b1"})

      {1, _} =
        AdminRepo.update_all(
          from(s in Story, where: s.id == ^story.id),
          set: [assigned_holder_id: nil, assigned_agent_id: nil, agent_status: :pending]
        )

      {1, _} =
        AdminRepo.update_all(
          from(st in StoryStage, where: st.story_id == ^story.id),
          set: [stage: :escalated, escalation_reason: "a human looks at it"]
        )

      assert {:error, :story_held} = open(ctx, ctx.h2, %{"branch" => "fix/b1"})
    end

    test "the caller's one unbranched item takes the branch", ctx do
      {:ok, :created, story} = open(ctx, ctx.h, %{"branch" => "fix/b0"})

      {1, _} =
        AdminRepo.update_all(
          from(st in StoryStage, where: st.story_id == ^story.id),
          set: [branch: nil]
        )

      assert {:ok, :branch_recorded, same} = open(ctx, ctx.h, %{"branch" => "fix/b1"})
      assert same.id == story.id
      assert Stages.get(ctx.tenant_id, story.id).branch == "fix/b1"
      assert story_count(ctx.tenant_id) == 1

      assert [_, recorded] = events(ctx.tenant_id, story.id, "effect_recorded")
      assert recorded.data == %{"effect" => "branch", "value" => "fix/b1"}
    end

    test "a finished item's branch opens a new item", ctx do
      {:ok, :created, story} = open(ctx, ctx.h, %{"branch" => "fix/b1"})

      {1, _} =
        AdminRepo.update_all(
          from(st in StoryStage, where: st.story_id == ^story.id),
          set: [stage: :done]
        )

      assert {:ok, :created, fresh} = open(ctx, ctx.h2, %{"branch" => "fix/b1"})
      refute fresh.id == story.id
    end

    test "with two unbranched items a new item is made", ctx do
      {:ok, :created, a} = open(ctx, ctx.h, %{"branch" => "fix/a"})
      {:ok, :created, b} = open(ctx, ctx.h, %{"branch" => "fix/b"})

      {2, _} =
        AdminRepo.update_all(
          from(st in StoryStage, where: st.story_id in ^[a.id, b.id]),
          set: [branch: nil]
        )

      assert {:ok, :created, _c} = open(ctx, ctx.h, %{"branch" => "fix/c"})
      assert story_count(ctx.tenant_id) == 3
    end
  end

  describe "tenant isolation (AC-52.18.7)" do
    setup :setup_project

    test "another tenant's repo is project_not_found and nothing is written", ctx do
      other = fixture(:agent, %{})
      h = holder(other.tenant_id, other.id, "session-x")

      assert {:error, :project_not_found} =
               WorkItems.open_interactive(other.tenant_id, opener(h), %{
                 "repo_url" => @repo,
                 "branch" => "fix/x"
               })

      assert story_count(other.tenant_id) == 0
      assert story_count(ctx.tenant_id) == 0
    end

    test "another tenant's holder is not this tenant's", ctx do
      other = fixture(:agent, %{})
      h = holder(other.tenant_id, other.id, "session-x")

      assert {:error, :holder_credential_required} = open(ctx, h, %{"branch" => "fix/x"})
    end
  end
end
