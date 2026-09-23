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
  import ExUnit.CaptureLog

  require Logger

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Delivery.DispatchDriver
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.TriageDispatcher
  alias Loopctl.Progress
  alias Loopctl.Runners.Presence
  alias Loopctl.Runners.Usage
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

    test "a LIVE triage dispatch excludes its story, and its release brings it back", ctx do
      story = detected_story(ctx)
      assert story.id in candidate_ids(50)

      # What stops a second session on one ticket. A triage dispatch claims nothing and writes
      # no stage row, so the STAGE cannot say a session is running; the unreleased ledger row
      # is the only thing that can.
      unboxed(fn -> write_ledger_row(ctx, story.id, released_at: nil) end)
      refute story.id in candidate_ids(50)

      # AND THE HALF THE OLD DESIGN COULD NOT DO. A triage dispatch ends without a verdict
      # whenever the machine restarts, the runner is drained, or the wall clock runs out and
      # `Capacity.heal/3` releases the reservation — and the story must become dispatchable
      # again. It never did while the `dispatch_id` was DERIVED from the story and its epoch:
      # nothing bumps `claim_epoch` on an unclaimed `detected` story, so the id could not
      # differ and every later attempt was refused for ever, as `:dispatch_id_conflict` if
      # another runner was picked and `:dispatch_already_replied` if the same one was — the
      # second logged at `info`, as though the fleet were merely busy.
      unboxed(fn -> release_ledger_rows(ctx, story.id) end)
      assert story.id in candidate_ids(50)
    end

    test "an IMPLEMENT dispatch on the story does not exclude it from triage", ctx do
      story = detected_story(ctx)

      # The predicate is scoped to the triage kind on purpose. A story at `detected` should
      # not have an implement dispatch at all — placement requires `queued` — but a predicate
      # reading every kind would let one stray row hide a ticket from triage for ever, which
      # is the failure mode this whole query is being corrected for.
      unboxed(fn -> write_ledger_row(ctx, story.id, kind: "implement", released_at: nil) end)
      assert story.id in candidate_ids(50)
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

    # US-44.6: the triage dispatcher selects through the same `Runners.accepts?/5` as the
    # driver, so an exhausted subscription holds a triage-capable machine out too — and the
    # pass says when capacity returns, once for the tenant.
    test "an EXHAUSTED runner is not sent triage, and the pass logs the earliest reset", ctx do
      _story = detected_story(ctx)
      channel = join_runner(ctx, %{"kinds" => ["triage"]})
      resets_at = DateTime.add(DateTime.utc_now(), 3_600, :second)

      unboxed(fn ->
        :ok =
          Usage.record(ctx.tenant.id, ctx.runner.id, %{exhausted: true, resets_at: resets_at})
      end)

      Logger.put_module_level(Usage, :info)
      on_exit(fn -> Logger.delete_module_level(Usage) end)

      log =
        capture_log([level: :info], fn ->
          assert unboxed(fn -> TriageDispatcher.run_with(20, @budgets) end) == [:no_runner]
        end)

      refute_push "dispatch", _pushed
      assert [_, logged] = Regex.run(~r/earliest_usage_reset=(\S+):/, log)
      assert {:ok, logged, 0} = DateTime.from_iso8601(logged)
      assert DateTime.compare(logged, resets_at) == :eq

      leave_channel(channel)
    end

    # ONE read of the tenant's exhausted runners per pass, as the driver's: the eligibility
    # check used to query per runner per story.
    test "a pass reads the tenant's exhausted runners once", ctx do
      _first = detected_story(ctx)
      _second = detected_story(ctx)
      channel = join_runner(ctx, %{"kinds" => ["triage"]})

      unboxed(fn -> :ok = Usage.record(ctx.tenant.id, ctx.runner.id, %{exhausted: true}) end)

      id = {__MODULE__, make_ref()}
      :ok = :telemetry.attach(id, [:loopctl, :repo, :query], &__MODULE__.count_read/4, self())

      try do
        assert unboxed(fn -> TriageDispatcher.run_with(20, @budgets) end) ==
                 [:no_runner, :no_runner]
      after
        :telemetry.detach(id)
      end

      assert_received :exhaustion_read
      refute_received :exhaustion_read

      leave_channel(channel)
    end

    test "an exhausted runner refused for ANOTHER reason logs no reset", ctx do
      _story = detected_story(ctx)
      # Triage-capable, but with no checkout of the story's repository: exhaustion is not why
      # nothing was sent, and the reset would name the wrong cause.
      channel = join_runner(ctx, %{"kinds" => ["triage"], "repos" => ["mkreyman/elsewhere"]})

      unboxed(fn -> :ok = Usage.record(ctx.tenant.id, ctx.runner.id, %{exhausted: true}) end)

      Logger.put_module_level(Usage, :info)
      on_exit(fn -> Logger.delete_module_level(Usage) end)

      log =
        capture_log([level: :info], fn ->
          assert unboxed(fn -> TriageDispatcher.run_with(20, @budgets) end) == [:no_runner]
        end)

      refute log =~ "earliest_usage_reset"

      leave_channel(channel)
    end

    test "a runner that ran dry AFTER the pass read the map is re-checked before the push, " <>
           "and the triage goes to the next runner",
         ctx do
      story = detected_story(ctx)

      {r2_key, r2} =
        fixture(:committed_runner, %{tenant_id: ctx.tenant.id, name: "beelink", max_sessions: 9})

      dry = join_runner(ctx, %{"kinds" => ["triage"]})
      other = join_as(r2, r2_key, "beelink", %{"kinds" => ["triage"]})
      # The dry runner is the least loaded, so it is picked FIRST.
      unboxed(fn -> set_in_flight(r2.id, 1) end)

      # `Runners.dispatch/3` checks nothing about the subscription, so without the re-check the
      # map read seconds earlier sent this to a machine whose session would end
      # `usage_exhausted`.
      assert exhaust_mid_pass(ctx.runner.id, fn ->
               unboxed(fn -> TriageDispatcher.run_with(20, @budgets) end)
             end) == [:dispatched]

      assert [runner_id] =
               unboxed(fn ->
                 AdminRepo.all(
                   from r in Loopctl.Runners.DispatchRecord,
                     where: r.story_id == ^story.id,
                     select: r.runner_id
                 )
               end)

      assert runner_id == r2.id

      leave_channel(other)
      leave_channel(dry)
    end

    test "an exhausted runner that is also FULL contributes no reset", ctx do
      _story = detected_story(ctx)
      channel = join_runner(ctx, %{"kinds" => ["triage"]})

      unboxed(fn ->
        :ok = Usage.record(ctx.tenant.id, ctx.runner.id, %{exhausted: true})
        set_in_flight(ctx.runner.id, 9)
      end)

      Logger.put_module_level(Usage, :info)
      on_exit(fn -> Logger.delete_module_level(Usage) end)

      log =
        capture_log([level: :info], fn ->
          assert unboxed(fn -> TriageDispatcher.run_with(20, @budgets) end) == [:no_runner]
        end)

      refute log =~ "earliest_usage_reset"

      leave_channel(channel)
    end

    test "an empty fleet reads no exhausted runners", ctx do
      _story = detected_story(ctx)

      id = {__MODULE__, make_ref()}
      :ok = :telemetry.attach(id, [:loopctl, :repo, :query], &__MODULE__.count_read/4, self())

      try do
        assert unboxed(fn -> TriageDispatcher.run_with(20, @budgets) end) == [:no_runner]
      after
        :telemetry.detach(id)
      end

      refute_received :exhaustion_read
    end

    test "a candidate that raises after the pass read the map does not throw the read away",
         ctx do
      for _ <- 1..2, do: detected_story(ctx)

      # A pool entry that passes every fact on its meta and whose id is not a UUID, so the row
      # read AFTER the exhaustion read raises — for every candidate.
      topic = Loopctl.Runners.pool_topic(ctx.tenant.id)

      {:ok, _ref} =
        Presence.track(self(), topic, "ghost", %{
          runner_id: "not-a-uuid",
          kinds: ["triage"]
        })

      id = {__MODULE__, make_ref()}
      :ok = :telemetry.attach(id, [:loopctl, :repo, :query], &__MODULE__.count_read/4, self())

      try do
        capture_log(fn ->
          assert unboxed(fn -> TriageDispatcher.run_with(20, @budgets) end) ==
                   [:errored, :errored]
        end)
      after
        :telemetry.detach(id)
        Presence.untrack(self(), topic, "ghost")
      end

      assert_received :exhaustion_read
      refute_received :exhaustion_read
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

      # The story stays at `detected` until a verdict comes back, so nothing about the STAGE
      # stops a second pass sending a second dispatch. What stops it is the ledger row: a
      # story holding an UNRELEASED triage dispatch is not a candidate, so the second pass has
      # nothing to do rather than being refused after minting an id.
      #
      # This used to be bought with a `dispatch_id` derived from the story and its epoch, and
      # the price was two permanent blocks — nothing bumps `claim_epoch` on an unclaimed
      # `detected` story, so the id could never differ for a runner that went away or a
      # session that died. The assertion here is the same either way; the next test is the one
      # the derivation could not pass.
      assert unboxed(fn -> TriageDispatcher.run_with(20, @budgets) end) == []

      records = unboxed(fn -> ledger_records(ctx, story.id) end)
      assert [%{dispatch_id: only}] = records
      assert only == first.dispatch_id

      leave_channel(channel)
    end

    test "a ticket too large to describe is ESCALATED, not logged every minute", ctx do
      story = detected_story(ctx, body: String.duplicate("x", 12_000))
      join_runner(ctx, %{"kinds" => ["triage"]})

      # `TriagePayload` states this contract in its own moduledoc — "its caller escalates it
      # to a human" — and this is the only caller. Logged and left, it was an ERROR line a
      # minute for ever about a condition that cannot change by itself, on a story the query
      # cannot exclude either: the bound is on the RENDERED object, so no predicate can see
      # it, and the story stayed at the head of the oldest-first ranking.
      assert unboxed(fn -> TriageDispatcher.run_with(20, @budgets) end) == [:escalated]
      refute_push "dispatch", _pushed

      # `detected` has no edge to `escalated`, so it takes the route the machine already has
      # for this conclusion — the one an escalating verdict takes.
      row = unboxed(fn -> Stages.get(ctx.tenant.id, story.id) end)
      assert row.stage == :escalated
      assert row.escalation_reason == "triage_dispatch:triage_too_large"

      # AND IT IS NO LONGER A CANDIDATE, which is the half that matters to every other story:
      # it has left `detected`.
      refute story.id in candidate_ids(50)
    end

    test "a LEGACY source whose base_branch is not a git ref name is blocked, not pushed", ctx do
      story = detected_story(ctx)
      join_runner(ctx, %{"kinds" => ["triage"]})

      # WRITTEN PAST THE CHANGESET ON PURPOSE, because that is the only way this row can exist:
      # `Source.validate_base_branch/1` refuses the value at enrolment and at repoint, so what
      # is modelled here is a row written BEFORE that validation — checked for length alone,
      # which `--upload-pack=/bin/sh` passes at 22 characters. The DB check bounds length too
      # and nothing else, so the update lands.
      #
      # This module is the one dispatch path that never goes through `DispatchPayload.fill/3`,
      # whose second `validate_refs/2` call is what judges a value the intake source supplied.
      # `dispatch/4` puts this column in as BOTH `branch` and `base_branch`, so without the
      # guard the string reaches git on a dev machine the first time an issue arrives.
      unboxed(fn ->
        {1, _} =
          AdminRepo.update_all(
            from(s in Loopctl.Intake.Source,
              where: s.tenant_id == ^ctx.tenant.id and s.project_id == ^story.project_id
            ),
            set: [base_branch: "--upload-pack=/bin/sh"]
          )
      end)

      # `:blocked` — "BLOCKED until somebody changes something" — which is what this is: an
      # operator has to repoint the source, and no later pass can change it by itself.
      assert unboxed(fn -> TriageDispatcher.run_with(20, @budgets) end) == [:blocked]
      refute_push "dispatch", _pushed
    end

    test "a story whose project has no intake source is not a candidate at all", ctx do
      _story = detected_story(ctx, bind_repo: false)
      join_runner(ctx, %{"kinds" => ["triage"]})

      # No source means no repository, and a dispatch must name one. Nothing clears that but a
      # person enrolling a source — and while it was discovered PER STORY it was `:blocked`
      # every pass, which left it at the head of an oldest-first ranking whose `updated_at`
      # never moves. Twenty such stories filled every batch and no newly detected story was
      # ever triaged again, while the worker reported a clean run. The predicate is in the
      # query now, the same one and for the same reason as the driver's.
      assert unboxed(fn -> TriageDispatcher.run_with(20, @budgets) end) == []
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

    test "a budget key that IS set has a ceiling, for every key in lib/" do
      # THE ONE THE UNSET TEST ABOVE CANNOT REACH, and the defect it hid. `normalise_budget/2`
      # returns before consulting the ceiling when the value is not a positive integer, so a
      # suite that only ever asserts the unset path never calls `budget_maximum/1` at all —
      # and that function is a private multi-clause with no catch-all, so a key it does not
      # name raises a FunctionClauseError INSIDE an Oban worker rather than returning an
      # error. The triage pair had no clause: setting `TRIAGE_WALL_CLOCK_SECONDS`, which is
      # what `deploy/FLY_SECRETS.md` tells an operator to do, crashed every pass — three
      # retries and a discard a minute, and not one triage dispatch ever sent.
      #
      # The keys are read from `lib/` rather than listed here, so a THIRD budget pair cannot be
      # added with a ceiling missing and this guard still pass. Scanned by the NAMING rather
      # than by the call site: two of the four call sites pass the key as a variable
      # (`fetch_budget(key)`, `budget_keys/1`), so a scan of the calls finds only the pair that
      # happens to be written out, which is the pair that already worked.
      keys =
        Path.wildcard("lib/**/*.ex")
        |> Enum.flat_map(fn file ->
          ~r/:([a-z_]+(?:_wall_clock_seconds|_max_turns))\b/
          |> Regex.scan(File.read!(file), capture: :all_but_first)
          |> List.flatten()
        end)
        |> Enum.uniq()
        |> Enum.map(&String.to_existing_atom/1)

      assert length(keys) >= 4,
             "found #{inspect(keys)}; the scan stopped matching the call sites it guards"

      for key <- keys do
        assert {:ok, 60} = DispatchDriver.normalise_budget(60, key)
      end
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
      do: attach_record(ctx, story, Keyword.get(opts, :bind_repo, true), opts)

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
  defp attach_record(ctx, story, bind_repo?, opts) do
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

    attrs =
      case Keyword.get(opts, :body) do
        nil -> attrs
        body -> Map.put(attrs, :untrusted_body, body)
      end

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

  # A ledger row as `record_sent/3` leaves one, written directly: the channel takes this row
  # `FOR UPDATE` on the SANDBOX connection when it pushes and holds that lock for the rest of
  # the test, so a committed write to a row a live socket has already touched waits out its
  # lock timeout. Selection is what is under test here and it needs no socket.
  defp write_ledger_row(ctx, story_id, opts) do
    now = DateTime.utc_now()

    AdminRepo.insert_all(Loopctl.Runners.DispatchRecord, [
      %{
        tenant_id: ctx.tenant.id,
        runner_id: ctx.runner.id,
        dispatch_id: Ecto.UUID.generate(),
        story_id: story_id,
        claim_epoch: 0,
        kind: Keyword.get(opts, :kind, "triage"),
        status: "sent",
        released_at: Keyword.get(opts, :released_at),
        wall_clock_seconds: 900,
        reserved_at: now,
        slot_generation: 1,
        trace_acked_seq: -1,
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  # What every ending does to the row, whatever ended it: `Capacity.release/4` on a refusal or
  # a terminal stage, and `heal/3` on a session that outran its wall clock.
  defp release_ledger_rows(ctx, story_id) do
    now = DateTime.utc_now()

    AdminRepo.update_all(
      from(r in Loopctl.Runners.DispatchRecord,
        where: r.tenant_id == ^ctx.tenant.id and r.story_id == ^story_id,
        where: is_nil(r.released_at)
      ),
      set: [released_at: now, updated_at: now]
    )
  end

  defp candidate_ids(limit) do
    unboxed(fn -> Enum.map(TriageDispatcher.candidates(limit), & &1.story_id) end)
  end

  @doc false
  def count_read(_event, _measurements, %{query: query}, pid) do
    if self() == pid and query =~ ~r/^SELECT .*"usage_exhausted_until"/s,
      do: send(pid, :exhaustion_read)
  end

  # Runs `fun` with `runner_id` exhausted the moment the pass has READ the tenant's exhausted
  # runners (the grouped read) and before it acts on what it read: a machine running dry
  # mid-pass. Written on AdminRepo's own connection, so it commits outside the read.
  defp exhaust_mid_pass(runner_id, fun) do
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(id, [:loopctl, :repo, :query], &__MODULE__.exhaust_after_read/4, %{
        pid: self(),
        id: id,
        runner_id: runner_id
      })

    try do
      fun.()
    after
      :telemetry.detach(id)
    end
  end

  @doc false
  def exhaust_after_read(_event, _measurements, %{query: query}, config) do
    %{pid: pid, id: id, runner_id: runner_id} = config

    if self() == pid and query =~ ~r/^SELECT .*"usage_exhausted_until".* GROUP BY /s do
      :telemetry.detach(id)
      until = DateTime.add(DateTime.utc_now(), 3_600, :second)

      {1, _} =
        AdminRepo.update_all(from(r in Loopctl.Runners.Runner, where: r.id == ^runner_id),
          set: [usage_exhausted_until: until]
        )
    end
  end

  defp set_in_flight(runner_id, count) do
    {1, _} =
      AdminRepo.update_all(from(r in Loopctl.Runners.Runner, where: r.id == ^runner_id),
        set: [in_flight: count]
      )
  end

  defp join_as(runner, key, machine, overrides) do
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
