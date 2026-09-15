defmodule Loopctl.Delivery.TriageDispatcherTest do
  @moduledoc """
  The hop between intake and everything else (#803 §4): a story the loop has DETECTED is sent
  to a runner to be triaged.

  `async: false` and COMMITTED, for the reason `Loopctl.Delivery.PlacementTest` records: the
  push goes through a real runner socket, whose channel process cannot see a sandbox
  connection's uncommitted rows.

  Every selection test binds a fact the pass reads. What is NOT tested here is the
  configuration gate — `:dispatch_driver_enabled` is false in every environment and this repo
  forbids `Application.put_env` — so `run/1`'s gate is asserted in the only state a test can
  observe and the work is reached through `run_with/2`.
  """

  use LoopctlWeb.ChannelCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.TriageDispatcher
  alias Loopctl.Progress
  alias LoopctlWeb.RunnerSocket

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  @reply_timeout 2_000
  @budgets %{wall_clock_seconds: 900, max_turns: 30}

  setup do
    sweep_committed_runner_tenants()

    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})

    {raw, runner} =
      fixture(:committed_runner, %{tenant_id: tenant.id, name: "minis", max_sessions: 9})

    %{tenant: tenant, runner: runner, runner_key: raw}
  end

  describe "candidates/1" do
    test "selects stories at DETECTED that came from an intake record", ctx do
      detected = detected_story(ctx)
      no_record = detected_story(ctx, intake_record: false)
      queued = detected_story(ctx) |> queue()

      ids = candidate_ids(50)

      assert detected.id in ids

      # The triage payload IS the reporter's words, so a story with no intake record has
      # nothing to triage: dispatched anyway it would carry an empty object, and the session
      # would be asked to judge a ticket it cannot read. Backfills and API-created stories are
      # that shape, and they are not this loop's work.
      refute no_record.id in ids

      # And a story already past `detected` is somebody else's business — the driver's, at
      # `queued`.
      refute queued.id in ids
    end
  end

  describe "run_with/2" do
    test "sends a triage dispatch to a runner that DECLARES the kind", ctx do
      story = detected_story(ctx)
      record_id = reload_story(ctx, story.id).intake_record_id
      channel = join_runner(ctx, %{"kinds" => ["triage", "implement"]})

      assert unboxed(fn -> TriageDispatcher.run_with(20, @budgets) end) == [:dispatched]
      assert_push "dispatch", pushed, @reply_timeout

      assert pushed.kind == "triage"
      assert pushed.story_id == story.id
      assert pushed.wall_clock_seconds == @budgets.wall_clock_seconds
      assert pushed.max_turns == @budgets.max_turns

      # THE REPORTER'S WORDS, fenced, and the record they came from — the whole input a triage
      # session has. A dispatch without them names a story nobody can judge.
      assert pushed.triage.record_id == record_id
      assert pushed.triage.untrusted =~ "UNTRUSTED DATA"

      # It CLAIMS NOTHING. A triage session decides whether the story is work at all; marking
      # it as being worked by the machine that is only deciding that would put it at
      # `claimed`, which is the stage an implement session reports from.
      assert unboxed(fn -> Stages.get(ctx.tenant.id, story.id) end).stage == :detected
      assert unboxed(fn -> reload_story(ctx, story.id) end).agent_status == :pending

      leave_channel(channel)
    end

    test "a runner that declares only IMPLEMENT is not sent triage", ctx do
      _story = detected_story(ctx)
      join_runner(ctx, %{"kinds" => ["implement"]})

      # The declaration decides, and `Runners.accepts?/5` reads it before anything is written.
      # Sent anyway, the dispatch would be refused `kind_not_supported` after a ledger row and
      # a slot — once per story per minute, for ever.
      assert unboxed(fn -> TriageDispatcher.run_with(20, @budgets) end) == [:no_runner]
      refute_push "dispatch", _pushed
    end

    test "a runner that declares NOTHING is not sent triage either", ctx do
      _story = detected_story(ctx)
      join_runner(ctx, %{})

      # THE ASYMMETRY THAT MAKES 1.10.0 SAFE TO DEPLOY AHEAD OF THE FLEET: a machine built
      # before the `kinds` field existed says nothing on join and is read as declaring what
      # loopctl sent then — `implement` alone. Equalising `implied_by_silence` with
      # `dispatchable` would start sending triage to every runner ever built.
      assert unboxed(fn -> TriageDispatcher.run_with(20, @budgets) end) == [:no_runner]
      refute_push "dispatch", _pushed
    end

    test "a second pass starts NO second session on the same ticket", ctx do
      story = detected_story(ctx)
      channel = join_runner(ctx, %{"kinds" => ["triage"]})

      assert unboxed(fn -> TriageDispatcher.run_with(20, @budgets) end) == [:dispatched]
      assert_push "dispatch", first, @reply_timeout

      # The story stays at `detected` until a verdict comes back, so it is a candidate of
      # every pass in between — correct, and exactly why the `dispatch_id` is DERIVED from the
      # story and its epoch rather than generated. A generated one would start a fresh triage
      # session every minute on the same ticket, each spending a slot and a model's time.
      #
      # The second pass answers `:deferred` — the ledger's own reservation for the live
      # session is what refuses it, which is the fleet being busy and not a fault.
      assert unboxed(fn -> TriageDispatcher.run_with(20, @budgets) end) == [:deferred]

      records = unboxed(fn -> ledger_records(ctx, story.id) end)
      assert [%{dispatch_id: only}] = records
      assert only == first.dispatch_id

      leave_channel(channel)
    end

    test "a story whose project has no intake source is BLOCKED, not dispatched", ctx do
      _story = detected_story(ctx, bind_repo: false)
      join_runner(ctx, %{"kinds" => ["triage"]})

      # No source means no repository, and a dispatch must name one. Nothing clears that but a
      # person enrolling a source, so it is `:blocked` and logged at ERROR rather than left
      # looking like an empty queue.
      assert unboxed(fn -> TriageDispatcher.run_with(20, @budgets) end) == [:blocked]
      refute_push "dispatch", _pushed
    end
  end

  describe "the config gate" do
    test "nothing is dispatched while the unattended loop is off", ctx do
      _story = detected_story(ctx)
      join_runner(ctx, %{"kinds" => ["triage"]})

      # One switch for the whole unattended loop: triage running while nothing places the
      # result is a state an operator should not be able to be in by accident.
      assert unboxed(fn -> TriageDispatcher.run(20) end) == {:ok, []}
      refute_push "dispatch", _pushed
    end

    test "the triage budgets are unset, and named when missing" do
      assert TriageDispatcher.budgets() == {:error, {:unset, :triage_wall_clock_seconds}}
    end
  end

  # -- helpers ---------------------------------------------------------------------------

  defp unboxed(fun) do
    Sandbox.unboxed_run(AdminRepo, fn -> Sandbox.unboxed_run(Loopctl.Repo, fun) end)
  end

  # A story as INTAKE leaves it: created from a record, its stage row open at `detected`, its
  # project bound to a repository.
  defp detected_story(ctx, opts \\ []) do
    story = fixture(:committed_story, %{tenant_id: ctx.tenant.id})

    if Keyword.get(opts, :intake_record, true),
      do: attach_record(ctx, story, Keyword.get(opts, :bind_repo, true))

    unboxed(fn ->
      {:ok, _row} = Stages.open(ctx.tenant.id, story.id, actor_label: "test")
      story
    end)
  end

  defp queue(story) do
    unboxed(fn ->
      {:ok, story} =
        Progress.contract_story(story.tenant_id, story.id, %{},
          actor_label: "test",
          skip_contract_check: true
        )

      {:ok, _} =
        Stages.advance(story.tenant_id, story.id, {:detected, :triaged},
          claim_epoch: story.claim_epoch
        )

      {:ok, _} =
        Stages.advance(story.tenant_id, story.id, {:triaged, :queued},
          claim_epoch: story.claim_epoch
        )

      story
    end)
  end

  # The record AND its source, on the story's own project when the story is meant to be
  # addressable. `intake_sources_active_repo_uidx` allows ONE active source per repository per
  # tenant, so the fixture's source has to BE the story's rather than a second one beside it.
  #
  # `bind_repo: false` leaves the source on the fixture's own project instead, which is the
  # real shape of a story whose project nobody bound: it has a record and no repository.
  defp attach_record(ctx, story, bind_repo?) do
    repo = "mkreyman/repo-#{System.unique_integer([:positive])}"

    attrs =
      if bind_repo?,
        do: %{
          tenant_id: ctx.tenant.id,
          project_id: story.project_id,
          issue_number: 412,
          repo_full_name: repo
        },
        else: %{tenant_id: ctx.tenant.id, issue_number: 412, repo_full_name: repo}

    {_source, record} = fixture(:committed_intake, attrs)

    unboxed(fn ->
      {1, _} =
        AdminRepo.update_all(
          from(s in Loopctl.WorkBreakdown.Story, where: s.id == ^story.id),
          set: [intake_record_id: record.id]
        )
    end)

    record
  end

  defp reload_story(ctx, story_id) do
    unboxed(fn ->
      AdminRepo.one(
        from s in Loopctl.WorkBreakdown.Story,
          where: s.id == ^story_id and s.tenant_id == ^ctx.tenant.id
      )
    end)
  end

  defp ledger_records(ctx, story_id) do
    AdminRepo.all(
      from r in Loopctl.Runners.DispatchRecord,
        where: r.tenant_id == ^ctx.tenant.id and r.story_id == ^story_id,
        select: %{dispatch_id: r.dispatch_id, status: r.status}
    )
  end

  defp candidate_ids(limit) do
    unboxed(fn -> Enum.map(TriageDispatcher.candidates(limit), & &1.story_id) end)
  end

  defp join_runner(ctx, overrides) do
    {:ok, socket} = connect(RunnerSocket, %{}, connect_info: connect_info(ctx.runner_key))

    {:ok, _reply, channel} =
      subscribe_and_join(
        socket,
        "runner:" <> ctx.runner.id,
        Map.merge(join_payload("minis"), overrides)
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

  defp join_payload(machine) do
    %{
      "contract_version" => RunnerContract.version(),
      "machine" => machine,
      "cores" => 16,
      "memory_mb" => 28_000,
      # EVERY repository: this suite gives each story its own (one active source per repo per
      # tenant), and what it is testing is the KIND declaration, not the repo one — which has
      # its own tests in `DispatchDriverTest`.
      "repos" => [],
      "max_sessions" => 9,
      "in_flight" => 0,
      "draining" => false
    }
  end
end
