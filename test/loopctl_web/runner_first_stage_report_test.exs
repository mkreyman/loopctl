defmodule LoopctlWeb.RunnerFirstStageReportTest do
  @moduledoc """
  THE LIVENESS PROBE the delivery loop did not have (#803, loopctl#849).

  Every stage report the loop has ever made in production was refused `stale_stage`, and both
  suites were green throughout. They were green because each one MANUFACTURES the state the
  report is judged against: `LoopctlWeb.RunnerChannelStageTest` dispatches with
  `Runners.dispatch/3` — which claims nothing and says so — and then writes the stage row at
  `:implementing` with a fixture, so the row is wherever the test needs it to be. The runner's
  own suite says the same of itself: the compare-and-set is not modelled and the reply is
  scripted.

  So the property that actually failed had no test on either side: **a story placed the way
  production places it accepts the runner's FIRST stage report.** KB `bc294563` names the
  class — a gate whose input no production caller writes is off, and tests that hand-craft the
  state hide it — and its review question is the one this file answers: what production call
  path writes the field this reads, and which test fails if that write is deleted?

  A placement writes through BOTH repos, the claim on `AdminRepo` and the transition on
  `Loopctl.Repo`; in test both run on the test's one sandbox connection
  (`Loopctl.AdminRepo.Route`), which the channel process reaches through `$callers`, so the
  placement, the channel's transition and the reads below all see one transaction.
  """

  use LoopctlWeb.ChannelCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.Placement
  alias Loopctl.Delivery.Stages
  alias Loopctl.Progress

  setup :verify_on_exit!

  @repo "mkreyman/home_care_billing"

  setup do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    {raw, runner} = fixture(:runner, %{tenant_id: tenant.id, name: "minis"})
    {_raw, operator} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

    {:ok, socket} = connect_runner_socket(raw)

    {:ok, _reply, channel} =
      subscribe_and_join(
        socket,
        "runner:" <> runner.id,
        runner_join_payload("minis", %{"repos" => [@repo]})
      )

    _ = :sys.get_state(channel.channel_pid)

    story = fixture(:ledger_story, %{tenant_id: tenant.id})
    story = contract_and_queue(tenant.id, story)
    bind_repo(tenant.id, story)

    %{tenant: tenant, runner: runner, channel: channel, story: story, operator: operator}
  end

  describe "a story placed the way production places it" do
    test "accepts the runner's FIRST stage report, claimed -> worktree", ctx do
      %{channel: channel, story: story} = ctx

      {dispatch_id, epoch} = place!(ctx)
      accept!(channel, dispatch_id, epoch)

      # THE MESSAGE THE FIRST END-TO-END RUN SENT, and the one production refused every time.
      # The runner starts its stream at `claimed` because that is what the contract's forward
      # line says a dispatched story is at; the refusal was correct then, because nothing had
      # claimed it. `Placement.place/4` is what claims, and this asserts the pair works
      # together rather than each half separately.
      ref =
        push(channel, "stage", %{
          "dispatch_id" => dispatch_id,
          "claim_epoch" => epoch,
          "from" => "claimed",
          "to" => "worktree"
        })

      assert_reply ref, :ok, reply, reply_timeout()
      assert reply.stage == "worktree"

      assert stage(story) == :worktree
    end

    test "and the SAME report is refused when nothing claimed the story", ctx do
      %{channel: channel, runner: runner, story: story} = ctx

      # BOUND ONCE, off the STORY, because the story's epoch is what `Stages.advance/4` fences
      # on — and `RunnerStages.apply/3` compares the message against the DISPATCH record before
      # the row is consulted at all. Re-read per message, a lease reclaim landing mid-test
      # would make this control fail with `stale_claim_epoch`: a refusal, but not the one it
      # names.
      epoch = story_epoch(ctx)

      # The negative control, and the whole reason the positive one means something. This is
      # the production RPC path the first run took: `Runners.dispatch/3` pushes and claims
      # NOTHING — its own moduledoc says "placement and claiming are the caller's" — so the
      # row is still at `queued` when the session reports `claimed -> worktree`.
      #
      # Without this, a change that quietly stopped claiming would leave the test above passing
      # for the wrong reason, because `stale_stage` is the row's answer and not the socket's.
      payload =
        build(:runner_dispatch, %{
          "story_id" => story.id,
          "claim_epoch" => epoch,
          "repo" => @repo
        })

      :ok = Loopctl.Runners.dispatch(runner.tenant_id, runner.id, payload)
      assert_push "dispatch", _pushed, reply_timeout()
      accept!(channel, payload["dispatch_id"], epoch)

      ref =
        push(channel, "stage", %{
          "dispatch_id" => payload["dispatch_id"],
          "claim_epoch" => epoch,
          "from" => "claimed",
          "to" => "worktree"
        })

      # THE REASON IS THE WHOLE ASSERTION, and there is deliberately no row read beside it: the
      # control writes nothing, so `queued` is true whether or not the report was judged, and
      # asserting it would look like evidence the row was inspected while being true either way.
      assert_reply ref, :error, %{reason: "stale_stage"}, reply_timeout()
    end
  end

  # -- helpers ---------------------------------------------------------------------------

  defp place!(ctx) do
    %{runner: runner, story: story, operator: operator} = ctx
    dispatch_id = Ecto.UUID.generate()

    payload = %{
      "dispatch_id" => dispatch_id,
      "story_id" => story.id,
      "kind" => "implement",
      "wall_clock_seconds" => 3_600,
      "max_turns" => 50
    }

    {:ok, placed} =
      Placement.place(runner.tenant_id, runner.id, payload,
        api_key: operator,
        actor_label: "test:first_stage_report"
      )

    assert_push "dispatch", _pushed, reply_timeout()

    # The epoch the CLAIM produced, not the one the story had: claiming bumps it, and every
    # message about this dispatch is fenced on the new one.
    {dispatch_id, placed.claim_epoch}
  end

  # A dispatch the runner has ACCEPTED, which is what `stage` requires: an unaccepted one is
  # refused `dispatch_not_accepted` and would hide whichever answer the row would have given.
  defp accept!(channel, dispatch_id, epoch) do
    ref =
      push(channel, "dispatch_reply", %{
        "dispatch_id" => dispatch_id,
        "claim_epoch" => epoch,
        "decision" => "accepted"
      })

    assert_reply ref, :ok, _reply, reply_timeout()
  end

  defp stage(story) do
    Stages.get(story.tenant_id, story.id).stage
  end

  # The STORY's epoch, which is what every transition is fenced on. The stage row carries one
  # too and they are in lockstep here, but a reclaim moves the story's without rebinding the
  # row — and reading the row's would then fence a message against a number nothing checks.
  defp story_epoch(ctx) do
    AdminRepo.get!(Loopctl.WorkBreakdown.Story, ctx.story.id).claim_epoch
  end

  defp contract_and_queue(tenant_id, story) do
    {:ok, story} =
      Progress.contract_story(tenant_id, story.id, %{},
        actor_label: "test",
        skip_contract_check: true
      )

    {:ok, _row} = Stages.open(tenant_id, story.id, actor_label: "test")
    epoch = story.claim_epoch
    {:ok, _} = Stages.advance(tenant_id, story.id, {:detected, :triaged}, claim_epoch: epoch)
    {:ok, _} = Stages.advance(tenant_id, story.id, {:triaged, :queued}, claim_epoch: epoch)

    story
  end

  defp bind_repo(tenant_id, story) do
    now = DateTime.utc_now()

    AdminRepo.insert!(%Loopctl.Intake.Source{
      tenant_id: tenant_id,
      project_id: story.project_id,
      repo_full_name: @repo,
      base_branch: "master",
      webhook_secret: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
      inserted_at: now,
      updated_at: now
    })
  end
end
