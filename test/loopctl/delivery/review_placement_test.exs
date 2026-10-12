defmodule Loopctl.Delivery.ReviewPlacementTest do
  @moduledoc """
  US-45.3 end to end over a real runner socket: `Loopctl.Delivery.Placement.place_review/4`
  pushes a `review` dispatch, and the runner holding it answers with `review_finding` and
  `review_verdict` (contract 1.21.0), applied by `Loopctl.Delivery.RunnerReviews`.

  The rules themselves are in `Loopctl.Threads.ReviewsTest`; this module pins the wiring they
  cannot see — the push, the socket events, the refusals as they reach the wire, the slot the
  verdict gives back, the custody halt, and the stage the ceiling escalates.

  The socket authenticates on `AdminRepo` while the ledger and the thread live on the RLS
  `Repo`. AdminRepo runs on Repo's sandbox connection in test (`Loopctl.AdminRepo.Route`),
  and the channel process inherits the test's `$callers`, so the socket sees the runner this
  test inserted and nothing here commits.
  """

  use LoopctlWeb.ChannelCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.AuditChain.Entry, as: ChainEntry
  alias Loopctl.Delivery.Placement
  alias Loopctl.Delivery.RunnerReviews
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.OwnLog
  alias Loopctl.Progress
  alias Loopctl.Repo
  alias Loopctl.Runners
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.Runner
  alias Loopctl.Tenants.Tenant
  alias Loopctl.Threads
  alias Loopctl.Threads.Entry
  alias Loopctl.Threads.Review
  alias Loopctl.WorkBreakdown.Story
  alias LoopctlWeb.RunnerSocket

  setup :verify_on_exit!

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
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    {raw, runner} = fixture(:runner, %{tenant_id: tenant.id, name: "reviewer"})
    {_raw, operator} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
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

  defp chain_count(ctx) do
    {:ok, count} =
      Repo.with_tenant(ctx.tenant_id, fn ->
        Repo.aggregate(
          from(c in ChainEntry, where: c.tenant_id == ^ctx.tenant_id),
          :count
        )
      end)

    count
  end

  defp stage_of(ctx) do
    {:ok, stage} =
      Repo.with_tenant(ctx.tenant_id, fn ->
        Repo.one(from s in StoryStage, where: s.story_id == ^ctx.story.id, select: s.stage)
      end)

    stage
  end

  defp reviews(ctx) do
    {:ok, rows} =
      Repo.with_tenant(ctx.tenant_id, fn ->
        Repo.all(from r in Review, where: r.story_id == ^ctx.story.id)
      end)

    rows
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

    test "a lost response is retried with the same dispatch_id and answers the same review",
         ctx do
      %{review: review, dispatch_id: dispatch_id} = accepted_review!(ctx)
      chained = chain_count(ctx)

      # The runner already holds it and replied, so a second push would be refused
      # (dispatch_already_replied): the retry is answered from the row instead.

      assert {:ok, %{review: ^review, dispatch_id: ^dispatch_id}} =
               place(ctx, dispatch_id: dispatch_id)

      refute_push "dispatch", _, 200
      assert chain_count(ctx) == chained

      # The same id for another story is a different placement.
      other = fixture(:ledger_story, %{tenant_id: ctx.tenant_id, claim_epoch: @epoch})

      assert {:error, {:conflict, "dispatch_id_conflict", _}} =
               Placement.place_review(ctx.tenant_id, ctx.runner.id, other.id,
                 api_key: ctx.operator,
                 dispatch_id: dispatch_id,
                 repo: @repo,
                 base_branch: "master"
               )
    end

    test "a retry of a review the runner refused is review_dispatch_refused", ctx do
      {:ok, %{dispatch_id: dispatch_id}} = place(ctx)
      assert_push "dispatch", _, @reply_timeout

      ref =
        push(ctx.channel, "dispatch_reply", %{
          "dispatch_id" => dispatch_id,
          "claim_epoch" => @epoch,
          "decision" => "refused",
          "reason" => "draining"
        })

      assert_reply ref, :ok, _, @reply_timeout

      assert {:error, {:conflict, "review_dispatch_refused", message}} =
               place(ctx, dispatch_id: dispatch_id)

      assert message =~ "new dispatch_id"
      refute_push "dispatch", _, 200
    end

    test "the loser of a race answers from the row and never pushes", ctx do
      # `record_review/3` answered `:existing`: another placement recorded this id first and
      # owns the push, which has not reached the ledger yet.
      {:ok, review, :created} =
        Threads.record_review(ctx.tenant_id, ctx.story.id,
          dispatch_id: Ecto.UUID.generate(),
          runner_id: ctx.runner.id,
          agent_id: ctx.runner.agent_id,
          placed_by: "t"
        )

      assert {:ok, %{review: ^review}} =
               Placement.answer_recorded(ctx.tenant_id, ctx.runner.id, review, push_unsent: false)

      refute_push "dispatch", _, 200
    end

    test "a recorded review whose push never reached the ledger is pushed by the retry", ctx do
      dispatch_id = Ecto.UUID.generate()

      {:ok, review, :created} =
        Threads.record_review(ctx.tenant_id, ctx.story.id,
          dispatch_id: dispatch_id,
          runner_id: ctx.runner.id,
          agent_id: ctx.runner.agent_id,
          placed_by: "t"
        )

      assert {:ok, %{review: ^review}} = place(ctx, dispatch_id: dispatch_id)
      assert_push "dispatch", %{dispatch_id: ^dispatch_id, kind: "review"}, @reply_timeout
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

    test "a payload the contract refuses records no review and chains nothing", ctx do
      chained = chain_count(ctx)

      # Over the contract's one-day maximum: the push would refuse it at the cast.
      assert {:error, {:invalid, _}} = place(ctx, wall_clock_seconds: 86_400 * 2)

      refute_push "dispatch", _, 200
      assert reviews(ctx) == []
      assert chain_count(ctx) == chained
    end

    test "a push the runner would refuse records no review", ctx do
      # The runner is at capacity: every slot it has is taken.
      AdminRepo.update_all(
        from(r in Runner,
          where: r.id == ^ctx.runner.id,
          update: [set: [in_flight: r.max_sessions]]
        ),
        []
      )

      assert {:error, :runner_at_capacity} = place(ctx)
      refute_push "dispatch", _, 200
      assert reviews(ctx) == []

      # Not on a socket at all: refused before anything is recorded.
      {_raw, offline} = fixture(:runner, %{tenant_id: ctx.tenant_id, name: "offline"})

      assert {:error, :runner_not_connected} =
               Placement.place_review(ctx.tenant_id, offline.id, ctx.story.id,
                 api_key: ctx.operator,
                 repo: @repo,
                 base_branch: "master",
                 wall_clock_seconds: 600,
                 max_turns: 20
               )

      assert reviews(ctx) == []
    end

    test "an agent-role key may not request one, and a halted tenant places nothing", ctx do
      agent = fixture(:agent, %{tenant_id: ctx.tenant_id})

      {_raw, agent_key} =
        fixture(:api_key, %{tenant_id: ctx.tenant_id, role: :agent, agent_id: agent.id})

      assert {:error, :insufficient_role} = place(ctx, api_key: agent_key)

      halt(ctx)
      assert {:error, :tenant_halted} = place(ctx)
      refute_push "dispatch", _, 200
    end
  end

  describe "judgements over the socket" do
    test "a finding and the verdict are recorded; the verdict closes the review, the session's end frees the slot",
         ctx do
      %{review: review, dispatch_id: dispatch_id} = accepted_review!(ctx)

      ref = finding(ctx, dispatch_id, %{"client_seq" => 1, "location" => "a.ex:1"})
      assert_reply ref, :ok, %{entry_id: entry_id, replayed: false}, @reply_timeout

      ref = finding(ctx, dispatch_id, %{"client_seq" => 1, "location" => "a.ex:1"})
      assert_reply ref, :ok, %{entry_id: ^entry_id, replayed: true}, @reply_timeout

      ref = verdict(ctx, dispatch_id)
      assert_reply ref, :ok, %{replayed: false, escalated: false}, @reply_timeout

      # The session is still running when it sends the verdict: its slot stays held.
      assert is_nil(ledger_row(ctx, dispatch_id).released_at)

      ref = finding(ctx, dispatch_id)
      assert_reply ref, :error, %{reason: "review_closed"}, @reply_timeout

      ref =
        push(ctx.channel, "session_ended", %{
          "dispatch_id" => dispatch_id,
          "claim_epoch" => @epoch,
          "reason" => "completed"
        })

      assert_reply ref, :ok, %{kind: "review"}, @reply_timeout
      refute is_nil(ledger_row(ctx, dispatch_id).released_at)

      {:ok, thread} = Threads.get_thread(ctx.tenant_id, ctx.story.id)
      assert Enum.any?(thread.entries, &(&1.id == entry_id and &1.review_id == review.id))
    end

    test "only a review dispatch judges: an implement dispatch is wrong_dispatch_kind", ctx do
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
      assert_reply ref, :error, %{reason: "wrong_dispatch_kind"}, @reply_timeout

      ref = verdict(ctx, payload["dispatch_id"])
      assert_reply ref, :error, %{reason: "wrong_dispatch_kind"}, @reply_timeout
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
      assert_reply ref, :error, %{reason: "wrong_dispatch_kind"}, @reply_timeout
    end

    test "after a force-unclaim a verdict is refused review_claim_ended and records nothing",
         ctx do
      fixture(:story_stage, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story.id,
        stage: :implementing,
        claim_epoch: @epoch
      })

      %{dispatch_id: r1} = accepted_review!(ctx)
      assert_reply verdict(ctx, r1), :ok, _, @reply_timeout
      checkpoint(ctx, 2)
      %{review: review, dispatch_id: r2} = accepted_review!(ctx)

      ref = finding(ctx, r2, %{"introduced_by" => "none", "severity" => "critical"})
      assert_reply ref, :ok, _, @reply_timeout

      # What a force-unclaim writes (`Progress.force_unclaim_story/3`, which runs on AdminRepo
      # and so cannot see this sandboxed story): the claimant cleared and the claim's release
      # change, which moves the epoch on.
      set_story(
        ctx,
        [agent_status: :pending, assigned_agent_id: nil] ++
          Map.to_list(Progress.claim_release_change(story_row(ctx)))
      )

      ref = verdict(ctx, r2)
      assert_reply ref, :error, %{reason: "review_claim_ended"}, @reply_timeout

      {:ok, kinds} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          Repo.all(from e in Entry, where: e.review_id == ^review.id, select: e.kind)
        end)

      assert kinds == [:finding]
    end

    test "a resent verdict answers the recorded escalation and re-drives the stage move", ctx do
      fixture(:story_stage, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story.id,
        stage: :implementing,
        claim_epoch: @epoch
      })

      %{dispatch_id: r1} = accepted_review!(ctx)
      assert_reply verdict(ctx, r1), :ok, _, @reply_timeout
      checkpoint(ctx, 2)
      %{dispatch_id: r2} = accepted_review!(ctx)
      ref = finding(ctx, r2, %{"introduced_by" => "none", "severity" => "high"})
      assert_reply ref, :ok, _, @reply_timeout

      assert_reply verdict(ctx, r2, 77), :ok, %{escalated: true, replayed: false}, @reply_timeout
      assert stage_of(ctx) == :escalated

      # The first delivery's move never landed, as far as the stage row knows.
      {:ok, {1, _}} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          from(s in StoryStage, where: s.story_id == ^ctx.story.id)
          |> Repo.update_all(set: [stage: :implementing])
        end)

      assert_reply verdict(ctx, r2, 77), :ok, %{escalated: true, replayed: true}, @reply_timeout
      assert stage_of(ctx) == :escalated
    end

    test "a review session that ends without a verdict frees its slot, and moves no stage",
         ctx do
      %{dispatch_id: first} = accepted_review!(ctx)
      %{dispatch_id: second} = accepted_review!(ctx)

      # The second review completes round 1, so the first is superseded and never judges.
      assert_reply verdict(ctx, second), :ok, _, @reply_timeout

      assert_reply finding(ctx, first),
                   :error,
                   %{reason: "review_round_superseded"},
                   @reply_timeout

      assert is_nil(ledger_row(ctx, first).released_at)

      ended = %{"dispatch_id" => first, "claim_epoch" => @epoch, "reason" => "completed"}
      ref = push(ctx.channel, "session_ended", ended)
      assert_reply ref, :ok, %{kind: "review", replayed: false}, @reply_timeout

      row = ledger_row(ctx, first)
      refute is_nil(row.released_at)
      assert row.session_ended_reason == "completed"
      assert row.counts_toward_retry_ceiling == nil

      ref = push(ctx.channel, "session_ended", ended)
      assert_reply ref, :ok, %{kind: "review", replayed: true}, @reply_timeout
    end

    test "freeing a review session's slot never raises: a database failure is logged", ctx do
      dispatch_id = Ecto.UUID.generate()

      log =
        OwnLog.capture_naming(dispatch_id, fn ->
          Repo.transaction(fn ->
            {:error, _} = Repo.query("SELECT 1 / 0")
            assert :ok = RunnerReviews.free_slot(ctx.tenant_id, dispatch_id, 0)
            Repo.rollback(:done)
          end)
        end)

      assert log =~ "review slot not released"
    end

    test "a review session that never ran cannot report ending", ctx do
      {:ok, %{dispatch_id: dispatch_id}} = place(ctx)
      assert_push "dispatch", _, @reply_timeout

      ref =
        push(ctx.channel, "session_ended", %{
          "dispatch_id" => dispatch_id,
          "claim_epoch" => @epoch,
          "reason" => "crashed"
        })

      assert_reply ref, :error, %{reason: "dispatch_not_accepted"}, @reply_timeout
      assert is_nil(ledger_row(ctx, dispatch_id).session_ended_reason)
    end

    test "an implement placement cannot resume a review's dispatch id", ctx do
      %{dispatch_id: dispatch_id} = accepted_review!(ctx)

      assert {:error, :dispatch_id_conflict} =
               Placement.place(
                 ctx.tenant_id,
                 ctx.runner.id,
                 %{"dispatch_id" => dispatch_id, "story_id" => ctx.story.id},
                 api_key: ctx.operator
               )

      refute_push "dispatch", _, 200
    end

    test "a review session cannot report a stage: only an implement session moves one", ctx do
      fixture(:story_stage, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story.id,
        stage: :implementing,
        claim_epoch: @epoch
      })

      %{dispatch_id: dispatch_id} = accepted_review!(ctx)

      ref =
        push(ctx.channel, "stage", %{
          "dispatch_id" => dispatch_id,
          "claim_epoch" => @epoch,
          "from" => "implementing",
          "to" => "reviewing"
        })

      assert_reply ref, :error, %{reason: "wrong_dispatch_kind"}, @reply_timeout

      {:ok, row} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          Repo.one(from s in StoryStage, where: s.story_id == ^ctx.story.id)
        end)

      assert row.stage == :implementing
    end

    test "after a review session reports ending, a late verdict is refused; a resend is not",
         ctx do
      %{dispatch_id: dispatch_id} = accepted_review!(ctx)
      ref = finding(ctx, dispatch_id, %{"client_seq" => 5})
      assert_reply ref, :ok, %{entry_id: entry_id}, @reply_timeout

      ref =
        push(ctx.channel, "session_ended", %{
          "dispatch_id" => dispatch_id,
          "claim_epoch" => @epoch,
          "reason" => "wall_clock_exceeded"
        })

      assert_reply ref, :ok, %{kind: "review"}, @reply_timeout

      assert_reply verdict(ctx, dispatch_id),
                   :error,
                   %{reason: "dispatch_not_accepted"},
                   @reply_timeout

      ref = finding(ctx, dispatch_id, %{"client_seq" => 5})
      assert_reply ref, :ok, %{entry_id: ^entry_id, replayed: true}, @reply_timeout
    end

    test "a halted tenant's judgements are refused tenant_halted, and nothing is written", ctx do
      %{dispatch_id: dispatch_id} = accepted_review!(ctx)
      halt(ctx)

      ref = finding(ctx, dispatch_id)
      assert_reply ref, :error, %{reason: "tenant_halted"}, @reply_timeout

      {:ok, thread} = Threads.get_thread(ctx.tenant_id, ctx.story.id)
      refute Enum.any?(thread.entries, &(&1.kind == :finding))
    end

    test "during a halt, a resend of a judgement already recorded is still answered", ctx do
      %{dispatch_id: dispatch_id} = accepted_review!(ctx)
      ref = finding(ctx, dispatch_id, %{"client_seq" => 9})
      assert_reply ref, :ok, %{entry_id: entry_id}, @reply_timeout
      assert_reply verdict(ctx, dispatch_id, 10), :ok, %{replayed: false}, @reply_timeout

      halt(ctx)

      ref = finding(ctx, dispatch_id, %{"client_seq" => 9})
      assert_reply ref, :ok, %{entry_id: ^entry_id, replayed: true}, @reply_timeout
      assert_reply verdict(ctx, dispatch_id, 10), :ok, %{replayed: true}, @reply_timeout
    end

    test "a reviewer that stops being separate is refused on the wire", ctx do
      %{dispatch_id: dispatch_id} = accepted_review!(ctx)
      set_story(ctx, assigned_agent_id: ctx.runner.agent_id)

      ref = finding(ctx, dispatch_id)
      assert_reply ref, :error, %{reason: "reviewer_not_separate"}, @reply_timeout
    end

    test "an implementer lineage that becomes unreadable is refused reviewer_not_separate", ctx do
      %{dispatch_id: dispatch_id} = accepted_review!(ctx)

      # Separation fails CLOSED (`unresolvable_dispatch_lineage`), and the runner hears the
      # contract's permanent refusal rather than the catch-all's `internal_error`.
      {:ok, %{num_rows: 1}} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          Repo.query!("UPDATE dispatches SET lineage_path = '{}' WHERE id = $1", [
            Ecto.UUID.dump!(ctx.session.id)
          ])
        end)

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

      # The two accepted reviews hold both of the runner's slots (`max_sessions: 2`), and a
      # placement checks the slot before the ceiling. Free them, as the sessions' ends would,
      # so the third placement is refused by the CEILING. Without this it was refused on
      # capacity once the slot counts and this read shared a connection (US-46.2).
      AdminRepo.update_all(from(r in Runner, where: r.id == ^ctx.runner.id), set: [in_flight: 0])

      assert {:error, {:conflict, "review_ceiling_reached", _}} = place(ctx)
    end
  end

  defp halt(ctx) do
    AdminRepo.update_all(from(t in Tenant, where: t.id == ^ctx.tenant_id),
      set: [custody_halted_at: DateTime.utc_now()]
    )
  end
end
