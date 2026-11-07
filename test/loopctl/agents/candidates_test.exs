defmodule Loopctl.Agents.CandidatesTest do
  @moduledoc """
  US-48.3: `Loopctl.Agents.Candidates.query/2` builds triage's and implement's candidate reads
  from each spec's predicate list.

  The equivalence tests (AC-48.3.2) seed ONE corpus that exercises every predicate in the
  closed set and assert, for each kind, that the builder's ordered list is exactly the list
  written out by hand below AND equal to what `candidates/1` returns. The hand-written list is
  the oracle: it was first checked against the old `candidates/1` bodies (before they were
  replaced by a delegation), and it stays a real comparison after, when `candidates/1` and the
  builder are the same code.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Agents.Candidates
  alias Loopctl.Agents.Specs.ImplementV1
  alias Loopctl.Agents.Specs.TriageV1
  alias Loopctl.Delivery.DispatchDriver
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.TriageDispatcher
  alias Loopctl.Intake.Source
  alias Loopctl.Progress

  setup do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    other = fixture(:tenant, %{trust_tier: :human_anchored})
    {_raw, runner} = fixture(:runner, %{tenant_id: tenant.id, name: "minis", max_sessions: 9})
    %{tenant: tenant, other: other, runner: runner}
  end

  describe "the corpus (AC-48.3.2)" do
    setup ctx, do: %{corpus: seed_corpus(ctx)}

    test "TC-48.3.1: triage — the builder returns the same ordered list as candidates/1", ctx do
      c = ctx.corpus

      # Round-robin: every project's oldest before any project's second (`d_a2` is older than
      # `d_b1` but second in its project), every tenant's first before any tenant's second
      # (`d_tenant_b` is the other tenant's only row, ranked 1 there).
      expected = [
        c.d_a1,
        c.d_tenant_b,
        c.d_b1,
        c.d_open,
        c.d_ticket_on_with_ticket,
        c.d_released_triage,
        c.d_live_implement,
        c.d_unmet_dependency,
        c.d_contracted,
        c.d_a2
      ]

      built = run(TriageV1.spec(), 50)

      assert ids(built) == expected
      assert TriageDispatcher.candidates(50) == Enum.map(built, &Map.take(&1, two_keys()))

      # Bounded, and the bound keeps the head.
      assert ids(run(TriageV1.spec(), 3)) == Enum.take(expected, 3)
      assert ids(TriageDispatcher.candidates(3)) == Enum.take(expected, 3)

      # Every exclusion is one predicate's doing, and none of them is a candidate.
      for excluded <-
            [
              c.d_closed,
              c.d_ticket_on_without_ticket,
              c.d_two_sources,
              c.d_live_triage,
              c.d_authored,
              c.d_no_source
            ] ++ queued_ids(c) do
        refute excluded in ids(built)
      end
    end

    test "TC-48.3.2: implement — the builder returns the same ordered list as candidates/1",
         ctx do
      c = ctx.corpus

      expected = [
        c.q_a1,
        c.q_tenant_b,
        c.q_b1,
        c.q_pending,
        c.q_authored,
        c.q_open,
        c.q_live_implement,
        c.q_ticket_on_without_ticket,
        c.q_a2
      ]

      built = run(ImplementV1.spec(), 50)

      assert ids(built) == expected
      assert DispatchDriver.candidates(50) == built

      assert ids(run(ImplementV1.spec(), 2)) == Enum.take(expected, 2)
      assert ids(DispatchDriver.candidates(2)) == Enum.take(expected, 2)

      for excluded <-
            [
              c.q_assigned,
              c.q_closed,
              c.q_story_dependency,
              c.q_epic_dependency,
              c.q_two_sources,
              c.q_no_source
            ] ++ detected_ids(c) do
        refute excluded in ids(built)
      end
    end

    test "a reopened issue is a candidate again, for both kinds", ctx do
      c = ctx.corpus

      set_issue_state(c.records.d_closed, "open")
      set_issue_state(c.records.q_closed, "open")

      assert c.d_closed in ids(run(TriageV1.spec(), 50))
      assert c.q_closed in ids(run(ImplementV1.spec(), 50))
      assert ids(TriageDispatcher.candidates(50)) == ids(run(TriageV1.spec(), 50))
      assert ids(DispatchDriver.candidates(50)) == ids(run(ImplementV1.spec(), 50))
    end
  end

  describe "tenant isolation (AC-48.3.4)" do
    test "TC-48.3.3: a tenant-scoped read never returns another tenant's story", ctx do
      mine_detected = detected(ctx.tenant.id, -100)
      mine_queued = detected(ctx.tenant.id, -90) |> queue()
      theirs_detected = detected(ctx.other.id, -200)
      theirs_queued = detected(ctx.other.id, -190) |> queue()
      backdate(mine_queued.id, -90)
      backdate(theirs_queued.id, -190)

      for {spec, mine, theirs} <- [
            {TriageV1.spec(), mine_detected.id, theirs_detected.id},
            {ImplementV1.spec(), mine_queued.id, theirs_queued.id}
          ] do
        scoped = run(spec, 50, tenant_id: ctx.tenant.id)
        assert ids(scoped) == [mine]
        assert Enum.all?(scoped, &(&1.tenant_id == ctx.tenant.id))

        assert ids(run(spec, 50, tenant_id: ctx.other.id)) == [theirs]

        # Fleet-wide, every row carries the tenant its story belongs to.
        fleet = run(spec, 50)
        assert Enum.sort(ids(fleet)) == Enum.sort([mine, theirs])

        for row <- fleet do
          story = AdminRepo.get!(Loopctl.WorkBreakdown.Story, row.story_id)
          assert row.tenant_id == story.tenant_id
        end
      end
    end

    test "a live triage dispatch in one tenant excludes only that tenant's story", ctx do
      mine = detected(ctx.tenant.id, -100)
      theirs = detected(ctx.other.id, -50)
      {_raw, their_runner} = fixture(:runner, %{tenant_id: ctx.other.id, name: "beelink"})

      write_ledger_row(ctx.other.id, their_runner.id, theirs.id, kind: "triage")

      assert ids(run(TriageV1.spec(), 50)) == [mine.id]
    end
  end

  describe "validate/1 — the closed predicate set (AC-48.3.1)" do
    test "both registered specs' predicate lists are valid" do
      assert Candidates.validate(TriageV1.spec().candidates) == :ok
      assert Candidates.validate(ImplementV1.spec().candidates) == :ok
    end

    @refusals [
      {[{:stage, :detected}, :by_vibes], "[:by_vibes]"},
      {[], "must name at least one"},
      {[:intake_record_required], "exactly one {:stage, stage}"},
      {[{:stage, :detected}, {:stage, :queued}], "exactly one {:stage, stage}"},
      {[{:stage, :nowhere}], "{:stage, :nowhere}"},
      {[{:stage, :queued}, {:agent_status_in, []}], "{:agent_status_in, []}"},
      {[{:stage, :queued}, {:agent_status_in, [:dreaming]}], "{:agent_status_in, [:dreaming]}"},
      {[{:stage, :queued}, {:agent_status_in, [:pending, :pending]}],
       "{:agent_status_in, [:pending, :pending]}"},
      {[{:stage, :queued}, {:agent_status_in, [:pending]}, {:agent_status_in, [:contracted]}],
       "at most one {:agent_status_in, statuses}"},
      {[{:stage, :queued}, :intake_record_required, :intake_record_optional],
       "at most one of [:intake_record_required, :intake_record_optional]"},
      {[{:stage, :queued}, :issue_not_closed], ":issue_not_closed needs"},
      {[{:stage, :detected}, :single_active_source, :requires_ticket_if_source_says],
       ":requires_ticket_if_source_says needs"},
      {[{:stage, :detected}, :intake_record_required, :requires_ticket_if_source_says],
       ":requires_ticket_if_source_says needs :single_active_source"},
      {[{:stage, :detected}, :dependencies_met, :dependencies_met], "names a predicate twice"}
    ]

    for {{predicates, expected}, index} <- Enum.with_index(@refusals) do
      test "#{index}: #{inspect(predicates)} is refused" do
        assert {:error, message} =
                 Candidates.validate(%{
                   predicates: unquote(Macro.escape(predicates)),
                   order: :round_robin_project_tenant
                 })

        assert message =~ unquote(expected)
      end
    end

    test "an unknown order is refused" do
      assert {:error, message} =
               Candidates.validate(%{predicates: [{:stage, :queued}], order: :newest_first})

      assert message =~ "candidates.order :newest_first"
    end

    test "a value that is not %{predicates:, order:} is refused" do
      assert {:error, message} = Candidates.validate([{:stage, :queued}])
      assert message =~ "candidates must be"
    end

    test "query/2 refuses a predicate list validate/1 refuses" do
      spec = %{
        kind: "triage",
        candidates: %{predicates: [:by_vibes], order: :round_robin_project_tenant}
      }

      assert_raise ArgumentError, ~r/by_vibes/, fn -> Candidates.query(spec, limit: 1) end
    end

    test "query/2 requires a positive :limit" do
      assert_raise ArgumentError, ~r/limit/, fn -> Candidates.query(TriageV1.spec(), []) end
      assert_raise ArgumentError, ~r/limit/, fn -> Candidates.query(TriageV1.spec(), limit: 0) end
    end
  end

  # -- the corpus ---------------------------------------------------------------------------

  # Every predicate, both ways where it has two, for both kinds, in two tenants. Each row is
  # backdated to its own second, so the order is a fact of the data and not of insertion time.
  defp seed_corpus(ctx) do
    t = ctx.tenant.id

    # ── detected (triage) ──
    d_a1 = detected(t, -1000)
    d_a2 = detected(t, -900)
    move_to_project(d_a2.id, d_a1.project_id)
    d_b1 = detected(t, -800)

    d_open = detected(t, -700)
    set_issue_state(record_id(d_open), "open")

    d_closed = detected(t, -690)
    set_issue_state(record_id(d_closed), "closed")

    d_ticket_on_with_ticket = detected(t, -600)
    set_requires_ticket(source_id(d_ticket_on_with_ticket), true)
    set_ticket(record_id(d_ticket_on_with_ticket), Ecto.UUID.generate())

    d_ticket_on_without_ticket = detected(t, -590)
    set_requires_ticket(source_id(d_ticket_on_without_ticket), true)

    d_two_sources = detected(t, -580)
    bind_source(t, d_two_sources.project_id)

    d_live_triage = detected(t, -570)
    write_ledger_row(t, ctx.runner.id, d_live_triage.id, kind: "triage")

    d_released_triage = detected(t, -500)

    write_ledger_row(t, ctx.runner.id, d_released_triage.id,
      kind: "triage",
      released_at: DateTime.utc_now()
    )

    d_live_implement = detected(t, -400)
    write_ledger_row(t, ctx.runner.id, d_live_implement.id, kind: "implement")

    d_unmet_dependency = detected(t, -300)
    depend_on_story(t, d_unmet_dependency)

    d_contracted = detected(t, -250)
    contract(d_contracted)

    d_authored = detected(t, -200, intake_record: false)
    bind_source(t, d_authored.project_id)

    d_no_source = detected(t, -150, bind_repo: false)

    # ── queued (implement) ──
    q_a1 = queued(t, -2000)
    q_a2 = queued(t, -1900)
    move_to_project(q_a2.id, q_a1.project_id)
    q_b1 = queued(t, -1800)

    q_pending = queued(t, -1700)
    set_agent_status(q_pending.id, :pending)

    q_assigned = queued(t, -1690)
    set_agent_status(q_assigned.id, :assigned)

    q_authored = queued(t, -1600, intake_record: false)

    q_closed = queued(t, -1590)
    set_issue_state(record_id(q_closed), "closed")

    q_open = queued(t, -1500)
    set_issue_state(record_id(q_open), "open")

    q_story_dependency = queued(t, -1490)
    depend_on_story(t, q_story_dependency)

    q_epic_dependency = queued(t, -1480)
    depend_on_epic(t, q_epic_dependency)

    q_two_sources = queued(t, -1470)
    bind_source(t, q_two_sources.project_id)

    q_live_implement = queued(t, -1400)
    write_ledger_row(t, ctx.runner.id, q_live_implement.id, kind: "implement")

    q_ticket_on_without_ticket = queued(t, -1300)
    set_requires_ticket(source_id(q_ticket_on_without_ticket), true)

    q_no_source = queued(t, -1290, bind_repo: false)

    # ── the other tenant ──
    d_tenant_b = detected(ctx.other.id, -950)
    q_tenant_b = queued(ctx.other.id, -1950)

    %{
      d_a1: d_a1.id,
      d_a2: d_a2.id,
      d_b1: d_b1.id,
      d_open: d_open.id,
      d_closed: d_closed.id,
      d_ticket_on_with_ticket: d_ticket_on_with_ticket.id,
      d_ticket_on_without_ticket: d_ticket_on_without_ticket.id,
      d_two_sources: d_two_sources.id,
      d_live_triage: d_live_triage.id,
      d_released_triage: d_released_triage.id,
      d_live_implement: d_live_implement.id,
      d_unmet_dependency: d_unmet_dependency.id,
      d_contracted: d_contracted.id,
      d_authored: d_authored.id,
      d_no_source: d_no_source.id,
      d_tenant_b: d_tenant_b.id,
      q_a1: q_a1.id,
      q_a2: q_a2.id,
      q_b1: q_b1.id,
      q_pending: q_pending.id,
      q_assigned: q_assigned.id,
      q_authored: q_authored.id,
      q_closed: q_closed.id,
      q_open: q_open.id,
      q_story_dependency: q_story_dependency.id,
      q_epic_dependency: q_epic_dependency.id,
      q_two_sources: q_two_sources.id,
      q_live_implement: q_live_implement.id,
      q_ticket_on_without_ticket: q_ticket_on_without_ticket.id,
      q_no_source: q_no_source.id,
      q_tenant_b: q_tenant_b.id,
      records: %{d_closed: record_id(d_closed), q_closed: record_id(q_closed)}
    }
  end

  defp detected_ids(c), do: for({k, v} <- c, String.starts_with?(to_string(k), "d_"), do: v)
  defp queued_ids(c), do: for({k, v} <- c, String.starts_with?(to_string(k), "q_"), do: v)

  # -- helpers -------------------------------------------------------------------------------

  defp run(spec, limit, opts \\ []) do
    spec |> Candidates.query([limit: limit] ++ opts) |> AdminRepo.all()
  end

  defp ids(rows), do: Enum.map(rows, & &1.story_id)

  defp two_keys, do: [:tenant_id, :story_id]

  defp detected(tenant_id, seconds, attrs \\ []) do
    story = fixture(:detected_story, Map.new([tenant_id: tenant_id] ++ attrs))
    backdate(story.id, seconds)
    story
  end

  # A story at `queued`, `contracted`: the shape `Placement.place/4` takes. Its project is
  # bound to one source either way: the intake pair's, or one inserted for an authored story.
  defp queued(tenant_id, seconds, attrs \\ []) do
    story = fixture(:detected_story, Map.new([tenant_id: tenant_id] ++ attrs))

    if Keyword.get(attrs, :intake_record, true) == false,
      do: bind_source(tenant_id, story.project_id)

    story = queue(story)
    backdate(story.id, seconds)
    story
  end

  defp contract(story) do
    {:ok, story} =
      Progress.contract_story(story.tenant_id, story.id, %{},
        actor_label: "test",
        skip_contract_check: true
      )

    story
  end

  defp queue(story) do
    story = contract(story)

    {:ok, _} =
      Stages.advance(story.tenant_id, story.id, {:detected, :triaged},
        claim_epoch: story.claim_epoch
      )

    {:ok, _} =
      Stages.advance(story.tenant_id, story.id, {:triaged, :queued},
        claim_epoch: story.claim_epoch
      )

    story
  end

  defp record_id(story) do
    AdminRepo.one!(
      from s in Loopctl.WorkBreakdown.Story, where: s.id == ^story.id, select: s.intake_record_id
    )
  end

  defp source_id(story) do
    AdminRepo.one!(
      from src in Source,
        where: src.tenant_id == ^story.tenant_id and src.project_id == ^story.project_id,
        where: is_nil(src.revoked_at),
        select: src.id
    )
  end

  defp bind_source(tenant_id, project_id) do
    now = DateTime.utc_now()

    AdminRepo.insert!(%Source{
      tenant_id: tenant_id,
      project_id: project_id,
      repo_full_name: "mkreyman/repo-#{System.unique_integer([:positive])}",
      base_branch: "master",
      webhook_secret: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
      inserted_at: now,
      updated_at: now
    })
  end

  defp set_requires_ticket(source_id, value) do
    {1, _} =
      AdminRepo.update_all(from(s in Source, where: s.id == ^source_id),
        set: [triage_requires_ticket: value]
      )
  end

  defp set_issue_state(record_id, state) do
    {1, _} =
      AdminRepo.update_all(from(r in Loopctl.Intake.Record, where: r.id == ^record_id),
        set: [issue_state: state]
      )
  end

  defp set_ticket(record_id, ticket_id) do
    {1, _} =
      AdminRepo.update_all(from(r in Loopctl.Intake.Record, where: r.id == ^record_id),
        set: [ticket_ref: "HCB-" <> String.slice(ticket_id, 0, 8), ticket_id: ticket_id]
      )
  end

  defp set_agent_status(story_id, status) do
    {1, _} =
      AdminRepo.update_all(from(s in Loopctl.WorkBreakdown.Story, where: s.id == ^story_id),
        set: [agent_status: status]
      )
  end

  defp depend_on_story(tenant_id, story) do
    blocker = fixture(:ledger_story, %{tenant_id: tenant_id})

    fixture(:story_dependency, %{
      tenant_id: tenant_id,
      story_id: story.id,
      depends_on_story_id: blocker.id
    })
  end

  defp depend_on_epic(tenant_id, story) do
    blocker = fixture(:ledger_story, %{tenant_id: tenant_id})

    fixture(:epic_dependency, %{
      tenant_id: tenant_id,
      epic_id: story.epic_id,
      depends_on_epic_id: blocker.epic_id
    })
  end

  defp move_to_project(story_id, project_id) do
    {1, _} =
      AdminRepo.update_all(from(s in Loopctl.WorkBreakdown.Story, where: s.id == ^story_id),
        set: [project_id: project_id]
      )
  end

  defp backdate(story_id, seconds) do
    at = NaiveDateTime.add(NaiveDateTime.utc_now(), seconds, :second)

    {1, _} =
      AdminRepo.update_all(
        from(s in Loopctl.Delivery.StoryStage, where: s.story_id == ^story_id),
        set: [updated_at: NaiveDateTime.truncate(at, :second)]
      )
  end

  defp write_ledger_row(tenant_id, runner_id, story_id, opts) do
    now = DateTime.utc_now()

    AdminRepo.insert_all(Loopctl.Runners.DispatchRecord, [
      %{
        tenant_id: tenant_id,
        runner_id: runner_id,
        dispatch_id: Ecto.UUID.generate(),
        story_id: story_id,
        claim_epoch: 0,
        kind: Keyword.fetch!(opts, :kind),
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
end
