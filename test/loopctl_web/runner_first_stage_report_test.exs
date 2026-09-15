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

  `async: false` and COMMITTED, for the reason `Loopctl.Delivery.PlacementTest` gives: a
  placement writes through BOTH repos — the claim on `AdminRepo`, the transition on
  `Loopctl.Repo` — and those two sandbox connections cannot see each other's uncommitted work.

  What is NOT the reason, because a maintainer acting on it would break the file: the channel
  process CAN see this test's uncommitted rows. `Loopctl.DataCase` starts every sandbox owner
  with `shared: not tags[:async]`, so under `async: false` the channel runs on exactly this
  connection — which is why the stage assertion below reads the SANDBOX row and not the
  committed one, and why rewriting it as the `unboxed(...)` read `PlacementTest` uses would
  report a working write as a failure.
  """

  use LoopctlWeb.ChannelCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Delivery.Placement
  alias Loopctl.Delivery.Stages
  alias Loopctl.Progress
  alias LoopctlWeb.RunnerSocket

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  @reply_timeout 2_000
  @repo "mkreyman/home_care_billing"

  setup do
    sweep_committed_runner_tenants()

    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
    {raw, runner} = fixture(:committed_runner, %{tenant_id: tenant.id, name: "minis"})
    {_raw, operator} = fixture(:committed_operator_key, %{tenant_id: tenant.id})

    {:ok, socket} = connect(RunnerSocket, %{}, connect_info: connect_info(raw))

    {:ok, _reply, channel} =
      subscribe_and_join(socket, "runner:" <> runner.id, join_payload("minis"))

    _ = :sys.get_state(channel.channel_pid)

    story = fixture(:committed_story, %{tenant_id: tenant.id})
    story = unboxed(fn -> contract_and_queue(tenant.id, story) end)
    unboxed(fn -> bind_repo(tenant.id, story) end)

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

      assert_reply ref, :ok, reply, @reply_timeout
      assert reply.stage == "worktree"

      # Read on the SANDBOX connection the channel wrote on, not unboxed: the fixtures and the
      # placement are committed, but the transition the channel just made lives in this
      # process's transaction — an unboxed read sees the committed `claimed` and would call a
      # working write a failure.
      assert sandboxed_stage(story) == :worktree
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

      :ok = unboxed(fn -> Loopctl.Runners.dispatch(runner.tenant_id, runner.id, payload) end)
      assert_push "dispatch", _pushed, @reply_timeout
      accept!(channel, payload["dispatch_id"], epoch)

      ref =
        push(channel, "stage", %{
          "dispatch_id" => payload["dispatch_id"],
          "claim_epoch" => epoch,
          "from" => "claimed",
          "to" => "worktree"
        })

      # THE REASON IS THE WHOLE ASSERTION, and there is deliberately no row read beside it: the
      # control writes nothing, so `queued` is equally true of the committed row and of the
      # sandbox one, and asserting it would look like evidence the row was inspected while
      # being true either way.
      assert_reply ref, :error, %{reason: "stale_stage"}, @reply_timeout
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
      unboxed(fn ->
        Placement.place(runner.tenant_id, runner.id, payload,
          api_key: operator,
          actor_label: "test:first_stage_report"
        )
      end)

    assert_push "dispatch", _pushed, @reply_timeout

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

    assert_reply ref, :ok, _reply, @reply_timeout
  end

  defp sandboxed_stage(story) do
    {:ok, row} =
      Loopctl.Repo.with_tenant(story.tenant_id, fn -> Stages.get(story.tenant_id, story.id) end)

    row.stage
  end

  # The STORY's epoch, which is what every transition is fenced on. The stage row carries one
  # too and they are in lockstep here, but a reclaim moves the story's without rebinding the
  # row — and reading the row's would then fence a message against a number nothing checks.
  defp story_epoch(ctx) do
    unboxed(fn -> AdminRepo.get!(Loopctl.WorkBreakdown.Story, ctx.story.id) end).claim_epoch
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

  defp unboxed(fun) do
    Sandbox.unboxed_run(AdminRepo, fn -> Sandbox.unboxed_run(Loopctl.Repo, fun) end)
  end

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
      "max_sessions" => 2,
      "in_flight" => 0,
      "draining" => false
    }
  end
end
