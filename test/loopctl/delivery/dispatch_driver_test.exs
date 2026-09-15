defmodule Loopctl.Delivery.DispatchDriverTest do
  @moduledoc """
  The unattended half of the dispatch trigger (issue #803 §3).

  `async: false`, and COMMITTED rather than sandboxed, for the reason
  `Loopctl.Delivery.PlacementTest`'s moduledoc gives in full: a placement writes through BOTH
  repos and the two sandbox connections cannot see each other's uncommitted work — worse, the
  claim's UPDATE holds the story row, so the stage transition's `FOR SHARE` would sit on it
  until its lock timeout. `sweep_committed_runner_tenants/0` removes what these tests commit.

  ## What is NOT tested here, and why not

  `run/1`'s own two gates read application config, and this repo forbids `Application.put_env`
  in a test — so the driver is DISABLED and its budgets UNSET in every test in this suite, and
  the enabled path is unreachable from here by construction. That is why the module splits
  along exactly that line: `enabled?/0` and `budgets/0` are the decision (asserted below in
  the only state a test can observe), `normalise_budget/2` is the pure judgement inside the
  second one, and `run_with/2` is the work. An operator who turns the driver on runs the same
  `run_with/2` these tests place through; what they run that nothing here does is the two
  `if`s, and those are what the mutation runs in the PR body cover.
  """

  use LoopctlWeb.ChannelCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Delivery.DispatchDriver
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Intake.Source
  alias Loopctl.Progress
  alias Loopctl.Runners.Runner
  alias Loopctl.WorkBreakdown.Stories
  alias LoopctlWeb.RunnerSocket

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  @reply_timeout 2_000
  @budgets %{wall_clock_seconds: 3_600, max_turns: 50}

  setup do
    # SWEPT BEFORE EVERY TEST, not only at the module boundary, for the reason
    # `Loopctl.Workers.TriageTriggerWorkerTest` records: `candidates/1` is FLEET-WIDE, so a
    # queued story an earlier test committed is a candidate of every later pass — the first
    # draft of this file asserted `[:no_runner]` and got six outcomes belonging to other tests.
    sweep_committed_runner_tenants()

    # HUMAN-ANCHORED explicitly, like `PlacementTest`: `place/4` applies the L0 tier gate
    # itself and the committed tenant's column default is `:agent_rooted`.
    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
    {raw, runner} = fixture(:committed_runner, %{tenant_id: tenant.id, name: "minis"})
    {_raw, _operator} = fixture(:committed_operator_key, %{tenant_id: tenant.id})

    %{tenant: tenant, runner: runner, runner_key: raw}
  end

  describe "candidates/1" do
    test "selects only stage rows at queued, oldest first, bounded", ctx do
      first = queued_story(ctx)
      second = queued_story(ctx)

      # The row that must NOT be a candidate, left at `triaged` by the machine rather than
      # moved by an UPDATE: the predicate is the stage, and a story one edge short of queued
      # is the nearest miss there is.
      triaged = triaged_story(ctx)

      # Backdated so the ORDER is a fact of the data rather than of insertion timing — two
      # rows written in the same millisecond would make an oldest-first assertion a coin toss.
      unboxed(fn -> backdate(first.id, -300) end)
      unboxed(fn -> backdate(second.id, -60) end)

      ids = candidate_ids(50)

      assert ids == [first.id, second.id]
      refute triaged.id in ids

      # BOUNDED — and the oldest is the one the bound keeps, which is what makes a full queue
      # drain in order instead of starving its head.
      assert candidate_ids(1) == [first.id]
    end
  end

  describe "available_runner/1" do
    test "nil when the tenant has no connected runner", ctx do
      # The runner ROW exists — the fixture enrolled it — and nothing is joined. A selection
      # on the row alone would return it here and place work on a machine that is not there.
      assert unboxed(fn -> DispatchDriver.available_runner(ctx.tenant.id) end) == nil
    end

    test "the connected runner with a free slot", ctx do
      join_runner(ctx)

      assert %Runner{} = found = unboxed(fn -> DispatchDriver.available_runner(ctx.tenant.id) end)
      assert found.id == ctx.runner.id
    end

    test "nil when the connected runner is full", ctx do
      join_runner(ctx)
      unboxed(fn -> set_in_flight(ctx.runner.id, ctx.runner.max_sessions) end)

      # CONNECTED and useless. `place/4` would take the claim, mint a dispatch and be refused
      # `:runner_at_capacity` on the push, then undo all of it — an undo per attempt is not a
      # selection strategy, which is why capacity is read here and not discovered there.
      assert unboxed(fn -> DispatchDriver.available_runner(ctx.tenant.id) end) == nil
    end

    test "nil when the connected runner has been revoked", ctx do
      join_runner(ctx)
      unboxed(fn -> revoke(ctx.runner.id) end)

      # Revocation is what an operator does to stop a machine being used. A live socket does
      # not survive it as far as selection is concerned.
      assert unboxed(fn -> DispatchDriver.available_runner(ctx.tenant.id) end) == nil
    end

    test "nil for a tenant whose runner belongs to somebody else", ctx do
      join_runner(ctx)
      other = fixture(:committed_tenant, %{trust_tier: :human_anchored})

      # The presence pool is per tenant and so is the row read; this asserts they agree. A
      # name-keyed pool with a fleet-wide row read would place another tenant's work on this
      # machine the moment two tenants enrolled a runner called "minis".
      assert unboxed(fn -> DispatchDriver.available_runner(other.id) end) == nil
    end
  end

  describe "normalise_budget/2" do
    test "a positive integer is the only usable value" do
      assert DispatchDriver.normalise_budget(1, :dispatch_max_turns) == {:ok, 1}
      assert DispatchDriver.normalise_budget(3_600, :dispatch_wall_clock_seconds) == {:ok, 3_600}
    end

    test "everything else is UNSET, named by key" do
      # Zero is the one that matters: a zero budget is not a small budget, it mints dispatches
      # that die on arrival — and `is_integer(value) and value > 0` would have accepted it
      # under a `>=`. The rest are what a hand-edited config produces.
      for value <- [nil, 0, -1, "3600", 3.5, :infinity, %{}] do
        assert DispatchDriver.normalise_budget(value, :dispatch_max_turns) ==
                 {:error, {:unset, :dispatch_max_turns}}
      end
    end
  end

  describe "the config gates" do
    test "the driver is OFF unless an operator turns it on" do
      # What this reads, precisely: `config/runtime.exs` runs in EVERY environment and sets the
      # key from `DISPATCH_DRIVER_ENABLED`, which is unset here — so this is the opt-in
      # deciding, and a deploy that exports nothing gets exactly this. The `false` in
      # `enabled?/0`'s own `Application.get_env/3` is a second layer and is NOT exercised by
      # this (the key is set either way); mutating it alone leaves the suite green, which is
      # why the mutation reported in the PR is on the runtime.exs predicate.
      refute DispatchDriver.enabled?()
    end

    test "a missing budget refuses the pass and NAMES the key" do
      # Unset in every environment, on purpose: a default here would be our guess quietly
      # becoming the operator's cost policy. Named, because "the driver placed nothing" with
      # no reason is indistinguishable from an empty queue.
      assert DispatchDriver.budgets() == {:error, {:unset, :dispatch_wall_clock_seconds}}
    end

    test "run/1 selects NOTHING while the driver is off", ctx do
      # Off is not a failure and not an error: the cron entry runs every minute from the
      # deploy that ships it, and until somebody enables the driver it must report a clean run.
      # A queued story is standing right here, so this is the gate and not an empty queue.
      _story = queued_story(ctx)
      join_runner(ctx)

      assert unboxed(fn -> DispatchDriver.run(20) end) == {:ok, []}
    end
  end

  describe "run_with/2" do
    test "places a queued story on the connected runner", ctx do
      story = bind_repo(ctx, queued_story(ctx))
      channel = join_runner(ctx)

      assert unboxed(fn -> DispatchDriver.run_with(20, @budgets) end) == [:placed]
      assert_push "dispatch", pushed, @reply_timeout

      # The DISPATCH the runner actually receives, field by field, because every one of them
      # is a decision this module made rather than a value it passed through: the budgets are
      # the operator's policy, the branch is derived from the story number, and `claim_epoch`
      # is the fence `place/4` stamps on after claiming.
      assert pushed.story_id == story.id
      assert pushed.kind == "implement"
      assert pushed.wall_clock_seconds == @budgets.wall_clock_seconds
      assert pushed.max_turns == @budgets.max_turns
      assert pushed.base_branch == "master"
      assert pushed.branch == "feature/story-#{story.number}"

      row = unboxed(fn -> Stages.get(ctx.tenant.id, story.id) end)
      assert row.stage == :claimed
      assert row.runner_id == ctx.runner.id
      assert pushed.claim_epoch == row.claim_epoch

      claimed = unboxed(fn -> reload(ctx.tenant.id, story.id) end)
      assert claimed.agent_status == :assigned
      assert claimed.assigned_agent_id == ctx.runner.agent_id

      # The custody provenance an L4 gate compares against, which is the whole reason a
      # placement mints a dispatch rather than advancing the stage as the runner's key.
      assert claimed.implementer_dispatch_id
      leave_channel(channel)
    end

    test "no connected runner leaves the story queued for the next pass", ctx do
      story = bind_repo(ctx, queued_story(ctx))

      assert unboxed(fn -> DispatchDriver.run_with(20, @budgets) end) == [:no_runner]

      # UNTOUCHED, and that is the whole policy: no retry counter, no backoff, no memory. The
      # condition that blocked this story clears when a runner connects, and a driver that
      # marked it would be inventing a policy nobody asked for — and one nothing clears.
      row = unboxed(fn -> Stages.get(ctx.tenant.id, story.id) end)
      assert row.stage == :queued
      assert unboxed(fn -> reload(ctx.tenant.id, story.id) end).agent_status == :contracted
    end

    test "a story whose project has no intake source is unplaceable, and the pass goes on",
         ctx do
      # `MergePrecondition.repo_for_story/1` resolves the repository from the project's intake
      # source, and `fixture(:committed_story)` creates a project with none — so this is the
      # ordinary shape of a story the driver cannot address, not a contrived one. It must not
      # take the pass down with it.
      _unplaceable = queued_story(ctx)
      join_runner(ctx)

      assert unboxed(fn -> DispatchDriver.run_with(20, @budgets) end) == [:unplaceable]
    end
  end

  # -- helpers ---------------------------------------------------------------------------

  # BOTH repos on real connections — a placement writes through each of them, and the sandbox
  # gives them separate, mutually invisible transactions.
  defp unboxed(fun) do
    Sandbox.unboxed_run(AdminRepo, fn -> Sandbox.unboxed_run(Loopctl.Repo, fun) end)
  end

  # A story contracted and standing at `queued` — what a placement takes. Called OUTSIDE
  # `unboxed/1` for the reason `PlacementTest` records: `fixture(:committed_story)` checks out
  # its own unboxed connection, and nesting two `unboxed_run`s on the same repo checks the
  # connection back in at the inner block's end.
  defp queued_story(ctx), do: ctx |> triaged_story() |> queue()

  defp triaged_story(ctx) do
    story = fixture(:committed_story, %{tenant_id: ctx.tenant.id})

    unboxed(fn ->
      {:ok, story} =
        Progress.contract_story(ctx.tenant.id, story.id, %{},
          actor_label: "test",
          skip_contract_check: true
        )

      {:ok, _row} = Stages.open(ctx.tenant.id, story.id, actor_label: "test")

      {:ok, _} =
        Stages.advance(ctx.tenant.id, story.id, {:detected, :triaged},
          claim_epoch: story.claim_epoch
        )

      story
    end)
  end

  defp queue(story) do
    unboxed(fn ->
      {:ok, _} =
        Stages.advance(story.tenant_id, story.id, {:triaged, :queued},
          claim_epoch: story.claim_epoch
        )

      story
    end)
  end

  # The story's PROJECT bound to a repository, which is what `MergePrecondition.repo_for_story/1`
  # resolves a dispatch's `repo` from — `fixture(:committed_story)` creates a project with no
  # intake source, so a driver-placed story is unaddressable until this exists. Inserted rather
  # than taken from `fixture(:committed_intake, ...)`: that fixture makes its OWN project, and
  # the binding under test is the one between the story's project and a repository.
  defp bind_repo(ctx, story, repo \\ "mkreyman/home_care_billing") do
    now = DateTime.utc_now()

    unboxed(fn ->
      AdminRepo.insert!(%Source{
        tenant_id: ctx.tenant.id,
        project_id: story.project_id,
        repo_full_name: repo,
        webhook_secret: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
        inserted_at: now,
        updated_at: now
      })
    end)

    story
  end

  defp join_runner(ctx) do
    {:ok, socket} = connect(RunnerSocket, %{}, connect_info: connect_info(ctx.runner_key))

    {:ok, _reply, channel} =
      subscribe_and_join(socket, "runner:" <> ctx.runner.id, join_payload("minis"))

    # The join's own writes must be committed before the selection reads them.
    _ = :sys.get_state(channel.channel_pid)
    channel
  end

  # Unlinked first: `leave/1` shuts the channel down with `{:shutdown, :left}` and
  # `subscribe_and_join/3` linked it to this process, so the exit would take the test with it.
  defp leave_channel(channel) do
    Process.unlink(channel.channel_pid)
    leave(channel)
  end

  defp candidate_ids(limit) do
    unboxed(fn -> Enum.map(DispatchDriver.candidates(limit), & &1.story_id) end)
  end

  defp backdate(story_id, seconds) do
    at = DateTime.add(DateTime.utc_now(), seconds, :second) |> DateTime.truncate(:second)

    {1, _} =
      AdminRepo.update_all(from(s in StoryStage, where: s.story_id == ^story_id),
        set: [updated_at: DateTime.to_naive(at)]
      )
  end

  defp set_in_flight(runner_id, count) do
    {1, _} =
      AdminRepo.update_all(from(r in Runner, where: r.id == ^runner_id), set: [in_flight: count])
  end

  defp revoke(runner_id) do
    at = DateTime.utc_now() |> DateTime.truncate(:second)

    {1, _} =
      AdminRepo.update_all(from(r in Runner, where: r.id == ^runner_id), set: [revoked_at: at])
  end

  defp reload(tenant_id, story_id) do
    {:ok, story} = Stories.get_story(tenant_id, story_id)
    story
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
      "repos" => ["mkreyman/home_care_billing"],
      "max_sessions" => 2,
      "in_flight" => 0,
      "draining" => false
    }
  end
end
