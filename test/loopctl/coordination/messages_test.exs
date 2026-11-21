defmodule Loopctl.Coordination.MessagesTest do
  @moduledoc """
  US-52.22: a channel post is a message with exactly one attachment, numbered within it and
  kept as long as the attachment needs it. The concurrent-insert ordering (TC-52.22.2) is in
  `messages_race_test.exs`, which needs committed transactions.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Coordination
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.Coordination.Messages
  alias Loopctl.Holders.Holder
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.ChannelPostSweeper

  @now ~U[2026-11-21 12:00:00.000000Z]

  defp world(tenant_attrs \\ %{}) do
    tenant = fixture(:tenant, tenant_attrs)
    project = fixture(:project, %{tenant_id: tenant.id})
    agent = fixture(:agent, %{tenant_id: tenant.id})
    story = fixture(:story, %{tenant_id: tenant.id, project_id: project.id})
    holder = fixture(:holder, %{tenant_id: tenant.id, agent_id: agent.id})
    %{tenant: tenant, project: project, agent: agent, story: story, holder: holder}
  end

  # A changeset for one message: `attachment` sets the programmatic attachment columns,
  # `attrs` the cast ones.
  defp message(ctx, attachment, attrs \\ %{}) do
    %ChannelPost{tenant_id: ctx.tenant.id, agent_id: ctx.agent.id}
    |> struct(attachment)
    |> ChannelPost.create_changeset(Map.put_new(attrs, "body", "hello"))
  end

  defp insert!(ctx, attachment, attrs \\ %{}, opts \\ []) do
    {:ok, post} = Messages.insert(message(ctx, attachment, attrs), opts)
    post
  end

  defp raw_insert!(ctx, attachment) do
    AdminRepo.insert!(
      struct(
        %ChannelPost{
          tenant_id: ctx.tenant.id,
          agent_id: ctx.agent.id,
          body: "raw",
          attachment_seq: System.unique_integer([:positive])
        },
        attachment
      )
    )
  end

  # A failing statement aborts the transaction it runs in; the inner transaction is a
  # savepoint, so the test's own transaction stays usable.
  defp refused_by_check(fun) do
    assert_raise Ecto.ConstraintError, ~r/channel_posts_one_attachment/, fn ->
      AdminRepo.transaction(fun)
    end
  end

  describe "the one-attachment check (TC-52.22.1)" do
    test "admits a thread, a DM and a channel, and refuses every other shape" do
      ctx = world()

      assert %ChannelPost{} = raw_insert!(ctx, story_id: ctx.story.id, project_id: ctx.project.id)
      assert %ChannelPost{} = raw_insert!(ctx, to_holder_id: ctx.holder.id)
      assert %ChannelPost{} = raw_insert!(ctx, project_id: ctx.project.id)

      refused_by_check(fn ->
        raw_insert!(ctx, story_id: ctx.story.id, to_holder_id: ctx.holder.id)
      end)

      refused_by_check(fn -> raw_insert!(ctx, []) end)
      refused_by_check(fn -> raw_insert!(ctx, story_id: ctx.story.id) end)
    end

    test "a changeset naming two attachments is a changeset error, not a raise" do
      ctx = world()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Messages.insert(
                 message(ctx, project_id: ctx.project.id, to_holder_id: ctx.holder.id)
               )

      assert {"a message is attached" <> _, _} = changeset.errors[:story_id]
    end

    test "the attachment columns are never cast" do
      ctx = world()

      changeset =
        message(ctx, [project_id: ctx.project.id], %{
          "story_id" => ctx.story.id,
          "to_holder_id" => ctx.holder.id,
          "author_holder_id" => ctx.holder.id,
          "attachment_seq" => 99,
          "expires_at" => DateTime.utc_now()
        })

      for field <- [:story_id, :to_holder_id, :author_holder_id, :attachment_seq, :expires_at] do
        refute Map.has_key?(changeset.changes, field), "#{field} was cast"
      end
    end

    test "a thread takes its story's project, whatever the struct said" do
      ctx = world()
      other = fixture(:project, %{tenant_id: ctx.tenant.id})

      post = insert!(ctx, story_id: ctx.story.id, project_id: other.id)

      assert post.project_id == ctx.story.project_id
      assert post.story_id == ctx.story.id
    end

    test "a thread on another tenant's story is :not_found and nothing is written" do
      ctx = world()
      foreign = world()

      assert {:error, :not_found} = Messages.insert(message(ctx, story_id: foreign.story.id))

      assert AdminRepo.aggregate(
               from(p in ChannelPost, where: p.story_id == ^foreign.story.id),
               :count
             ) == 0
    end

    test "a thread dies with its story; a DM with its holder; an author holder is nulled" do
      ctx = world()
      author = fixture(:holder, %{tenant_id: ctx.tenant.id, agent_id: ctx.agent.id})

      thread = insert!(ctx, story_id: ctx.story.id)
      dm = insert!(ctx, to_holder_id: ctx.holder.id)
      channel = insert!(ctx, project_id: ctx.project.id, author_holder_id: author.id)

      holder_ids = [ctx.holder.id, author.id]
      AdminRepo.delete_all(from(s in Story, where: s.id == ^ctx.story.id))
      # A registered holder's credential references it; it goes first.
      AdminRepo.delete_all(from(k in ApiKey, where: k.holder_id in ^holder_ids))
      AdminRepo.delete_all(from(h in Holder, where: h.id in ^holder_ids))

      refute AdminRepo.get(ChannelPost, thread.id)
      refute AdminRepo.get(ChannelPost, dm.id)
      assert %ChannelPost{author_holder_id: nil} = AdminRepo.get(ChannelPost, channel.id)
    end
  end

  describe "attachment_seq (AC-52.22.2)" do
    test "each attachment numbers its own messages from 1" do
      ctx = world()

      assert [1, 2, 3] =
               for(_ <- 1..3, do: insert!(ctx, project_id: ctx.project.id).attachment_seq)

      # The thread shares the story's project_id but is its own attachment.
      assert [1, 2] = for(_ <- 1..2, do: insert!(ctx, story_id: ctx.story.id).attachment_seq)
      assert [1] = [insert!(ctx, to_holder_id: ctx.holder.id).attachment_seq]
    end

    test "a rolled-back insert consumes nothing" do
      ctx = world()
      insert!(ctx, project_id: ctx.project.id)

      {:error, :rolled_back} =
        AdminRepo.transaction(fn ->
          insert!(ctx, project_id: ctx.project.id)
          AdminRepo.rollback(:rolled_back)
        end)

      assert insert!(ctx, project_id: ctx.project.id).attachment_seq == 2
    end

    test "a handoff upsert onto an existing slot keeps the row's attachment_seq" do
      ctx = world()
      member_story(ctx)
      attrs = %{project_id: ctx.project.id, key: "handoff:repo#3", session_id: "s1", audit: []}

      {:ok, first, :created} =
        Coordination.post(ctx.tenant.id, ctx.agent.id, :agent, Map.put(attrs, :body, "one"))

      insert!(ctx, project_id: ctx.project.id)

      {:ok, again, :updated} =
        Coordination.post(ctx.tenant.id, ctx.agent.id, :agent, Map.put(attrs, :body, "two"))

      assert again.id == first.id
      assert again.attachment_seq == first.attachment_seq
      assert insert!(ctx, project_id: ctx.project.id).attachment_seq == 3
    end

    test "two tenants never share a counter" do
      a = world()
      b = world()

      assert insert!(a, project_id: a.project.id).attachment_seq == 1
      assert insert!(b, project_id: b.project.id).attachment_seq == 1
      assert insert!(a, project_id: a.project.id).attachment_seq == 2
    end
  end

  describe "retention by attachment (TC-52.22.3)" do
    test "thread and DM never expire; a channel lives the tenant's window; a handoff 30 days" do
      ctx = world()
      short = world(%{settings: %{"channel_message_retention_days" => 3}})

      thread = insert!(ctx, [story_id: ctx.story.id], %{}, now: @now)
      dm = insert!(ctx, [to_holder_id: ctx.holder.id], %{}, now: @now)
      channel = insert!(ctx, [project_id: ctx.project.id], %{}, now: @now)

      handoff =
        insert!(
          ctx,
          [project_id: ctx.project.id],
          %{"key" => "handoff:repo#1", "session_id" => "s1"},
          now: @now
        )

      other = insert!(short, [project_id: short.project.id], %{}, now: @now)

      assert thread.expires_at == nil
      assert dm.expires_at == nil
      assert channel.expires_at == DateTime.add(@now, 7 * 86_400, :second)
      assert handoff.expires_at == DateTime.add(@now, 30 * 86_400, :second)
      assert other.expires_at == DateTime.add(@now, 3 * 86_400, :second)

      ChannelPostSweeper.sweep(1_000, DateTime.add(@now, 31 * 86_400, :second))

      ids = [thread.id, dm.id, channel.id, handoff.id, other.id]

      remaining =
        AdminRepo.all(from(p in ChannelPost, where: p.id in ^ids, select: p.id))

      assert Enum.sort(remaining) == Enum.sort([thread.id, dm.id])
    end

    test "an invalid tenant setting falls back to the default" do
      for bad <- [0, -2, "5", nil] do
        ctx = world(%{settings: %{"channel_message_retention_days" => bad}})
        post = insert!(ctx, [project_id: ctx.project.id], %{}, now: @now)
        assert post.expires_at == DateTime.add(@now, 7 * 86_400, :second)
      end
    end

    test "quarantining a thread message gives it no expiry; releasing restores none" do
      ctx = world()
      thread = insert!(ctx, story_id: ctx.story.id)

      quarantined =
        thread
        |> ChannelPost.quarantine_changeset([:body], DateTime.utc_now())
        |> AdminRepo.update!()

      assert quarantined.expires_at == nil
      assert quarantined.quarantined_at

      user = fixture(:agent, %{tenant_id: ctx.tenant.id})

      assert {:ok, released} =
               Coordination.release_post(ctx.tenant.id, user.id, :user, thread.id, [])

      assert released.expires_at == nil
      assert released.quarantined_at == nil
    end

    test "releasing a quarantined channel post rolls it back to the 7-day window" do
      ctx = world()
      post = insert!(ctx, project_id: ctx.project.id)

      post
      |> ChannelPost.quarantine_changeset([:body], DateTime.utc_now())
      |> AdminRepo.update!()

      user = fixture(:agent, %{tenant_id: ctx.tenant.id})

      assert {:ok, released} =
               Coordination.release_post(ctx.tenant.id, user.id, :user, post.id, [])

      assert released.expires_at == DateTime.add(post.inserted_at, 7 * 86_400, :second)
    end
  end

  describe "retired keyed slots (AC-52.22.5)" do
    test "a key that does not start handoff: is refused; nothing is written" do
      ctx = world()

      for key <- ["session_goal", "claim:lib/a.ex", " handoff:x", "Handoff:x"] do
        assert {:error, :keyed_slot_retired} =
                 Messages.insert(
                   message(ctx, [project_id: ctx.project.id], %{
                     "key" => key,
                     "session_id" => "s1"
                   })
                 )
      end

      assert AdminRepo.aggregate(
               from(p in ChannelPost, where: p.tenant_id == ^ctx.tenant.id),
               :count
             ) == 0
    end

    test "a thread or DM message carries no key, not even a handoff: one" do
      ctx = world()
      attrs = %{"key" => "handoff:repo#2", "session_id" => "s1"}

      assert {:error, :keyed_slot_retired} =
               Messages.insert(message(ctx, [story_id: ctx.story.id], attrs))

      assert {:error, :keyed_slot_retired} =
               Messages.insert(message(ctx, [to_holder_id: ctx.holder.id], attrs))
    end

    test "Coordination.create_post/4 refuses it too" do
      ctx = world()

      assert {:error, :keyed_slot_retired} =
               Coordination.create_post(ctx.tenant.id, ctx.project.id, ctx.agent.id, %{
                 "body" => "x",
                 "key" => "session_goal",
                 "session_id" => "s1"
               })
    end
  end

  describe "channel reads see channel rows only (TC-52.22.7)" do
    test "list, by-id, handoffs, graduate and delete never return a thread or DM" do
      a = world()
      b = world()

      channel = insert!(a, project_id: a.project.id)
      thread = insert!(a, story_id: a.story.id)
      dm = insert!(a, to_holder_id: a.holder.id)

      insert!(a, [project_id: a.project.id], %{"key" => "handoff:repo#7", "session_id" => "s1"})

      {page, false, nil} = Coordination.recent_page(a.tenant.id, a.project.id, [])
      assert channel.id in Enum.map(page, & &1.id)
      refute thread.id in Enum.map(page, & &1.id)
      refute dm.id in Enum.map(page, & &1.id)

      assert {:error, :not_found} = Coordination.get_post(a.tenant.id, dm.id)
      assert {:error, :not_found} = Coordination.get_post(a.tenant.id, thread.id)
      assert {:ok, _} = Coordination.get_post(a.tenant.id, channel.id)

      assert {:error, :not_found} =
               Coordination.graduate_post(a.tenant.id, a.agent.id, :user, thread.id, %{
                 title: "t"
               })

      assert {:error, :not_found} =
               Coordination.delete_post(a.tenant.id, a.agent.id, :user, dm.id, [])

      assert AdminRepo.get(ChannelPost, dm.id)

      assert [%{key: "handoff:repo#7"}] =
               Coordination.directed_handoffs(a.tenant.id, a.project.id)

      # Tenant B reading tenant A's project sees nothing, and cannot resolve A's posts.
      assert {[], false, nil} = Coordination.recent_page(b.tenant.id, a.project.id, [])
      assert {:error, :not_found} = Coordination.get_post(b.tenant.id, channel.id)
    end

    test "a thread message is never a supersede target on the channel" do
      ctx = world()
      member_story(ctx)
      thread = insert!(ctx, story_id: ctx.story.id)

      assert {:error, :supersede_target_not_found} =
               Coordination.post(ctx.tenant.id, ctx.agent.id, :agent, %{
                 project_id: ctx.project.id,
                 body: "next",
                 supersedes: thread.id,
                 audit: []
               })
    end
  end

  # Makes the world's agent a writable member of its project (an assigned story).
  defp member_story(ctx) do
    fixture(:story, %{
      tenant_id: ctx.tenant.id,
      project_id: ctx.project.id,
      assigned_agent_id: ctx.agent.id,
      agent_status: :assigned
    })
  end
end
