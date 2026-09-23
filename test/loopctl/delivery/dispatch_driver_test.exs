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
  import ExUnit.CaptureLog

  require Logger

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Delivery.DispatchDriver
  alias Loopctl.Delivery.Placement
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Intake.Source
  alias Loopctl.Progress
  alias Loopctl.Runners.Capacity
  alias Loopctl.Runners.Runner
  alias Loopctl.Runners.Selection
  alias Loopctl.Runners.Usage
  alias Loopctl.WorkBreakdown.Stories
  alias LoopctlWeb.RunnerSocket

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  @reply_timeout 2_000
  @repo "mkreyman/home_care_billing"
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

    {raw, runner} =
      fixture(:committed_runner, %{tenant_id: tenant.id, name: "minis", max_sessions: 9})

    {_raw, _operator} = fixture(:committed_operator_key, %{tenant_id: tenant.id})

    %{tenant: tenant, runner: runner, runner_key: raw}
  end

  describe "candidates/1" do
    test "selects only stage rows at queued, oldest first, bounded", ctx do
      first = bind_repo(ctx, queued_story(ctx))
      second = bind_repo(ctx, queued_story(ctx))

      # The row that must NOT be a candidate, left at `triaged` by the machine rather than
      # moved by an UPDATE: the predicate is the stage, and a story one edge short of queued
      # is the nearest miss there is.
      triaged = bind_repo(ctx, triaged_story(ctx))

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

  describe "candidates/1 — the states a stage row alone cannot tell apart" do
    test "a RELEASED story is not a candidate, however long it sits at queued", ctx do
      story = bind_repo(ctx, queued_story(ctx))
      assert story.id in candidate_ids(50)

      # What every release does — the lease's `:runner_lost`, and `place/4`'s own undo on a
      # push refusal: the stage row goes back to `queued` and `agent_status` becomes
      # `:pending`. `Placement.place/4` refuses anything that is not `contracted`, and nothing
      # in lib/ re-contracts a story, so on the stage row alone this story was selected for
      # ever — with its `updated_at` frozen at the release, i.e. permanently at the head of an
      # oldest-first queue. Twenty of them and the driver never reached a placeable story
      # again, while every pass still reported a clean run.
      unboxed(fn ->
        {:ok, _} = Progress.force_unclaim_story(ctx.tenant.id, story.id, actor_label: "test")
      end)

      assert unboxed(fn -> Stages.get(ctx.tenant.id, story.id) end).stage == :queued
      assert unboxed(fn -> reload(ctx.tenant.id, story.id) end).agent_status == :pending
      refute story.id in candidate_ids(50)
    end

    test "the bound is shared FAIRLY: every tenant's oldest before any tenant's second", ctx do
      first = bind_repo(ctx, queued_story(ctx))
      second = bind_repo(ctx, queued_story(ctx))
      unboxed(fn -> backdate(first.id, -600) end)
      unboxed(fn -> backdate(second.id, -590) end)

      other = fixture(:committed_tenant, %{trust_tier: :human_anchored})
      other_ctx = %{ctx | tenant: other}
      other_story = bind_repo(other_ctx, queued_story(other_ctx))
      unboxed(fn -> backdate(other_story.id, -60) end)

      # On a plain global ordering the two oldest rows are BOTH the first tenant's, so a
      # tenant with a full queue consumed every slot of every pass and no other tenant's work
      # was ever looked at — the read is fleet-wide and the bound is one number for everybody.
      # Ranked per tenant, the newer tenant's only story is reached in the same pass.
      ids = candidate_ids(2)

      assert first.id in ids
      assert other_story.id in ids
      refute second.id in ids

      # And WITHIN a tenant it is still oldest-first, which is the half that cannot starve a
      # story: the second story arrives once every tenant's first has been taken.
      assert candidate_ids(3) == [first.id, other_story.id, second.id]
    end
  end

  describe "available_runner/2" do
    test "nil when the tenant has no connected runner", ctx do
      # The runner ROW exists — the fixture enrolled it — and nothing is joined. A selection
      # on the row alone would return it here and place work on a machine that is not there.
      assert unboxed(fn -> DispatchDriver.available_runner(ctx.tenant.id, @repo) end) == nil
    end

    test "the connected runner with a free slot", ctx do
      join_runner(ctx)

      assert %Runner{} =
               found = unboxed(fn -> DispatchDriver.available_runner(ctx.tenant.id, @repo) end)

      assert found.id == ctx.runner.id
    end

    test "nil when the connected runner is full", ctx do
      join_runner(ctx)
      unboxed(fn -> set_in_flight(ctx.runner.id, ctx.runner.max_sessions) end)

      # CONNECTED and useless. `place/4` would take the claim, mint a dispatch and be refused
      # `:runner_at_capacity` on the push, then undo all of it — an undo per attempt is not a
      # selection strategy, which is why capacity is read here and not discovered there.
      assert unboxed(fn -> DispatchDriver.available_runner(ctx.tenant.id, @repo) end) == nil
    end

    test "nil when the connected runner has been revoked", ctx do
      join_runner(ctx)
      unboxed(fn -> revoke(ctx.runner.id) end)

      # Revocation is what an operator does to stop a machine being used. A live socket does
      # not survive it as far as selection is concerned.
      assert unboxed(fn -> DispatchDriver.available_runner(ctx.tenant.id, @repo) end) == nil
    end

    test "nil when the connected runner is DRAINING", ctx do
      join_runner(ctx, %{"draining" => true})

      # `draining` means the runner accepts no new work, and nothing server-side read it
      # before this: `Runners.dispatch/3` leaves it to the runner, which refuses the push —
      # AFTER the claim has committed and after `dispatch/3` has already answered `:ok`. So an
      # operator draining a machine to stop new work got the work placed on it anyway, and the
      # story sat at `claimed` with no session until its lease expired.
      assert unboxed(fn -> DispatchDriver.available_runner(ctx.tenant.id, @repo) end) == nil
    end

    test "nil when the runner does not do this KIND", ctx do
      join_runner(ctx, %{"kinds" => ["triage"]})

      # Since 1.6.0 the runner's own declaration decides what it is sent, and `dispatch/3`
      # checks it — after the claim and after the session dispatch has been minted. A
      # triage-only runner therefore cost a `dispatches` row, an `api_keys` row and an
      # IMMUTABLE chain entry per candidate per minute, for a refusal that was knowable from
      # the join meta before anything was written.
      assert unboxed(fn -> DispatchDriver.available_runner(ctx.tenant.id, @repo) end) == nil
    end

    test "nil when the runner does not have this REPO checked out", ctx do
      join_runner(ctx, %{"repos" => ["mkreyman/cron_books"]})

      # Same shape as draining: the runner refuses `repo_not_allowed`, and the refusal arrives
      # too late to undo. Its declaration is on the join meta and says so beforehand.
      assert unboxed(fn -> DispatchDriver.available_runner(ctx.tenant.id, @repo) end) == nil

      # And the repo it DOES declare is placeable on the same connection, so this is the
      # declaration binding rather than the runner being excluded for some other reason.
      assert %Runner{} =
               unboxed(fn ->
                 DispatchDriver.available_runner(ctx.tenant.id, "mkreyman/cron_books")
               end)
    end

    test "the repo declaration is matched case-insensitively, as GitHub treats it", ctx do
      join_runner(ctx, %{"repos" => [String.upcase(@repo)]})

      # GitHub treats `owner/Repo` and `owner/repo` as ONE repository, and `Loopctl.Intake`
      # already compares them down-cased when it decides whether a webhook's repository is the
      # one a source is bound to. An exact comparison here answered "this runner does not have
      # that checkout" for a machine that plainly does — and for the driver that answer is
      # `:no_runner`, the one outcome that logs nothing at all, so the queue would simply stop
      # with no line anywhere saying why.
      assert %Runner{} = unboxed(fn -> DispatchDriver.available_runner(ctx.tenant.id, @repo) end)
    end

    test "nil when the TENANT is at its admission limit, even with a free slot on the row",
         ctx do
      join_runner(ctx)

      # The two limits are independent, and this is the state `RUNNER_MAX_IN_FLIGHT_SESSIONS`
      # exists to produce: the fixture runner has `max_sessions: 9`, so the row has free slots
      # while the tenant is at its fleet-wide cap. Checked only inside `Runners.dispatch/3`
      # before this, which is after the claim — so every pass took up to twenty
      # mint-claim-refuse-release cycles, each one a permanent chain entry.
      unboxed(fn -> set_in_flight(ctx.runner.id, Capacity.limit()) end)

      assert Capacity.limit() < ctx.runner.max_sessions
      assert unboxed(fn -> DispatchDriver.available_runner(ctx.tenant.id, @repo) end) == nil
    end

    test "nil for a tenant whose runner belongs to somebody else", ctx do
      join_runner(ctx)
      other = fixture(:committed_tenant, %{trust_tier: :human_anchored})

      # The presence pool is per tenant and so is the row read; this asserts they agree. A
      # name-keyed pool with a fleet-wide row read would place another tenant's work on this
      # machine the moment two tenants enrolled a runner called "minis".
      assert unboxed(fn -> DispatchDriver.available_runner(other.id, @repo) end) == nil
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
      bind_repo(ctx, queued_story(ctx), @repo)
      join_runner(ctx)

      assert unboxed(fn -> DispatchDriver.run(20) end) == {:ok, []}
    end
  end

  describe "run_with/2" do
    test "places a queued story on the connected runner", ctx do
      story = bind_repo(ctx, queued_story(ctx), @repo)
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
      assert pushed.branch == "feature/story-#{story.number}-#{String.slice(story.id, 0, 8)}"

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
      story = bind_repo(ctx, queued_story(ctx), @repo)

      assert unboxed(fn -> DispatchDriver.run_with(20, @budgets) end) == [:no_runner]

      # UNTOUCHED, and that is the whole policy: no retry counter, no backoff, no memory. The
      # condition that blocked this story clears when a runner connects, and a driver that
      # marked it would be inventing a policy nobody asked for — and one nothing clears.
      row = unboxed(fn -> Stages.get(ctx.tenant.id, story.id) end)
      assert row.stage == :queued
      assert unboxed(fn -> reload(ctx.tenant.id, story.id) end).agent_status == :contracted
    end

    test "the base branch comes from the SOURCE, not from a hardcoded master", ctx do
      bind_repo(ctx, queued_story(ctx), @repo, "main")
      channel = join_runner(ctx)

      assert unboxed(fn -> DispatchDriver.run_with(20, @budgets) end) == [:placed]
      assert_push "dispatch", pushed, @reply_timeout

      # GitHub has defaulted new repositories to `main` since 2020. Hardcoded, the dispatch
      # named a base branch that does not exist, and the failure arrives after the claim: the
      # runner refuses or cuts the worktree from the wrong ref, and the story comes back
      # `queued` + `:pending`, which nothing re-contracts.
      assert pushed.base_branch == "main"
      leave_channel(channel)
    end

    test "a tenant whose only operator key has EXPIRED is blocked, not placed", ctx do
      bind_repo(ctx, queued_story(ctx), @repo)
      join_runner(ctx)

      # Expiry is what key ROTATION uses (`Auth.expire_api_key/2`), so a rotated-out key is
      # expired and NOT revoked — and `Placement.resolve_caller/2` validates neither, so an
      # expired key here mints dispatches and drives custody transitions that the HTTP
      # pipeline would have 401'd. Made worse by the oldest-first ordering, which deliberately
      # picks the key most likely to have been rotated out.
      unboxed(fn -> expire_operator_keys(ctx.tenant.id) end)

      assert unboxed(fn -> DispatchDriver.run_with(20, @budgets) end) == [:blocked]
      refute_push "dispatch", _pushed
    end

    # 846.2 REVIEW FINDING 2. `Runners.accepts?/5` knows nothing about branch prefixes, so
    # `available_runner/2` selects this same machine on every pass and the placement fails the
    # same way each time. Classified `:unplaceable` it printed one INFO line a minute for ever
    # — "leaving for the next pass" — while its actual remedy is an operator editing
    # `branch_prefixes` on that box and reconnecting it, which is `blocked/2`'s own criterion:
    # a state that clears only when a person acts.
    test "a runner whose declared prefixes can produce no branch is BLOCKED, not unplaceable",
         ctx do
      bind_repo(ctx, queued_story(ctx), @repo)
      channel = join_runner(ctx, %{"branch_prefixes" => ["loop//"]})

      assert unboxed(fn -> DispatchDriver.run_with(20, @budgets) end) == [:blocked]
      refute_push "dispatch", _pushed
      leave_channel(channel)
    end

    # 846.2 REVIEW ROUND 2, FINDING 3. `Runners.accepts?/5` knows nothing about branch
    # prefixes, so a machine whose declaration can produce no valid branch is still
    # "accepting" — and is selected FIRST, because it is idle and this orders by fewest slots.
    # Every story for that repository then failed `no_conforming_branch` and the healthy second
    # runner was never tried: one misconfigured box stopped delivery for a whole repository,
    # which no placement could do before contract 1.14.0.
    #
    # The healthy runner is put at in_flight 1 so the ORDER is decided rather than left to a
    # UUID comparison: the broken one is genuinely first, which is the case under test.
    test "a misconfigured runner does not stop the repository — the next one is tried", ctx do
      story = bind_repo(ctx, queued_story(ctx), @repo)

      {healthy_key, healthy} =
        fixture(:committed_runner, %{tenant_id: ctx.tenant.id, name: "beelink", max_sessions: 9})

      unusable = join_runner(ctx, %{"branch_prefixes" => ["loop//"]})
      working = join_as(healthy, healthy_key, "beelink")
      unboxed(fn -> set_in_flight(healthy.id, 1) end)

      assert unboxed(fn -> DispatchDriver.run_with(20, @budgets) end) == [:placed]

      # Only the healthy machine can have produced this: the other one composes no valid name.
      assert_push "dispatch", pushed, @reply_timeout
      assert pushed.story_id == story.id
      assert pushed.branch == "feature/story-#{story.number}-#{String.slice(story.id, 0, 8)}"

      leave_channel(working)
      leave_channel(unusable)
    end

    # The classification survives the fan-out: when EVERY candidate is misconfigured the pass
    # still reports the state that needs a person, not a `:no_runner` that reads as "wait".
    test "with every runner misconfigured it is still BLOCKED, not no_runner", ctx do
      bind_repo(ctx, queued_story(ctx), @repo)

      {other_key, other} =
        fixture(:committed_runner, %{tenant_id: ctx.tenant.id, name: "beelink", max_sessions: 9})

      first = join_runner(ctx, %{"branch_prefixes" => ["loop//"]})
      second = join_as(other, other_key, "beelink", %{"branch_prefixes" => ["bad//"]})

      assert unboxed(fn -> DispatchDriver.run_with(20, @budgets) end) == [:blocked]
      refute_push "dispatch", _pushed

      leave_channel(second)
      leave_channel(first)
    end

    test "a story whose project has no intake source is not selected at all, and does not " <>
           "hold a slot in the batch",
         ctx do
      # It USED to be selected and reported `:blocked`, which was honest but was the same trap
      # the `contracted` predicate closed: a blocked story's `updated_at` never moves, so it
      # sat at the head of an oldest-first queue for ever and twenty of them filled every
      # pass's batch while the job still reported a clean run. Excluded in the PREDICATE, a
      # placeable story behind it is reached in the same pass.
      unaddressable = queued_story(ctx)
      placeable = bind_repo(ctx, queued_story(ctx), @repo)
      unboxed(fn -> backdate(unaddressable.id, -600) end)

      channel = join_runner(ctx)

      refute unaddressable.id in candidate_ids(50)
      assert unboxed(fn -> DispatchDriver.run_with(20, @budgets) end) == [:placed]
      assert_push "dispatch", pushed, @reply_timeout
      assert pushed.story_id == placeable.id
      leave_channel(channel)
    end

    test "a project bound to TWO active sources is not selected either", ctx do
      # Two sources name two repositories, so nothing can choose between them without choosing
      # a repository nobody nominated. Same exclusion and the same reason as none at all: it
      # is a configuration a person has to fix, and until they do it must not occupy the queue.
      ambiguous = bind_repo(ctx, queued_story(ctx), @repo)
      bind_repo(ctx, ambiguous, "mkreyman/cron_books")

      refute ambiguous.id in candidate_ids(50)
    end
  end

  describe "an exhausted subscription is not capacity (US-44.6)" do
    # The reset line is `:info`, below `config/test.exs`'s `:warning` primary level; a module
    # level lets it past for the module that logs it — `Selection.note_no_runner/3`, which both
    # passes share — the way `Loopctl.Workers.ReclaimExpiredClaimsLoggingTest` does. VM-global,
    # which this module's `async: false` already covers.
    setup do
      Logger.put_module_level(Selection, :info)
      on_exit(fn -> Logger.delete_module_level(Selection) end)
      :ok
    end

    test "an exhausted account is excluded everywhere: the driver places nothing, and a " <>
           "placement naming the OTHER machine on that account is refused (TC-44.6.5)",
         ctx do
      story = bind_repo(ctx, queued_story(ctx), @repo)

      {r2_key, r2} =
        fixture(:committed_runner, %{tenant_id: ctx.tenant.id, name: "beelink", max_sessions: 9})

      first = join_runner(ctx)
      second = join_as(r2, r2_key, "beelink")

      # r2 reported the account and NOTHING about it being exhausted; r1 ran it dry.
      unboxed(fn ->
        :ok = Usage.record(ctx.tenant.id, r2.id, %{exhausted: false, account_ref: "a"})
        :ok = Usage.record(ctx.tenant.id, ctx.runner.id, %{exhausted: true, account_ref: "a"})
      end)

      # Two connected machines with free slots, both refused: one ran dry, the other shares
      # its login. Before this every session placed on either ended `usage_exhausted`.
      assert unboxed(fn -> DispatchDriver.available_runners(ctx.tenant.id, @repo) end) == []
      assert unboxed(fn -> DispatchDriver.run_with(20, @budgets) end) == [:no_runner]
      refute_push "dispatch", _pushed

      {_raw, operator} = fixture(:committed_operator_key, %{tenant_id: ctx.tenant.id})

      assert {:error, :runner_exhausted} =
               unboxed(fn ->
                 Placement.place(
                   ctx.tenant.id,
                   r2.id,
                   %{"dispatch_id" => Ecto.UUID.generate(), "story_id" => story.id},
                   api_key: operator,
                   actor_label: "test"
                 )
               end)

      # NOTHING WAS CLAIMED — the refusal comes before the mint.
      assert unboxed(fn -> Stages.get(ctx.tenant.id, story.id) end).stage == :queued
      assert unboxed(fn -> reload(ctx.tenant.id, story.id) end).agent_status == :contracted

      leave_channel(second)
      leave_channel(first)
    end

    test "the pool shows the reset per runner, and the pass logs the earliest one, once per " <>
           "tenant (TC-44.6.7)",
         ctx do
      bind_repo(ctx, queued_story(ctx), @repo)
      # A second story the same exhausted runner is refused for (a repository is one active
      # source, so it is the runner's second checkout): `:no_runner` too, and the reset is
      # still logged ONCE for the tenant.
      bind_repo(ctx, queued_story(ctx), "mkreyman/cron_books")
      channel = join_runner(ctx, %{"repos" => [@repo, "mkreyman/cron_books"]})

      resets_at = DateTime.utc_now() |> DateTime.add(3_600, :second)

      unboxed(fn ->
        :ok = Usage.record(ctx.tenant.id, ctx.runner.id, %{exhausted: true, resets_at: resets_at})
      end)

      {operator_raw, _operator} = fixture(:committed_operator_key, %{tenant_id: ctx.tenant.id})

      assert %{"runners" => [entry]} =
               Phoenix.ConnTest.build_conn()
               |> Plug.Conn.put_req_header("authorization", "Bearer #{operator_raw}")
               |> Phoenix.ConnTest.dispatch(@endpoint, :get, "/api/v1/runners/pool")
               |> Phoenix.ConnTest.json_response(200)

      assert entry["runner_id"] == ctx.runner.id
      assert {:ok, shown, 0} = DateTime.from_iso8601(entry["usage_exhausted_until"])
      assert DateTime.compare(shown, resets_at) == :eq

      log =
        capture_log([level: :info], fn ->
          assert unboxed(fn -> DispatchDriver.run_with(20, @budgets) end) ==
                   [:no_runner, :no_runner]
        end)

      [line] =
        log |> String.split("\n") |> Enum.filter(&(&1 =~ "earliest_usage_reset="))

      [_, logged] = Regex.run(~r/earliest_usage_reset=(\S+)/, line)
      assert {:ok, logged, 0} = DateTime.from_iso8601(logged)
      assert DateTime.compare(logged, resets_at) == :eq

      leave_channel(channel)
    end

    test "a dry runner is never selected, even the least loaded: the story goes to the " <>
           "fresh one",
         ctx do
      story = bind_repo(ctx, queued_story(ctx), @repo)

      {r2_key, r2} =
        fixture(:committed_runner, %{tenant_id: ctx.tenant.id, name: "beelink", max_sessions: 9})

      dry = join_runner(ctx)
      fresh = join_as(r2, r2_key, "beelink")
      # The dry runner is the least loaded, so an order-only selection would try it FIRST.
      unboxed(fn -> set_in_flight(r2.id, 1) end)
      unboxed(fn -> :ok = Usage.record(ctx.tenant.id, ctx.runner.id, %{exhausted: true}) end)

      assert [%Runner{id: id}] =
               unboxed(fn -> DispatchDriver.available_runners(ctx.tenant.id, @repo) end)

      assert id == r2.id
      assert unboxed(fn -> DispatchDriver.run_with(20, @budgets) end) == [:placed]
      assert unboxed(fn -> Stages.get(ctx.tenant.id, story.id) end).stage == :claimed
      assert unboxed(fn -> AdminRepo.get!(Runner, ctx.runner.id) end).in_flight == 0

      leave_channel(fresh)
      leave_channel(dry)
    end

    test "the only runner going dry between selection and placement is :no_runner, with the " <>
           "note, and nothing is claimed",
         ctx do
      story = bind_repo(ctx, queued_story(ctx), @repo)
      channel = join_runner(ctx)

      log =
        capture_log([level: :info], fn ->
          assert exhaust_after_selection(ctx.runner.id, fn ->
                   unboxed(fn -> DispatchDriver.run_with(20, @budgets) end)
                 end) == [:no_runner]
        end)

      assert log =~ "earliest_usage_reset="
      refute_push "dispatch", _pushed
      assert unboxed(fn -> Stages.get(ctx.tenant.id, story.id) end).stage == :queued
      assert unboxed(fn -> AdminRepo.get!(Runner, ctx.runner.id) end).in_flight == 0

      leave_channel(channel)
    end

    test "an exhausted runner that is also FULL still names its reset: its slots are held by " <>
           "sessions about to end",
         ctx do
      bind_repo(ctx, queued_story(ctx), @repo)
      channel = join_runner(ctx)
      resets_at = DateTime.add(DateTime.utc_now(), 3_600, :second)

      # ONE slot, taken: full, and still under the tenant's admission cap. On the row rather
      # than declared at join: a join that lowers `max_sessions` writes through the sandbox,
      # whose uncommitted row lock the unboxed writes below would wait out.
      unboxed(fn ->
        :ok = Usage.record(ctx.tenant.id, ctx.runner.id, %{exhausted: true, resets_at: resets_at})

        {1, _} =
          AdminRepo.update_all(from(r in Runner, where: r.id == ^ctx.runner.id),
            set: [max_sessions: 1, in_flight: 1]
          )
      end)

      log =
        capture_log([level: :info], fn ->
          assert unboxed(fn -> DispatchDriver.run_with(20, @budgets) end) == [:no_runner]
        end)

      [_, logged] = Regex.run(~r/earliest_usage_reset=(\S+)/, log)
      assert {:ok, logged, 0} = DateTime.from_iso8601(logged)
      assert DateTime.compare(logged, resets_at) == :eq

      leave_channel(channel)
    end

    test "another tenant's exhausted runner on the same account_ref does not hold this " <>
           "tenant's runner out (TC-44.6.8)",
         ctx do
      story = bind_repo(ctx, queued_story(ctx), @repo)

      other = fixture(:committed_tenant, %{trust_tier: :human_anchored})
      {_raw, theirs} = fixture(:committed_runner, %{tenant_id: other.id, name: "minis"})

      unboxed(fn ->
        :ok = Usage.record(other.id, theirs.id, %{exhausted: true, account_ref: "a"})
        :ok = Usage.record(ctx.tenant.id, ctx.runner.id, %{exhausted: false, account_ref: "a"})
      end)

      channel = join_runner(ctx)

      assert unboxed(fn -> DispatchDriver.run_with(20, @budgets) end) == [:placed]
      assert_push "dispatch", pushed, @reply_timeout
      assert pushed.story_id == story.id

      leave_channel(channel)
    end
  end

  # -- helpers ---------------------------------------------------------------------------

  # Runs `fun` with `runner_id` exhausted the moment the pass has SELECTED its runners (the
  # free-slot query, on AdminRepo) and before it places on one: a machine running dry between
  # the selection and the push. Written on AdminRepo's own connection, so it commits outside
  # the read.
  defp exhaust_after_selection(runner_id, fun) do
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        id,
        [:loopctl, :admin_repo, :query],
        &__MODULE__.exhaust_after_select/4,
        %{pid: self(), id: id, runner_id: runner_id}
      )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end
  end

  @doc false
  def exhaust_after_select(_event, _measurements, %{query: query}, config) do
    %{pid: pid, id: id, runner_id: runner_id} = config

    if self() == pid and query =~ ~r/^SELECT .*"in_flight" < .*exists\(/s do
      :telemetry.detach(id)
      until = DateTime.add(DateTime.utc_now(), 3_600, :second)

      {1, _} =
        AdminRepo.update_all(from(r in Runner, where: r.id == ^runner_id),
          set: [usage_exhausted_until: until]
        )
    end
  end

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
  # A UNIQUE repository by default, because `intake_sources_active_repo_uidx` allows one
  # ACTIVE source per repository per tenant — so two stories in two projects of one tenant
  # cannot both be bound to the same repo. The placing tests pass `@repo` explicitly, since
  # that is the one the joined runner declares.
  defp bind_repo(ctx, story, repo \\ nil, base_branch \\ "master") do
    repo = repo || "mkreyman/repo-#{System.unique_integer([:positive])}"

    now = DateTime.utc_now()

    unboxed(fn ->
      AdminRepo.insert!(%Source{
        tenant_id: ctx.tenant.id,
        project_id: story.project_id,
        repo_full_name: repo,
        base_branch: base_branch,
        webhook_secret: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
        inserted_at: now,
        updated_at: now
      })
    end)

    story
  end

  defp join_runner(ctx, overrides \\ %{}) do
    {:ok, socket} = connect(RunnerSocket, %{}, connect_info: connect_info(ctx.runner_key))

    {:ok, _reply, channel} =
      subscribe_and_join(
        socket,
        "runner:" <> ctx.runner.id,
        Map.merge(join_payload("minis"), overrides)
      )

    # The join's own writes must be committed before the selection reads them.
    _ = :sys.get_state(channel.channel_pid)
    channel
  end

  # `join_runner/2` for a runner other than the one `setup` made, so a test can put two
  # machines in the pool.
  defp join_as(runner, key, machine, overrides \\ %{}) do
    {:ok, socket} = connect(RunnerSocket, %{}, connect_info: connect_info(key))

    {:ok, _reply, channel} =
      subscribe_and_join(
        socket,
        "runner:" <> runner.id,
        Map.merge(join_payload(machine), overrides)
      )

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

  defp expire_operator_keys(tenant_id) do
    past = DateTime.utc_now() |> DateTime.add(-60, :second)

    {count, _} =
      AdminRepo.update_all(
        from(k in Loopctl.Auth.ApiKey, where: k.tenant_id == ^tenant_id and k.role == :user),
        set: [expires_at: past]
      )

    # Non-vacuous: a tenant with no operator key at all would be blocked for a different
    # reason and this test would pass without expiry having anything to do with it.
    assert count > 0
    count
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
      "repos" => [@repo],
      "max_sessions" => 9,
      "in_flight" => 0,
      "draining" => false
    }
  end
end
