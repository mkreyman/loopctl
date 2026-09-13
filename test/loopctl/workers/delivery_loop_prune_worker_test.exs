defmodule Loopctl.Workers.DeliveryLoopPruneWorkerTest do
  @moduledoc """
  #803 §11: retention for `runner_trace_events` and the intake delivery log.

  The two halves live on different connections by design — the trace prune runs on the RLS
  `Loopctl.Repo` (`Loopctl.Runners.DispatchLedger`) and the delivery prune on `AdminRepo`
  (`Loopctl.Intake`), each following its owning module's documented isolation — and the two
  sandbox transactions cannot see each other's rows. So the trace cases build their tenant on
  `Repo` (`fixture(:stage_story)`) and drive the worker through `prune_tenant/3`, which takes
  the tenant STRUCT; the intake cases build theirs on `AdminRepo` and drive the whole
  `perform/1`, including the `Tenants.list_tenants/1` fan-out and the telemetry. Both stay
  `async: true` that way, with no committed fixtures.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Intake
  alias Loopctl.Intake.Delivery, as: IntakeDelivery
  alias Loopctl.Intake.Signature
  alias Loopctl.Runners.Capacity
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.TraceEvent
  alias Loopctl.Tenants.Tenant
  alias Loopctl.Workers.DeliveryLoopPruneWorker

  setup :verify_on_exit!

  @day 86_400

  defp ago(days), do: DateTime.add(DateTime.utc_now(), -trunc(days * @day), :second)

  # A dispatch holding its slot: not terminal, so its trace is load-bearing.
  defp live_dispatch(tenant_id, runner) do
    story = fixture(:stage_story, %{tenant_id: tenant_id})
    fixture(:accepted_dispatch, %{tenant_id: tenant_id, runner: runner, story_id: story.id})
  end

  # The same, then released through the production path — the session is over.
  defp terminal_dispatch(tenant_id, runner) do
    record = live_dispatch(tenant_id, runner)

    {:ok, :released} =
      Repo.with_tenant(tenant_id, fn -> Capacity.release(Repo, record, record.slot_generation) end)

    record
  end

  defp trace_seqs(tenant_id, dispatch) do
    {:ok, seqs} =
      Repo.with_tenant(tenant_id, fn ->
        Repo.all(
          from e in TraceEvent,
            where: e.tenant_id == ^tenant_id and e.runner_dispatch_id == ^dispatch.id,
            order_by: [asc: e.seq],
            select: e.seq
        )
      end)

    seqs
  end

  defp delivery_ids(tenant_id) do
    AdminRepo.all(
      from d in IntakeDelivery,
        where: d.tenant_id == ^tenant_id,
        order_by: [asc: d.inserted_at],
        select: d.github_delivery_id
    )
  end

  defp tenant_struct(tenant_id, settings \\ %{}) do
    %Tenant{id: tenant_id, settings: settings}
  end

  defp run, do: DeliveryLoopPruneWorker.perform(%Oban.Job{args: %{}})

  # One real signed webhook delivery, so the delivery row and the record that cites it are
  # made the way production makes them.
  defp deliver(secret, source, delivery_id, attrs \\ %{}) do
    raw = Jason.encode!(build(:github_issues_payload, attrs))

    Intake.receive_github_delivery(source.id, %{
      raw_body: raw,
      signature: Signature.header(secret, raw),
      event: "issues",
      delivery_id: delivery_id,
      content_type: "application/json"
    })
  end

  defp backdate_delivery(tenant_id, delivery_id, at) do
    {1, _} =
      AdminRepo.update_all(
        from(d in IntakeDelivery,
          where: d.tenant_id == ^tenant_id and d.github_delivery_id == ^delivery_id
        ),
        set: [inserted_at: at]
      )

    :ok
  end

  describe "runner_trace_events: the retention window" do
    setup do
      story = fixture(:stage_story, %{})
      runner = fixture(:stage_runner, %{tenant_id: story.tenant_id})
      %{tenant_id: story.tenant_id, runner: runner}
    end

    test "deletes events past the window and keeps events inside it", ctx do
      dispatch = terminal_dispatch(ctx.tenant_id, ctx.runner)
      fixture(:trace_event, %{dispatch: dispatch, seq: 1, inserted_at: ago(30)})
      fixture(:trace_event, %{dispatch: dispatch, seq: 2, inserted_at: ago(15)})
      fixture(:trace_event, %{dispatch: dispatch, seq: 3, inserted_at: ago(1)})

      assert %{trace: %{deleted: 2, budget_exhausted: false}} =
               DeliveryLoopPruneWorker.prune_tenant(
                 tenant_struct(ctx.tenant_id),
                 DateTime.utc_now()
               )

      assert trace_seqs(ctx.tenant_id, dispatch) == [3]
    end

    test "a second run over the same window deletes nothing more", ctx do
      dispatch = terminal_dispatch(ctx.tenant_id, ctx.runner)
      fixture(:trace_event, %{dispatch: dispatch, seq: 1, inserted_at: ago(30)})

      tenant = tenant_struct(ctx.tenant_id)
      assert %{trace: %{deleted: 1}} = DeliveryLoopPruneWorker.prune_tenant(tenant, ago(0))
      assert %{trace: %{deleted: 0}} = DeliveryLoopPruneWorker.prune_tenant(tenant, ago(0))
    end

    test "an event of a dispatch still holding its slot survives however old it is", ctx do
      live = live_dispatch(ctx.tenant_id, ctx.runner)
      fixture(:trace_event, %{dispatch: live, seq: 1, inserted_at: ago(900)})

      assert %{trace: %{deleted: 0}} =
               DeliveryLoopPruneWorker.prune_tenant(
                 tenant_struct(ctx.tenant_id),
                 DateTime.utc_now()
               )

      assert trace_seqs(ctx.tenant_id, live) == [1]
    end

    test "releasing that dispatch is what makes its trace prunable", ctx do
      record = live_dispatch(ctx.tenant_id, ctx.runner)
      fixture(:trace_event, %{dispatch: record, seq: 1, inserted_at: ago(900)})
      tenant = tenant_struct(ctx.tenant_id)

      assert %{trace: %{deleted: 0}} =
               DeliveryLoopPruneWorker.prune_tenant(tenant, DateTime.utc_now())

      {:ok, :released} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          Capacity.release(Repo, record, record.slot_generation)
        end)

      assert %{trace: %{deleted: 1}} =
               DeliveryLoopPruneWorker.prune_tenant(tenant, DateTime.utc_now())
    end

    test "the tenant's own window is used, and one below the floor is raised to it", ctx do
      dispatch = terminal_dispatch(ctx.tenant_id, ctx.runner)
      fixture(:trace_event, %{dispatch: dispatch, seq: 1, inserted_at: ago(3)})
      fixture(:trace_event, %{dispatch: dispatch, seq: 2, inserted_at: ago(0.5)})

      # Two days is inside the default 14, so only the tenant setting can reach seq 1.
      assert %{trace: %{deleted: 1}} =
               DeliveryLoopPruneWorker.prune_tenant(
                 tenant_struct(ctx.tenant_id, %{"runner_trace_retention_days" => 2}),
                 DateTime.utc_now()
               )

      # Seq 2 is half a day old: a window of 0 would take it, the floor of one day keeps it.
      assert %{trace: %{deleted: 0}} =
               DeliveryLoopPruneWorker.prune_tenant(
                 tenant_struct(ctx.tenant_id, %{"runner_trace_retention_days" => 0}),
                 DateTime.utc_now()
               )

      assert trace_seqs(ctx.tenant_id, dispatch) == [2]
    end

    test "a setting that is not a positive integer falls back to the default", ctx do
      dispatch = terminal_dispatch(ctx.tenant_id, ctx.runner)
      fixture(:trace_event, %{dispatch: dispatch, seq: 1, inserted_at: ago(3)})

      for bad <- ["2", 2.0, nil, %{"days" => 2}] do
        assert %{trace: %{deleted: 0}} =
                 DeliveryLoopPruneWorker.prune_tenant(
                   tenant_struct(ctx.tenant_id, %{"runner_trace_retention_days" => bad}),
                   DateTime.utc_now()
                 )
      end

      assert trace_seqs(ctx.tenant_id, dispatch) == [1]
    end

    test "another tenant's events are never touched", ctx do
      mine = terminal_dispatch(ctx.tenant_id, ctx.runner)
      fixture(:trace_event, %{dispatch: mine, seq: 1, inserted_at: ago(30)})

      other_story = fixture(:stage_story, %{})
      other_runner = fixture(:stage_runner, %{tenant_id: other_story.tenant_id})
      theirs = terminal_dispatch(other_story.tenant_id, other_runner)
      fixture(:trace_event, %{dispatch: theirs, seq: 1, inserted_at: ago(30)})

      assert %{trace: %{deleted: 1}} =
               DeliveryLoopPruneWorker.prune_tenant(
                 tenant_struct(ctx.tenant_id),
                 DateTime.utc_now()
               )

      assert trace_seqs(ctx.tenant_id, mine) == []
      assert trace_seqs(other_story.tenant_id, theirs) == [1]
    end
  end

  describe "runner_trace_events: batching and the budget" do
    setup do
      story = fixture(:stage_story, %{})
      runner = fixture(:stage_runner, %{tenant_id: story.tenant_id})
      dispatch = terminal_dispatch(story.tenant_id, runner)

      for seq <- 1..5,
          do: fixture(:trace_event, %{dispatch: dispatch, seq: seq, inserted_at: ago(30 + seq)})

      %{tenant_id: story.tenant_id, dispatch: dispatch}
    end

    test "a run stops at its budget and the next one resumes, oldest first", ctx do
      tenant = tenant_struct(ctx.tenant_id)
      opts = [batch_size: 1, budget: 2]

      assert %{trace: %{deleted: 2, budget_exhausted: true}} =
               DeliveryLoopPruneWorker.prune_tenant(tenant, DateTime.utc_now(), opts)

      # Oldest first: seq 5 is the oldest (30 + seq days), so 5 and 4 went.
      assert trace_seqs(ctx.tenant_id, ctx.dispatch) == [1, 2, 3]

      assert %{trace: %{deleted: 2, budget_exhausted: true}} =
               DeliveryLoopPruneWorker.prune_tenant(tenant, DateTime.utc_now(), opts)

      assert %{trace: %{deleted: 1, budget_exhausted: false}} =
               DeliveryLoopPruneWorker.prune_tenant(tenant, DateTime.utc_now(), opts)

      assert trace_seqs(ctx.tenant_id, ctx.dispatch) == []
    end

    test "the budget caps the LAST batch, so a run never overshoots it", ctx do
      # Five eligible rows, a batch bigger than the budget: the batch has to be trimmed to
      # what the budget has left, or one statement takes all five.
      assert %{deleted: 3, budget_exhausted: true} =
               DispatchLedger.prune_trace_events(ctx.tenant_id, DateTime.utc_now(),
                 batch_size: 10,
                 budget: 3
               )

      assert length(trace_seqs(ctx.tenant_id, ctx.dispatch)) == 2
    end

    test "a tenant with exactly its budget of eligible rows is NOT reported at budget", ctx do
      # The probe is the difference between "stopped because there is more" and "stopped
      # because that was all", and an operator alerts on the first.
      assert %{deleted: 5, budget_exhausted: false} =
               DispatchLedger.prune_trace_events(ctx.tenant_id, DateTime.utc_now(),
                 batch_size: 2,
                 budget: 5
               )

      assert trace_seqs(ctx.tenant_id, ctx.dispatch) == []
    end

    test "one more eligible row than the budget IS reported at budget", ctx do
      assert %{deleted: 4, budget_exhausted: true} =
               DispatchLedger.prune_trace_events(ctx.tenant_id, DateTime.utc_now(),
                 batch_size: 2,
                 budget: 4
               )
    end

    test "a batch smaller than the work still drains it inside one run", ctx do
      assert %{deleted: 5, budget_exhausted: false} =
               DispatchLedger.prune_trace_events(ctx.tenant_id, DateTime.utc_now(), batch_size: 2)

      assert trace_seqs(ctx.tenant_id, ctx.dispatch) == []
    end

    test "the default budget is large enough not to stop on a handful of rows", ctx do
      assert %{deleted: 5, budget_exhausted: false} =
               DispatchLedger.prune_trace_events(ctx.tenant_id, DateTime.utc_now())

      assert DispatchLedger.prune_budget() > 5
      assert DispatchLedger.prune_batch_size() > 0
    end
  end

  describe "intake_deliveries: the retention window, through the whole worker" do
    setup do
      {secret, source} = fixture(:intake_source, %{})
      %{secret: secret, source: source, tenant_id: source.tenant_id}
    end

    test "deletes deliveries past the window and keeps deliveries inside it", ctx do
      fixture(:intake_delivery, %{
        source: ctx.source,
        github_delivery_id: "old",
        inserted_at: ago(200)
      })

      fixture(:intake_delivery, %{
        source: ctx.source,
        github_delivery_id: "recent",
        inserted_at: ago(10)
      })

      assert :ok = run()
      assert delivery_ids(ctx.tenant_id) == ["recent"]
    end

    test "a delivery a record still cites survives however old it is", ctx do
      assert {:ok, :recorded} = deliver(ctx.secret, ctx.source, "cited")
      :ok = backdate_delivery(ctx.tenant_id, "cited", ago(500))

      fixture(:intake_delivery, %{
        source: ctx.source,
        github_delivery_id: "uncited",
        inserted_at: ago(500)
      })

      assert [%{last_delivery_id: "cited"}] = Intake.list_records(ctx.tenant_id)

      assert :ok = run()
      assert delivery_ids(ctx.tenant_id) == ["cited"]
    end

    test "a tenant window below the redelivery floor cannot reach a replayable delivery", ctx do
      # Twenty days old: still inside GitHub's ~30-day history, so still replayable.
      fixture(:intake_delivery, %{
        source: ctx.source,
        github_delivery_id: "replayable",
        inserted_at: ago(20)
      })

      fixture(:intake_delivery, %{
        source: ctx.source,
        github_delivery_id: "past-the-floor",
        inserted_at: ago(45)
      })

      tenant = tenant_struct(ctx.tenant_id, %{"intake_delivery_retention_days" => 1})

      assert %{intake: %{deleted: 1}} =
               DeliveryLoopPruneWorker.prune_tenant(tenant, DateTime.utc_now())

      assert delivery_ids(ctx.tenant_id) == ["replayable"]
      assert DeliveryLoopPruneWorker.min_intake_retention_days() == 30

      assert DeliveryLoopPruneWorker.default_intake_retention_days() >
               DeliveryLoopPruneWorker.min_intake_retention_days()
    end

    test "another tenant's deliveries are never touched", ctx do
      {_secret, other} = fixture(:intake_source, %{})

      fixture(:intake_delivery, %{
        source: ctx.source,
        github_delivery_id: "mine",
        inserted_at: ago(200)
      })

      fixture(:intake_delivery, %{
        source: other,
        github_delivery_id: "theirs",
        inserted_at: ago(200)
      })

      assert %{intake: %{deleted: 1}} =
               DeliveryLoopPruneWorker.prune_tenant(
                 tenant_struct(ctx.tenant_id),
                 DateTime.utc_now()
               )

      assert delivery_ids(ctx.tenant_id) == []
      assert delivery_ids(other.tenant_id) == ["theirs"]
    end

    test "a pruned delivery id is no longer idempotency evidence, which is why the floor exists",
         ctx do
      # Ignored (not `issues`), so the delivery row is the whole record of it and no
      # `last_delivery_id` protects it.
      raw = Jason.encode!(build(:github_issues_payload, %{}))

      input = %{
        raw_body: raw,
        signature: Signature.header(ctx.secret, raw),
        event: "push",
        delivery_id: "replayed",
        content_type: "application/json"
      }

      assert {:ok, :ignored} = Intake.receive_github_delivery(ctx.source.id, input)
      assert {:ok, :duplicate} = Intake.receive_github_delivery(ctx.source.id, input)

      :ok = backdate_delivery(ctx.tenant_id, "replayed", ago(200))

      assert %{intake: %{deleted: 1}} =
               DeliveryLoopPruneWorker.prune_tenant(
                 tenant_struct(ctx.tenant_id),
                 DateTime.utc_now()
               )

      # The row IS what made the replay a no-op. Past the window GitHub can no longer send
      # it; inside the window `min_intake_retention_days/0` is what keeps this from
      # happening to a delivery that can still arrive.
      assert {:ok, :ignored} = Intake.receive_github_delivery(ctx.source.id, input)
    end

    test "the run stops at its budget and resumes", ctx do
      for n <- 1..4 do
        fixture(:intake_delivery, %{
          source: ctx.source,
          github_delivery_id: "d#{n}",
          inserted_at: ago(200 + n)
        })
      end

      tenant = tenant_struct(ctx.tenant_id)
      opts = [batch_size: 1, budget: 3]

      assert %{intake: %{deleted: 3, budget_exhausted: true}} =
               DeliveryLoopPruneWorker.prune_tenant(tenant, DateTime.utc_now(), opts)

      assert delivery_ids(ctx.tenant_id) == ["d1"]

      assert %{intake: %{deleted: 1, budget_exhausted: false}} =
               DeliveryLoopPruneWorker.prune_tenant(tenant, DateTime.utc_now(), opts)

      assert Intake.prune_budget() > 4
    end

    test "a tenant with exactly its budget of deliveries is NOT reported at budget", ctx do
      for n <- 1..3 do
        fixture(:intake_delivery, %{
          source: ctx.source,
          github_delivery_id: "f#{n}",
          inserted_at: ago(200 + n)
        })
      end

      assert %{deleted: 3, budget_exhausted: false} =
               Intake.prune_deliveries(ctx.tenant_id, DateTime.utc_now(),
                 batch_size: 2,
                 budget: 3
               )

      assert delivery_ids(ctx.tenant_id) == []
    end

    test "the budget caps the last delivery batch, so a run never overshoots it", ctx do
      for n <- 1..4 do
        fixture(:intake_delivery, %{
          source: ctx.source,
          github_delivery_id: "e#{n}",
          inserted_at: ago(200 + n)
        })
      end

      assert %{deleted: 2, budget_exhausted: true} =
               Intake.prune_deliveries(ctx.tenant_id, DateTime.utc_now(),
                 batch_size: 10,
                 budget: 2
               )

      assert delivery_ids(ctx.tenant_id) == ["e2", "e1"]
    end
  end

  describe "a window an operator actually persisted" do
    test "perform/1 reads the window out of tenants.settings, not just a struct in a test" do
      # Every other window case hand-builds the struct. This one persists the setting and
      # drives the whole worker, so the KEY the code reads is bound to the key an operator
      # writes: rename one and this is the test that notices.
      tenant = fixture(:tenant, %{settings: %{"intake_delivery_retention_days" => 40}})
      {_secret, source} = fixture(:intake_source, %{tenant_id: tenant.id})

      fixture(:intake_delivery, %{
        source: source,
        github_delivery_id: "past-forty",
        inserted_at: ago(50)
      })

      # Inside the tenant's 40 days, outside nothing: the DEFAULT of 90 would have kept both,
      # so seeing exactly one go proves the persisted setting is what took effect.
      fixture(:intake_delivery, %{
        source: source,
        github_delivery_id: "inside-forty",
        inserted_at: ago(35)
      })

      assert :ok = run()
      assert delivery_ids(tenant.id) == ["inside-forty"]
    end

    test "a window above the ceiling is capped rather than handed to Postgres", ctx_free do
      _ = ctx_free
      story = fixture(:stage_story, %{})
      runner = fixture(:stage_runner, %{tenant_id: story.tenant_id})
      dispatch = terminal_dispatch(story.tenant_id, runner)

      fixture(:trace_event, %{dispatch: dispatch, seq: 1, inserted_at: ago(4000)})
      fixture(:trace_event, %{dispatch: dispatch, seq: 2, inserted_at: ago(3000)})

      # A DATE pasted where a day count belongs. Uncapped, the cutoff is ~55,000 years back,
      # which is outside timestamptz and makes Postgres refuse the query.
      tenant = tenant_struct(story.tenant_id, %{"runner_trace_retention_days" => 20_260_918})

      assert %{trace: %{deleted: 1, failed: 0}} =
               DeliveryLoopPruneWorker.prune_tenant(tenant, DateTime.utc_now())

      # Capped at the ceiling, so the 4000-day row went and the 3000-day one stayed.
      assert trace_seqs(story.tenant_id, dispatch) == [2]
      assert DeliveryLoopPruneWorker.max_retention_days() == 3650
    end
  end

  describe "a prune that fails" do
    setup do
      story = fixture(:stage_story, %{})
      runner = fixture(:stage_runner, %{tenant_id: story.tenant_id})
      dispatch = terminal_dispatch(story.tenant_id, runner)
      fixture(:trace_event, %{dispatch: dispatch, seq: 1, inserted_at: ago(30)})

      %{tenant_id: story.tenant_id, dispatch: dispatch}
    end

    test "is contained to its own table: it is counted, not raised, and the other half runs",
         ctx do
      {_secret, source} = fixture(:intake_source, %{})

      fixture(:intake_delivery, %{
        source: source,
        github_delivery_id: "unaffected",
        inserted_at: ago(200)
      })

      # A negative LIMIT is a Postgrex error the moment the first batch runs — the cheapest
      # real database failure to provoke, and NOT a transient one, so it is a hard failure.
      result =
        DeliveryLoopPruneWorker.prune_tenant(
          %Tenant{id: ctx.tenant_id, settings: %{}},
          DateTime.utc_now(),
          batch_size: -1
        )

      assert %{trace: %{deleted: 0, failed: 1, hard_failed: 1, budget_exhausted: false}} = result

      # The trace half of this tenant blew up and the trace rows are untouched...
      assert trace_seqs(ctx.tenant_id, ctx.dispatch) == [1]

      # ...and the intake half of the SAME call still ran, which is the property the whole
      # per-unit guard exists for. (Its own delete then failed on the same negative LIMIT, so
      # it is counted too rather than silently passing.)
      assert %{intake: %{failed: 1, hard_failed: 1}} = result
      assert delivery_ids(source.tenant_id) == ["unaffected"]
    end

    test "does not stop the fold, and the run still reports what it managed" do
      # TWO tenants, both of whose prunes will fail. `tenants_failed == 2` is the assertion
      # that matters: the fold reached the second tenant. Without the guard the first raise
      # escapes, and since `Tenants.list_tenants/1` orders by name it is deterministically
      # the same later tenants that are never pruned, hourly and for ever.
      {_s1, one} = fixture(:intake_source, %{})
      {_s2, two} = fixture(:intake_source, %{})

      for source <- [one, two] do
        fixture(:intake_delivery, %{
          source: source,
          github_delivery_id: "keep-#{source.tenant_id}",
          inserted_at: ago(200)
        })
      end

      ref = :telemetry_test.attach_event_handlers(self(), [[:loopctl, :delivery_loop, :prune]])
      on_exit(fn -> :telemetry.detach(ref) end)

      assert {:error, message} =
               DeliveryLoopPruneWorker.perform(%Oban.Job{args: %{"batch_size" => -1}})

      assert message =~ "non-retryable"

      assert_receive {[:loopctl, :delivery_loop, :prune], ^ref, intake,
                      %{
                        table: "intake_deliveries"
                      }}

      assert_receive {[:loopctl, :delivery_loop, :prune], ^ref, trace,
                      %{
                        table: "runner_trace_events"
                      }}

      # Emitted DESPITE the failures, and carrying them.
      assert intake.tenants_failed == 2
      assert trace.tenants_failed == 2
      assert intake.deleted == 0

      # And nothing was deleted on the way.
      assert delivery_ids(one.tenant_id) == ["keep-#{one.tenant_id}"]
      assert delivery_ids(two.tenant_id) == ["keep-#{two.tenant_id}"]
    end

    test "a later valid run over the same tenant still prunes", ctx do
      _ =
        DeliveryLoopPruneWorker.prune_tenant(
          %Tenant{id: ctx.tenant_id, settings: %{}},
          DateTime.utc_now(),
          batch_size: -1
        )

      assert %{trace: %{deleted: 1, failed: 0, hard_failed: 0}} =
               DeliveryLoopPruneWorker.prune_tenant(
                 tenant_struct(ctx.tenant_id),
                 DateTime.utc_now()
               )
    end
  end

  describe "reporting" do
    test "one telemetry event per table carries the rows deleted and the tenants at budget" do
      {_secret, source} = fixture(:intake_source, %{})

      fixture(:intake_delivery, %{
        source: source,
        github_delivery_id: "old",
        inserted_at: ago(200)
      })

      ref = :telemetry_test.attach_event_handlers(self(), [[:loopctl, :delivery_loop, :prune]])
      on_exit(fn -> :telemetry.detach(ref) end)

      assert :ok = run()

      assert_receive {[:loopctl, :delivery_loop, :prune], ^ref, intake_measurements,
                      %{table: "intake_deliveries"}}

      assert_receive {[:loopctl, :delivery_loop, :prune], ^ref, trace_measurements,
                      %{table: "runner_trace_events"}}

      assert intake_measurements.deleted == 1
      assert intake_measurements.tenants_at_budget == 0
      assert intake_measurements.tenants_failed == 0
      assert intake_measurements.tenants >= 1
      assert is_integer(intake_measurements.duration_ms)

      # Same run, same shape, its own count: the trace table has nothing on this connection.
      assert trace_measurements.deleted == 0
      assert trace_measurements.tenants_at_budget == 0
    end
  end
end
