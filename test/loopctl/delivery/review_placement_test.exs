defmodule Loopctl.Delivery.ReviewPlacementTest do
  @moduledoc """
  US-45.3 end to end over a real runner socket: `Loopctl.Delivery.Placement.place_review/4`
  pushes a `review` dispatch, and the runner holding it answers with `review_finding` and
  `review_verdict` (contract 1.21.0), applied by `Loopctl.Delivery.RunnerReviews`.

  The rules themselves are in `Loopctl.Threads.ReviewsTest`; this module pins the wiring they
  cannot see — the push, the socket events, the refusals as they reach the wire, the slot the
  verdict gives back, the custody halt, and the stage the ceiling escalates.

  `async: false` for the reason every runner channel test gives: the runner and its tenant are
  COMMITTED, because the socket authenticates on `AdminRepo` while the ledger and the thread
  live on the RLS `Repo`.
  """

  use LoopctlWeb.ChannelCase, async: false

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Delivery.Placement
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Repo
  alias Loopctl.Runners
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Tenants.Tenant
  alias Loopctl.Threads
  alias Loopctl.WorkBreakdown.Story
  alias LoopctlWeb.RunnerSocket

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  @reply_timeout 2_000
  @epoch 3
  @tree String.duplicate("c", 40)
  @repo "mkreyman/home_care_billing"

  defp connect_info(token) do
    %{
      x_headers: [{RunnerSocket.token_header(), token}],
      peer_data: %{address: {127, 0, 0, 1}, port: 40_000, ssl_cert: nil}
    }
  end

  defp join_payload(machine) do
    %{
      "contract_version" => RunnerContract.version(),
      "machine" => machine,
      "cores" => 16,
      "memory_mb" => 28_000,
      "repos" => [@repo],
      "max_sessions" => 4,
      "in_flight" => 0,
      "draining" => false,
      "kinds" => ["implement", "review"]
    }
  end

  # A joined REVIEWING runner, and a story another agent has claimed through a dispatch, with
  # one checkpoint of the current claim.
  setup do
    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
    {raw, runner} = fixture(:committed_runner, %{tenant_id: tenant.id, name: "reviewer"})
    {_raw, operator} = fixture(:committed_operator_key, %{tenant_id: tenant.id})
    {:ok, socket} = connect(RunnerSocket, %{}, connect_info: connect_info(raw))

    {:ok, _reply, channel} =
      subscribe_and_join(socket, "runner:" <> runner.id, join_payload("reviewer"))

    _ = :sys.get_state(channel.channel_pid)

    story = fixture(:ledger_story, %{tenant_id: tenant.id, claim_epoch: @epoch})
    implementer = fixture(:stage_agent, %{tenant_id: tenant.id})
    orchestrator = fixture(:stage_agent, %{tenant_id: tenant.id})
    root = fixture(:stage_dispatch, %{tenant_id: tenant.id, agent_id: orchestrator.id})

    session =
      fixture(:stage_dispatch, %{tenant_id: tenant.id, agent_id: implementer.id, parent: root})

    ctx = %{
      tenant_id: tenant.id,
      runner: runner,
      channel: channel,
      operator: operator,
      story: story,
      implementer: implementer,
      session: session
    }

    set_story(ctx,
      assigned_agent_id: implementer.id,
      implementer_dispatch_id: session.id,
      agent_status: :implementing,
      claimed_until: DateTime.add(DateTime.utc_now(), 3_600)
    )

    checkpoint(ctx, 1)
    {:ok, ctx}
  end

  defp set_story(ctx, fields) do
    {:ok, _} =
      Repo.with_tenant(ctx.tenant_id, fn ->
        from(s in Story, where: s.id == ^ctx.story.id) |> Repo.update_all(set: fields)
      end)
  end

  defp checkpoint(ctx, n) do
    {:ok, cp, :created} =
      Threads.record_checkpoint(ctx.tenant_id, ctx.story.id,
        agent_id: ctx.implementer.id,
        claim_epoch: @epoch,
        commit_sha: n |> Integer.to_string() |> String.pad_leading(40, "0"),
        tree_sha: @tree,
        author_principal: "agent:#{ctx.implementer.id}",
        actor_lineage: ctx.session.lineage_path
      )

    cp
  end

  defp place(ctx, opts \\ []) do
    Placement.place_review(
      ctx.tenant_id,
      ctx.runner.id,
      ctx.story.id,
      Keyword.merge(
        [
          api_key: ctx.operator,
          repo: @repo,
          base_branch: "master",
          wall_clock_seconds: 600,
          max_turns: 20
        ],
        opts
      )
    )
  end

  # Placed, pushed and accepted: what a runner holds when it starts reviewing.
  defp accepted_review!(ctx, opts \\ []) do
    {:ok, %{review: review, dispatch_id: dispatch_id}} = place(ctx, opts)
    assert_push "dispatch", pushed, @reply_timeout
    assert pushed.dispatch_id == dispatch_id

    ref =
      push(ctx.channel, "dispatch_reply", %{
        "dispatch_id" => dispatch_id,
        "claim_epoch" => @epoch,
        "decision" => "accepted"
      })

    assert_reply ref, :ok, _, @reply_timeout
    %{review: review, dispatch_id: dispatch_id, pushed: pushed}
  end

  defp finding(ctx, dispatch_id, attrs \\ %{}) do
    push(
      ctx.channel,
      "review_finding",
      Map.merge(
        %{
          "dispatch_id" => dispatch_id,
          "claim_epoch" => @epoch,
          "client_seq" => System.unique_integer([:positive]),
          "body" => "breaks on retry",
          "severity" => "high"
        },
        attrs
      )
    )
  end

  defp verdict(ctx, dispatch_id, seq \\ 999_999) do
    push(ctx.channel, "review_verdict", %{
      "dispatch_id" => dispatch_id,
      "claim_epoch" => @epoch,
      "client_seq" => seq,
      "body" => "round done"
    })
  end

  defp ledger_row(ctx, dispatch_id) do
    {:ok, row} =
      Repo.with_tenant(ctx.tenant_id, fn ->
        Repo.one(from r in DispatchRecord, where: r.dispatch_id == ^dispatch_id)
      end)

    row
  end

  defp story_row(ctx) do
    {:ok, story} =
      Repo.with_tenant(ctx.tenant_id, fn -> Repo.get!(Story, ctx.story.id) end)

    story
  end

  describe "place_review/4" do
    test "pushes a review dispatch carrying the story and the review, and claims nothing", ctx do
      %{review: review, dispatch_id: dispatch_id, pushed: pushed} = accepted_review!(ctx)

      assert pushed.kind == "review"
      assert pushed.claim_epoch == @epoch
      assert pushed.story.id == ctx.story.id
      assert pushed.review.review_id == review.id
      assert pushed.review.round == 1
      assert pushed.review.checkpoint_id == review.checkpoint_id

      assert ledger_row(ctx, dispatch_id).kind == "review"
      assert review.runner_id == ctx.runner.id
      assert review.agent_id == ctx.runner.agent_id

      # Nothing was claimed: the implementer still holds the story under the same epoch.
      story = story_row(ctx)
      assert story.assigned_agent_id == ctx.implementer.id
      assert story.claim_epoch == @epoch
    end

    test "a lost response is retried with the same dispatch_id and pushes the same review",
         ctx do
      dispatch_id = Ecto.UUID.generate()

      {:ok, %{review: review}} = place(ctx, dispatch_id: dispatch_id)
      assert_push "dispatch", _, @reply_timeout

      assert {:ok, %{review: ^review}} = place(ctx, dispatch_id: dispatch_id)
      assert_push "dispatch", %{dispatch_id: ^dispatch_id}, @reply_timeout
    end

    test "the runner's agent must be separate from the implementer", ctx do
      set_story(ctx, assigned_agent_id: ctx.runner.agent_id)
      assert {:error, {:conflict, "reviewer_not_separate", _}} = place(ctx)
      refute_push "dispatch", _, 200
    end

    test "an id the runner ledger holds for another dispatch is refused, and nothing is pushed",
         ctx do
      payload =
        build(:runner_dispatch, %{
          "story_id" => ctx.story.id,
          "claim_epoch" => @epoch,
          "repo" => @repo
        })

      :ok = Runners.dispatch(ctx.tenant_id, ctx.runner.id, payload)
      assert_push "dispatch", _, @reply_timeout

      assert {:error, {:conflict, "dispatch_id_conflict", _}} =
               place(ctx, dispatch_id: payload["dispatch_id"])

      refute_push "dispatch", _, 200
    end

    test "an agent-role key may not request one, and a halted tenant places nothing", ctx do
      {_raw, agent_key, _agent} = fixture(:committed_agent_key, %{tenant_id: ctx.tenant_id})
      assert {:error, :insufficient_role} = place(ctx, api_key: agent_key)

      halt(ctx)
      assert {:error, :tenant_halted} = place(ctx)
      refute_push "dispatch", _, 200
    end
  end

  describe "judgements over the socket" do
    test "a finding and the verdict are recorded; the verdict closes the review and its slot",
         ctx do
      %{review: review, dispatch_id: dispatch_id} = accepted_review!(ctx)

      ref = finding(ctx, dispatch_id, %{"client_seq" => 1, "location" => "a.ex:1"})
      assert_reply ref, :ok, %{entry_id: entry_id, replayed: false}, @reply_timeout

      ref = finding(ctx, dispatch_id, %{"client_seq" => 1, "location" => "a.ex:1"})
      assert_reply ref, :ok, %{entry_id: ^entry_id, replayed: true}, @reply_timeout

      ref = verdict(ctx, dispatch_id)
      assert_reply ref, :ok, %{replayed: false, escalated: false}, @reply_timeout
      refute is_nil(ledger_row(ctx, dispatch_id).released_at)

      ref = finding(ctx, dispatch_id)
      assert_reply ref, :error, %{reason: "review_closed"}, @reply_timeout

      {:ok, thread} = Threads.get_thread(ctx.tenant_id, ctx.story.id)
      assert Enum.any?(thread.entries, &(&1.id == entry_id and &1.review_id == review.id))
    end

    test "only a review dispatch judges: an implement dispatch is unknown_dispatch", ctx do
      payload =
        build(:runner_dispatch, %{
          "story_id" => ctx.story.id,
          "claim_epoch" => @epoch,
          "repo" => @repo
        })

      :ok = Runners.dispatch(ctx.tenant_id, ctx.runner.id, payload)
      assert_push "dispatch", _, @reply_timeout

      ref =
        push(ctx.channel, "dispatch_reply", %{
          "dispatch_id" => payload["dispatch_id"],
          "claim_epoch" => @epoch,
          "decision" => "accepted"
        })

      assert_reply ref, :ok, _, @reply_timeout

      ref = finding(ctx, payload["dispatch_id"])
      assert_reply ref, :error, %{reason: "unknown_dispatch"}, @reply_timeout

      ref = verdict(ctx, payload["dispatch_id"])
      assert_reply ref, :error, %{reason: "unknown_dispatch"}, @reply_timeout
    end

    test "a review bound to an id an implement dispatch then took judges nothing", ctx do
      # The order a caller-chosen id allows: the review is recorded first, and an implement
      # dispatch reaches the ledger under the same id before the review's push does. The review
      # row and the runner match, so only the ledger row's KIND stands between the implement
      # session and a verdict.
      dispatch_id = Ecto.UUID.generate()

      {:ok, _review, :created} =
        Threads.record_review(ctx.tenant_id, ctx.story.id,
          dispatch_id: dispatch_id,
          runner_id: ctx.runner.id,
          agent_id: ctx.runner.agent_id,
          placed_by: "t"
        )

      payload =
        build(:runner_dispatch, %{
          "dispatch_id" => dispatch_id,
          "story_id" => ctx.story.id,
          "claim_epoch" => @epoch,
          "repo" => @repo
        })

      :ok = Runners.dispatch(ctx.tenant_id, ctx.runner.id, payload)
      assert_push "dispatch", _, @reply_timeout

      ref =
        push(ctx.channel, "dispatch_reply", %{
          "dispatch_id" => dispatch_id,
          "claim_epoch" => @epoch,
          "decision" => "accepted"
        })

      assert_reply ref, :ok, _, @reply_timeout

      ref = finding(ctx, dispatch_id)
      assert_reply ref, :error, %{reason: "unknown_dispatch"}, @reply_timeout
    end

    test "a halted tenant's judgements are refused tenant_halted, and nothing is written", ctx do
      %{dispatch_id: dispatch_id} = accepted_review!(ctx)
      halt(ctx)

      ref = finding(ctx, dispatch_id)
      assert_reply ref, :error, %{reason: "tenant_halted"}, @reply_timeout

      {:ok, thread} = Threads.get_thread(ctx.tenant_id, ctx.story.id)
      refute Enum.any?(thread.entries, &(&1.kind == :finding))
    end

    test "a reviewer that stops being separate is refused on the wire", ctx do
      %{dispatch_id: dispatch_id} = accepted_review!(ctx)
      set_story(ctx, assigned_agent_id: ctx.runner.agent_id)

      ref = finding(ctx, dispatch_id)
      assert_reply ref, :error, %{reason: "reviewer_not_separate"}, @reply_timeout
    end

    test "a round-2 ceiling with a material finding escalates the delivery stage", ctx do
      fixture(:story_stage, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story.id,
        stage: :implementing,
        claim_epoch: @epoch
      })

      %{dispatch_id: r1} = accepted_review!(ctx)
      ref = finding(ctx, r1, %{"severity" => "low"})
      assert_reply ref, :ok, _, @reply_timeout
      ref = verdict(ctx, r1)
      assert_reply ref, :ok, %{escalated: false}, @reply_timeout

      checkpoint(ctx, 2)
      %{dispatch_id: r2, pushed: pushed} = accepted_review!(ctx)
      assert pushed.review.round == 2

      ref = finding(ctx, r2, %{"introduced_by" => "none", "severity" => "critical"})
      assert_reply ref, :ok, _, @reply_timeout
      ref = verdict(ctx, r2)
      assert_reply ref, :ok, %{escalated: true}, @reply_timeout

      {:ok, row} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          Repo.one(from s in StoryStage, where: s.story_id == ^ctx.story.id)
        end)

      assert row.stage == :escalated

      assert {:error, {:conflict, "review_ceiling_reached", _}} = place(ctx)
    end
  end

  defp halt(ctx) do
    AdminRepo.update_all(from(t in Tenant, where: t.id == ^ctx.tenant_id),
      set: [custody_halted_at: DateTime.utc_now()]
    )
  end
end
