defmodule Loopctl.Agents.BuildDispatcherTest do
  @moduledoc """
  US-48.7: the implement pass runs from `implement@1` (`Loopctl.Agents.Dispatcher.run/2`, the
  `:build` archetype).

  ## The equivalence tests are a RECORDING of the pass before it moved

  Every literal below — each outcome list, each tally the worker's summary line prints, each
  log line, each pushed dispatch — was captured from `Loopctl.Delivery.DispatchDriver.run_with/2`
  BEFORE its body moved onto the spec, on the fixed corpus `corpus/1` builds. None is derived
  from the code under test, so a change to the spec-driven pass that alters a byte of a pushed
  dispatch, the order of a pass, an outcome or a log line fails here.

  The values that differ per run (ids, story numbers and titles, the claim's lease cap) are read
  from the rows the corpus wrote; everything else is literal. `dispatch_id` is random by design
  (a fresh one per attempt) and is compared for shape only.

  ## What the corpus records about the old pass that is easy to get wrong

  - A runner holds ONE placement at a time: its agent may carry one active key per role
    (`api_keys_one_role_per_agent_idx`), and the session dispatch's ephemeral key takes it. So
    a second story for the same machine in the same pass is `:unplaceable`, reason the mint's
    changeset — which is why the corpus spreads its placeable stories over two runners.
  - A source whose `base_branch` is not a ref is `:unplaceable` (`DispatchPayload.fill/3`'s
    `validate_refs/2`, before anything is minted), NOT `:blocked`: the `:build` pass does not
    judge the ref itself, unlike the `:judge` pass.
  - No runner is decided before the operator key, so a tenant with no usable key still reports
    `:no_runner` for a story no machine takes.
  """

  use LoopctlWeb.ChannelCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Agents.Dispatcher
  alias Loopctl.Agents.Specs.ImplementV1
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Delivery.DispatchDriver
  alias Loopctl.Delivery.Stages
  alias Loopctl.Intake.Source
  alias Loopctl.OwnLog
  alias Loopctl.Progress
  alias Loopctl.Runners.Usage
  alias Loopctl.WorkBreakdown.Stories
  alias Loopctl.Workers.DispatchDriverWorker
  alias LoopctlWeb.RunnerSocket

  setup :verify_on_exit!

  @reply_timeout 2_000
  @budgets %{wall_clock_seconds: 3_600, max_turns: 50}
  @repo "mkreyman/home_care_billing"
  @repo_main "mkreyman/cron_books"
  @repo_legacy "mkreyman/legacy"
  @repo_elsewhere "mkreyman/nobody_takes_this"

  setup do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    {raw, runner} = fixture(:runner, %{tenant_id: tenant.id, name: "minis", max_sessions: 9})

    {second_raw, second} =
      fixture(:runner, %{tenant_id: tenant.id, name: "beelink", max_sessions: 9})

    {_raw, _operator} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

    %{
      tenant: tenant,
      runner: runner,
      runner_key: raw,
      second: second,
      second_key: second_raw
    }
  end

  # Through BOTH entry points: `DispatchDriver.run_with/2`, the wrapper every existing caller
  # and test reaches the pass by, and `Dispatcher.run/2` with `implement@1`, which is what the
  # cron worker calls.
  for path <- [:driver_wrapper, :dispatcher] do
    describe "the spec-driven pass equals the recorded one, through #{path} (AC-48.7.2)" do
      test "TC-48.7.1, two runners: identical outcomes, log lines and pushed dispatches", ctx do
        corpus = corpus(ctx)
        minis = join_as(ctx.runner, ctx.runner_key, "minis", [@repo, @repo_legacy])
        beelink = join_as(ctx.second, ctx.second_key, "beelink", [@repo_main])

        {outcomes, log} = run_recorded(ctx, unquote(path))

        assert outcomes == [:placed, :placed, :unplaceable, :no_runner]
        assert_summary(outcomes, %{placed: 2, unplaceable: 1, no_runner: 1})

        assert log =~
                 "[info] DispatchDriver: leaving for the next pass: " <>
                   "story_id=#{corpus.legacy.id} " <>
                   "reason={:invalid_branch_name, :base_branch, \"--upload-pack=/bin/sh\"}"

        pushed = collect_pushed(2)
        assert_pushed(ctx, pushed[corpus.plain.id], corpus.plain, @repo, "master")
        assert_pushed(ctx, pushed[corpus.main_base.id], corpus.main_base, @repo_main, "main")

        # The custody provenance the claim wrote, which every L4 gate compares against.
        assert_claimed(ctx, corpus.plain, ctx.runner)
        assert_claimed(ctx, corpus.main_base, ctx.second)

        for story <- [corpus.legacy, corpus.elsewhere], do: assert_untouched(ctx, story)

        leave_channel(beelink)
        leave_channel(minis)
      end

      test "TC-48.7.1, one runner taking every repository: the second placement is refused " <>
             "by the agent's key slot",
           ctx do
        corpus = corpus(ctx)
        minis = join_as(ctx.runner, ctx.runner_key, "minis", [@repo, @repo_main, @repo_legacy])

        {outcomes, log} = run_recorded(ctx, unquote(path))

        assert outcomes == [:placed, :unplaceable, :unplaceable, :no_runner]
        assert_summary(outcomes, %{placed: 1, unplaceable: 2, no_runner: 1})

        assert log =~
                 "[info] DispatchDriver: leaving for the next pass: " <>
                   "story_id=#{corpus.main_base.id} reason=#Ecto.Changeset<"

        assert log =~ "agent already has an active key with this role"

        pushed = collect_pushed(1)
        assert_pushed(ctx, pushed[corpus.plain.id], corpus.plain, @repo, "master")
        assert_untouched(ctx, corpus.main_base)

        leave_channel(minis)
      end

      test "TC-48.7.1, no runner: every candidate is :no_runner and nothing is pushed", ctx do
        corpus = corpus(ctx)

        {outcomes, _log} = run_recorded(ctx, unquote(path))

        assert outcomes == [:no_runner, :no_runner, :no_runner, :no_runner]
        assert_summary(outcomes, %{no_runner: 4})
        refute_push "dispatch", _pushed

        for story <- Map.values(corpus), do: assert_untouched(ctx, story)
      end

      test "TC-48.7.1, an exhausted runner: :no_runner, and the reset is noted once", ctx do
        corpus = corpus(ctx)
        minis = join_as(ctx.runner, ctx.runner_key, "minis", [@repo, @repo_main, @repo_legacy])
        resets_at = DateTime.add(DateTime.utc_now(), 3_600, :second)
        :ok = Usage.record(ctx.tenant.id, ctx.runner.id, %{exhausted: true, resets_at: resets_at})

        {outcomes, log} = run_recorded(ctx, unquote(path))

        assert outcomes == [:no_runner, :no_runner, :no_runner, :no_runner]
        assert_summary(outcomes, %{no_runner: 4})
        refute_push "dispatch", _pushed

        assert [line] =
                 log |> String.split("\n") |> Enum.filter(&(&1 =~ "earliest_usage_reset="))

        assert line =~
                 "[info] DispatchDriver: no runner for story_id=#{corpus.plain.id}; " <>
                   "1 exhausted runner(s) in tenant; earliest_usage_reset="

        leave_channel(minis)
      end

      test "TC-48.7.1, no usable operator key: :blocked, logged at ERROR", ctx do
        corpus = corpus(ctx)
        minis = join_as(ctx.runner, ctx.runner_key, "minis", [@repo, @repo_legacy])
        beelink = join_as(ctx.second, ctx.second_key, "beelink", [@repo_main])
        expire_operator_keys(ctx.tenant.id)

        {outcomes, log} = run_recorded(ctx, unquote(path))

        assert outcomes == [:blocked, :blocked, :blocked, :no_runner]
        assert_summary(outcomes, %{blocked: 3, no_runner: 1})

        assert log =~
                 "[error] DispatchDriver: BLOCKED until somebody changes something — this " <>
                   "will not clear by itself: story_id=#{corpus.plain.id} reason=:no_operator_key"

        refute_push "dispatch", _pushed
        for story <- Map.values(corpus), do: assert_untouched(ctx, story)

        leave_channel(beelink)
        leave_channel(minis)
      end

      test "TC-48.7.1, a misconfigured runner first: the pass advances to the next one", ctx do
        corpus = corpus(ctx)

        broken =
          join_as(ctx.runner, ctx.runner_key, "minis", [@repo, @repo_main, @repo_legacy], %{
            "branch_prefixes" => ["loop//"]
          })

        healthy =
          join_as(ctx.second, ctx.second_key, "beelink", [@repo, @repo_main, @repo_legacy])

        # The broken machine is the less loaded one, so it is tried FIRST.
        set_in_flight(ctx.second.id, 1)

        {outcomes, log} = run_recorded(ctx, unquote(path))

        assert outcomes == [:placed, :unplaceable, :unplaceable, :no_runner]
        assert_summary(outcomes, %{placed: 1, unplaceable: 2, no_runner: 1})

        assert log =~
                 "[info] DispatchDriver: leaving for the next pass: " <>
                   "story_id=#{corpus.main_base.id} reason=#Ecto.Changeset<"

        pushed = collect_pushed(1)
        assert_pushed(ctx, pushed[corpus.plain.id], corpus.plain, @repo, "master")
        assert_claimed(ctx, corpus.plain, ctx.second)

        leave_channel(healthy)
        leave_channel(broken)
      end

      test "TC-48.7.1, every runner misconfigured: :blocked on the machine's declaration", ctx do
        corpus = corpus(ctx)

        broken =
          join_as(ctx.runner, ctx.runner_key, "minis", [@repo, @repo_main], %{
            "branch_prefixes" => ["loop//"]
          })

        {outcomes, log} = run_recorded(ctx, unquote(path))

        assert outcomes == [:blocked, :blocked, :no_runner, :no_runner]
        assert_summary(outcomes, %{blocked: 2, no_runner: 2})

        assert log =~
                 "[error] DispatchDriver: BLOCKED until somebody changes something — this " <>
                   "will not clear by itself: story_id=#{corpus.plain.id} " <>
                   "reason={:no_conforming_branch, [\"loop//\"]}"

        refute_push "dispatch", _pushed
        leave_channel(broken)
      end
    end
  end

  describe "the :dispatch_driver_enabled switch and the budgets" do
    test "off, the pass places NOTHING", ctx do
      corpus = corpus(ctx)
      minis = join_as(ctx.runner, ctx.runner_key, "minis", [@repo])

      assert Dispatcher.run(ImplementV1.spec(), limit: 20, budgets: @budgets, enabled?: false) ==
               {:ok, []}

      refute_push "dispatch", _pushed
      for story <- Map.values(corpus), do: assert_untouched(ctx, story)

      leave_channel(minis)
    end

    test "the default reads the configured switch, which is off in test; so does the driver",
         ctx do
      _corpus = corpus(ctx)
      minis = join_as(ctx.runner, ctx.runner_key, "minis", [@repo])

      assert Dispatcher.run(ImplementV1.spec(), limit: 20) == {:ok, []}
      assert DispatchDriver.run(20) == {:ok, []}
      refute_push "dispatch", _pushed

      leave_channel(minis)
    end

    test "the worker, off: a clean job and nothing placed", ctx do
      _corpus = corpus(ctx)
      minis = join_as(ctx.runner, ctx.runner_key, "minis", [@repo])

      assert DispatchDriverWorker.perform(%Oban.Job{args: %{}}) == :ok
      refute_push "dispatch", _pushed

      leave_channel(minis)
    end

    test "on, with implement@1's budget keys unset, the first unset key is named" do
      assert Dispatcher.run(ImplementV1.spec(), limit: 20, enabled?: true) ==
               {:error, {:unset, :dispatch_wall_clock_seconds}}

      assert DispatchDriver.budgets() == Dispatcher.budgets(ImplementV1.spec())
    end
  end

  # How each answer of `Placement.place/4` is classified, reached through the `:place` input
  # with a runner the selection admits. One candidate per test, so the outcome list is its
  # outcome.
  describe "classification of Placement.place/4's answer" do
    setup ctx do
      story = bind_repo(ctx, queued_story(ctx), @repo, "master")
      _minis = join_as(ctx.runner, ctx.runner_key, "minis", [@repo])
      %{story: story}
    end

    for reason <- [
          :no_operator_key,
          :tenant_halted,
          :custody_tier_required,
          {:no_intake_source, "p"},
          {:ambiguous_intake_source, "p", 2},
          {:no_conforming_branch, ["loop//"]}
        ] do
      test "{:error, #{inspect(reason)}} is :blocked, logged at ERROR", ctx do
        reason = unquote(Macro.escape(reason))

        log =
          OwnLog.capture_naming(ctx.story.id, [level: :info], fn ->
            send(self(), {:outcomes, pass_answering(fn -> {:error, reason} end)})
          end)

        assert_received {:outcomes, [:blocked]}

        assert log =~
                 "DispatchDriver: BLOCKED until somebody changes something — this will not " <>
                   "clear by itself: story_id=#{ctx.story.id} reason=#{inspect(reason)}"
      end
    end

    for reason <- [
          :invalid_transition,
          :wrong_stage,
          :dependencies_not_met,
          :runner_declines_work
        ] do
      test "{:error, #{inspect(reason)}} is :unplaceable, logged at info", ctx do
        reason = unquote(reason)

        log =
          OwnLog.capture_naming(ctx.story.id, [level: :info], fn ->
            send(self(), {:outcomes, pass_answering(fn -> {:error, reason} end)})
          end)

        assert_received {:outcomes, [:unplaceable]}

        assert log =~
                 "DispatchDriver: leaving for the next pass: story_id=#{ctx.story.id} " <>
                   "reason=#{inspect(reason)}"
      end
    end

    test "{:error, :runner_exhausted} on the only runner is :no_runner" do
      assert pass_answering(fn -> {:error, :runner_exhausted} end) == [:no_runner]
    end

    test "a placement that RAISES is :errored, and the pass goes on", ctx do
      log =
        OwnLog.capture_naming(ctx.story.id, [level: :info], fn ->
          send(self(), {:outcomes, pass_answering(fn -> raise "boom" end)})
        end)

      assert_received {:outcomes, [:errored]}

      assert log =~
               "DispatchDriver: candidate failed, continuing with the rest of the pass: " <>
                 "story_id=#{ctx.story.id}"
    end

    test "a placement that THROWS is :errored" do
      ExUnit.CaptureLog.capture_log(fn ->
        send(self(), {:outcomes, pass_answering(fn -> throw(:boom) end)})
      end)

      assert_received {:outcomes, [:errored]}
    end

    # The identity `place/4` is handed is the pass's own resolution — the tenant's oldest live
    # unlineaged user key — and the actor is the driver's: neither is an input of `run/2`.
    test "place/4 is handed the tenant's operator key, the driver's actor and the dispatch the " <>
           "caller owns",
         ctx do
      test = self()

      {:ok, [:placed]} =
        Dispatcher.run(ImplementV1.spec(),
          limit: 20,
          budgets: @budgets,
          enabled?: true,
          place: fn tenant_id, runner_id, dispatch, opts ->
            send(test, {:placed, tenant_id, runner_id, dispatch, opts})
            {:ok, %{}}
          end
        )

      assert_received {:placed, tenant_id, runner_id, dispatch, opts}
      assert tenant_id == ctx.tenant.id
      assert runner_id == ctx.runner.id

      operator =
        AdminRepo.one!(
          from k in Loopctl.Auth.ApiKey,
            where: k.tenant_id == ^ctx.tenant.id and k.role == :user,
            order_by: [asc: k.inserted_at],
            limit: 1
        )

      assert Keyword.fetch!(opts, :api_key).id == operator.id
      assert Keyword.fetch!(opts, :actor_label) == "worker:dispatch_driver"
      assert Enum.sort(Keyword.keys(opts)) == [:actor_label, :api_key]

      # The map the old `dispatch/3` built, literally: no `branch` (place/4 derives it from the
      # target runner's declaration) and no `story` (place/4 builds it and refuses a caller's).
      assert %{"dispatch_id" => dispatch_id} = dispatch
      assert {:ok, _} = Ecto.UUID.cast(dispatch_id)

      assert Map.delete(dispatch, "dispatch_id") === %{
               "story_id" => ctx.story.id,
               "kind" => "implement",
               "repo" => @repo,
               "base_branch" => "master",
               "wall_clock_seconds" => 3_600,
               "max_turns" => 50
             }
    end

    test "an advance_on the spec does not name stops at the first runner", ctx do
      _beelink = join_as(ctx.second, ctx.second_key, "beelink", [@repo])
      spec = %{ImplementV1.spec() | advance_on: []}
      test = self()

      {{:ok, outcomes}, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          Dispatcher.run(spec,
            limit: 20,
            budgets: @budgets,
            enabled?: true,
            place: fn _tenant_id, runner_id, _dispatch, _opts ->
              send(test, {:tried, runner_id})
              {:error, {:no_conforming_branch, ["loop//"]}}
            end
          )
        end)

      assert outcomes == [:blocked]
      assert_received {:tried, _first}
      refute_received {:tried, _second}
    end

    test "implement@1's advance_on tries every selected runner", ctx do
      _beelink = join_as(ctx.second, ctx.second_key, "beelink", [@repo])
      test = self()

      {{:ok, outcomes}, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          Dispatcher.run(ImplementV1.spec(),
            limit: 20,
            budgets: @budgets,
            enabled?: true,
            place: fn _tenant_id, runner_id, _dispatch, _opts ->
              send(test, {:tried, runner_id})
              {:error, {:no_conforming_branch, ["loop//"]}}
            end
          )
        end)

      assert outcomes == [:blocked]
      assert_received {:tried, first}
      assert_received {:tried, second}
      assert Enum.sort([first, second]) == Enum.sort([ctx.runner.id, ctx.second.id])
    end
  end

  describe "run/2 over a spec the :build pass cannot run" do
    test "a :build spec naming a part the pass has no clause for is refused, naming it" do
      implement = ImplementV1.spec()

      for {spec, named} <- [
            {%{implement | payload: :triage_payload}, ~r/payload: \[:triage_payload\]/},
            {%{implement | sweeps: %{stranded_triaged_unbound: []}},
             ~r/sweeps: \[:stranded_triaged_unbound\]/}
          ] do
        assert_raise ArgumentError, named, fn ->
          Dispatcher.run(spec, limit: 20, budgets: @budgets, enabled?: true)
        end
      end
    end

    test "a :draft spec is refused before anything is read" do
      spec = %{ImplementV1.spec() | archetype: :draft}

      assert_raise ArgumentError, ~r/implement@1 is a :draft spec/, fn ->
        Dispatcher.run(spec, limit: 20, budgets: @budgets, enabled?: true)
      end
    end
  end

  defp pass_answering(answer) do
    {:ok, outcomes} =
      Dispatcher.run(ImplementV1.spec(),
        limit: 20,
        budgets: @budgets,
        enabled?: true,
        place: fn _tenant_id, _runner_id, _dispatch, _opts -> answer.() end
      )

    outcomes
  end

  # -- the pass under test ----------------------------------------------------------------

  defp run_recorded(ctx, path) do
    log =
      OwnLog.capture_naming(ctx.tenant.id, [level: :info], fn ->
        send(self(), {:outcomes, run_path(path)})
      end)

    assert_received {:outcomes, outcomes}
    {outcomes, log}
  end

  defp run_path(:driver_wrapper), do: DispatchDriver.run_with(20, @budgets)

  defp run_path(:dispatcher) do
    {:ok, outcomes} =
      Dispatcher.run(ImplementV1.spec(), limit: 20, budgets: @budgets, enabled?: true)

    outcomes
  end

  # The worker's summary is `inspect/1` of `Enum.frequencies/1`; the tally is the recorded
  # literal.
  defp assert_summary(outcomes, recorded_tally),
    do: assert(Enum.frequencies(outcomes) == recorded_tally)

  defp collect_pushed(count) do
    for _ <- 1..count, into: %{} do
      assert_push "dispatch", pushed, @reply_timeout
      {pushed.story_id, pushed}
    end
  end

  # BYTE-IDENTICAL, `dispatch_id` aside: strict equality on the whole map the socket received.
  defp assert_pushed(ctx, pushed, story, repo, base_branch) do
    assert %{dispatch_id: dispatch_id} = pushed
    assert {:ok, _} = Ecto.UUID.cast(dispatch_id)

    claimed = reload(ctx.tenant.id, story.id)

    expected = %{
      kind: "implement",
      branch: "feature/story-#{story.number}-#{String.slice(story.id, 0, 8)}",
      repo: repo,
      story_id: story.id,
      claim_epoch: 1,
      wall_clock_seconds: 3600,
      story: %{
        id: story.id,
        description: "Test story description",
        title: story.title
      },
      base_branch: base_branch,
      max_turns: 50,
      deadline_at: claimed.claim_lease_cap
    }

    assert Map.delete(pushed, :dispatch_id) === expected
  end

  defp assert_claimed(ctx, story, runner) do
    claimed = reload(ctx.tenant.id, story.id)
    assert claimed.agent_status == :assigned
    assert claimed.assigned_agent_id == runner.agent_id
    assert is_binary(claimed.implementer_dispatch_id)

    row = Stages.get(ctx.tenant.id, story.id)
    assert row.stage == :claimed
    assert row.runner_id == runner.id
  end

  defp assert_untouched(ctx, story) do
    assert Stages.get(ctx.tenant.id, story.id).stage == :queued
    unclaimed = reload(ctx.tenant.id, story.id)
    assert unclaimed.agent_status == :contracted
    assert unclaimed.assigned_agent_id == nil
    assert unclaimed.implementer_dispatch_id == nil
  end

  # -- the corpus ------------------------------------------------------------------------

  # FOUR stories under one tenant, each on its own project, at fixed relative ages so the
  # round-robin ranking is deterministic:
  #
  #   * `plain` — a source on `master`;
  #   * `main_base` — a source on `main`;
  #   * `legacy` — a source whose `base_branch` predates the git-ref validation;
  #   * `elsewhere` — a repository no runner declares.
  defp corpus(ctx) do
    plain = bind_repo(ctx, queued_story(ctx), @repo, "master")
    main_base = bind_repo(ctx, queued_story(ctx), @repo_main, "main")
    legacy = bind_repo(ctx, queued_story(ctx), @repo_legacy, "--upload-pack=/bin/sh")
    elsewhere = bind_repo(ctx, queued_story(ctx), @repo_elsewhere, "master")

    [plain, main_base, legacy, elsewhere]
    |> Enum.with_index()
    |> Enum.each(fn {story, i} -> backdate(story.id, -600 + i * 60) end)

    %{plain: plain, main_base: main_base, legacy: legacy, elsewhere: elsewhere}
  end

  defp queued_story(ctx) do
    story = fixture(:ledger_story, %{tenant_id: ctx.tenant.id})

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

    {:ok, _} =
      Stages.advance(ctx.tenant.id, story.id, {:triaged, :queued}, claim_epoch: story.claim_epoch)

    story
  end

  defp bind_repo(ctx, story, repo, base_branch) do
    now = DateTime.utc_now()

    AdminRepo.insert!(%Source{
      tenant_id: ctx.tenant.id,
      project_id: story.project_id,
      repo_full_name: repo,
      base_branch: base_branch,
      webhook_secret: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
      inserted_at: now,
      updated_at: now
    })

    story
  end

  defp backdate(story_id, seconds) do
    at = DateTime.add(DateTime.utc_now(), seconds, :second) |> DateTime.truncate(:second)

    {1, _} =
      AdminRepo.update_all(
        from(s in Loopctl.Delivery.StoryStage, where: s.story_id == ^story_id),
        set: [updated_at: DateTime.to_naive(at)]
      )
  end

  defp set_in_flight(runner_id, count) do
    {1, _} =
      AdminRepo.update_all(from(r in Loopctl.Runners.Runner, where: r.id == ^runner_id),
        set: [in_flight: count]
      )
  end

  defp expire_operator_keys(tenant_id) do
    past = DateTime.utc_now() |> DateTime.add(-60, :second)

    {count, _} =
      AdminRepo.update_all(
        from(k in Loopctl.Auth.ApiKey, where: k.tenant_id == ^tenant_id and k.role == :user),
        set: [expires_at: past]
      )

    assert count > 0
  end

  defp reload(tenant_id, story_id) do
    {:ok, story} = Stories.get_story(tenant_id, story_id)
    story
  end

  defp join_as(runner, key, machine, repos, overrides \\ %{}) do
    {:ok, socket} = connect(RunnerSocket, %{}, connect_info: connect_info(key))

    {:ok, _reply, channel} =
      subscribe_and_join(
        socket,
        "runner:" <> runner.id,
        Map.merge(join_payload(machine, repos), overrides)
      )

    _ = :sys.get_state(channel.channel_pid)
    channel
  end

  defp leave_channel(channel) do
    Process.unlink(channel.channel_pid)
    leave(channel)
  end

  defp connect_info(token) do
    %{
      x_headers: [{RunnerSocket.token_header(), token}],
      peer_data: %{address: {127, 0, 0, 1}, port: 40_000, ssl_cert: nil}
    }
  end

  defp join_payload(machine, repos) do
    %{
      "contract_version" => RunnerContract.version(),
      "machine" => machine,
      "cores" => 16,
      "memory_mb" => 28_000,
      "repos" => repos,
      "max_sessions" => 9,
      "in_flight" => 0,
      "draining" => false
    }
  end
end
