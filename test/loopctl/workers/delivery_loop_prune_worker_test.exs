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

      assert %{trace: %{deleted: 0, failed: 1, budget_exhausted: false}} = result

      # The trace half of this tenant blew up and the trace rows are untouched...
      assert trace_seqs(ctx.tenant_id, ctx.dispatch) == [1]

      # ...and the intake half of the SAME call still ran, which is the property the whole
      # per-unit guard exists for. (Its own delete then failed on the same negative LIMIT, so
      # it is counted too rather than silently passing.)
      assert %{intake: %{failed: 1}} = result
      assert delivery_ids(source.tenant_id) == ["unaffected"]
    end

    test "carries the rows the batches BEFORE it already committed", ctx do
      # Four more events, five in all, and a budget that runs out MID-LOOP: the third batch's
      # `take` is 0.5, which Postgres refuses. Two batches have committed by then, and their
      # count is what a run must not throw away — a long run is mostly already-committed
      # batches, so discarding them reports zero deleted on the run that deleted the most.
      for seq <- 2..5,
          do: fixture(:trace_event, %{dispatch: ctx.dispatch, seq: seq, inserted_at: ago(30)})

      assert %{trace: %{deleted: 4, failed: 1}} =
               DeliveryLoopPruneWorker.prune_tenant(
                 tenant_struct(ctx.tenant_id),
                 DateTime.utc_now(),
                 batch_size: 2,
                 budget: 4.5
               )

      # Exactly the four the two committed batches took, and the fifth is still there.
      assert length(trace_seqs(ctx.tenant_id, ctx.dispatch)) == 1
    end

    test "carries the delivery rows its committed batches took, too" do
      {_secret, source} = fixture(:intake_source, %{})

      for n <- 1..5 do
        fixture(:intake_delivery, %{
          source: source,
          github_delivery_id: "h#{n}",
          inserted_at: ago(200 + n)
        })
      end

      assert %{intake: %{deleted: 4, failed: 1}} =
               DeliveryLoopPruneWorker.prune_tenant(
                 %Tenant{id: source.tenant_id, settings: %{}},
                 DateTime.utc_now(),
                 batch_size: 2,
                 budget: 4.5
               )

      assert length(delivery_ids(source.tenant_id)) == 1
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

      tenants = for s <- [one, two], do: %Tenant{id: s.tenant_id, settings: %{}}

      assert {:error, message} =
               DeliveryLoopPruneWorker.run(tenants, DateTime.utc_now(), batch_size: -1)

      # EVERY unit failed, which is an outage rather than a broken tenant — that one is the
      # job's to report, so Oban's backoff becomes its retry.
      assert message =~ "every one of"

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

    test "one broken tenant does NOT discard the run — tenants_failed carries it", ctx do
      # A partial failure returning an error undid the isolation: the job discarded, Oban
      # re-ran the whole fan-out three times an hour re-pruning every healthy tenant with a
      # fresh full budget, and the exception events biased the fleet-wide discard rate, where
      # a discard means something else entirely.
      {_secret, healthy} = fixture(:intake_source, %{})

      fixture(:intake_delivery, %{
        source: healthy,
        github_delivery_id: "healthy",
        inserted_at: ago(200)
      })

      # Four more trace events, five in all, so the fractional budget's THIRD batch faults —
      # while every other unit in the run (this tenant's empty intake half, and the healthy
      # tenant's two halves) completes. Exactly one unit of four fails.
      for seq <- 2..5,
          do: fixture(:trace_event, %{dispatch: ctx.dispatch, seq: seq, inserted_at: ago(30)})

      broken = tenant_struct(ctx.tenant_id)
      ok = %Tenant{id: healthy.tenant_id, settings: %{}}

      ref = :telemetry_test.attach_event_handlers(self(), [[:loopctl, :delivery_loop, :prune]])
      on_exit(fn -> :telemetry.detach(ref) end)

      assert :ok =
               DeliveryLoopPruneWorker.run([broken, ok], DateTime.utc_now(),
                 batch_size: 2,
                 budget: 4.5
               )

      assert_receive {[:loopctl, :delivery_loop, :prune], ^ref, intake,
                      %{
                        table: "intake_deliveries"
                      }}

      assert_receive {[:loopctl, :delivery_loop, :prune], ^ref, trace,
                      %{
                        table: "runner_trace_events"
                      }}

      assert trace.tenants_failed == 1, "the broken unit is counted"
      assert intake.tenants_failed == 0
      assert intake.deleted == 1, "the healthy tenant was still pruned"
      assert delivery_ids(healthy.tenant_id) == []
    end

    test "a later valid run over the same tenant still prunes", ctx do
      _ =
        DeliveryLoopPruneWorker.prune_tenant(
          %Tenant{id: ctx.tenant_id, settings: %{}},
          DateTime.utc_now(),
          batch_size: -1
        )

      assert %{trace: %{deleted: 1, failed: 0}} =
               DeliveryLoopPruneWorker.prune_tenant(
                 tenant_struct(ctx.tenant_id),
                 DateTime.utc_now()
               )
    end
  end

  describe "the operator's job args" do
    test "a positive integer is taken; anything else is ignored" do
      assert DeliveryLoopPruneWorker.prune_opts(%{"batch_size" => 10, "budget" => 20}) == [
               batch_size: 10,
               budget: 20
             ]

      # Term order is why each of these matters: `min("1000", 20_000)` is 20_000 and
      # `0 >= "1"` is false, so an unvalidated value is not refused — it silently becomes the
      # whole budget, or runs the loop to an ArithmeticError.
      for bad <- ["1000", nil, 0, -1, 2.5, %{"n" => 5}, [5]] do
        assert DeliveryLoopPruneWorker.prune_opts(%{"batch_size" => bad, "budget" => bad}) == [],
               "#{inspect(bad)} must not reach the prune"
      end

      assert DeliveryLoopPruneWorker.prune_opts(%{}) == []
      assert DeliveryLoopPruneWorker.prune_opts(%{"other" => 1}) == []
      assert DeliveryLoopPruneWorker.prune_opts(nil) == []
    end

    test "BOTH halves cap the override at their own constants" do
      huge = [batch_size: 100_000, budget: 500_000]

      # The trace half too. Uncapped, `batch_size: 20_000` is one SELECT FOR UPDATE of 20,000
      # rows and one DELETE of 20,000 in a single transaction — which usually exceeds the
      # statement timeout, rolls back, is read as contention, retries identically and fails,
      # so that tenant prunes nothing at all, hourly.
      assert DeliveryLoopPruneWorker.trace_opts(huge) == [
               batch_size: DispatchLedger.prune_batch_size(),
               budget: DispatchLedger.prune_budget()
             ]

      assert DeliveryLoopPruneWorker.intake_opts(huge) == [
               batch_size: Intake.prune_batch_size(),
               budget: Intake.prune_budget()
             ]

      # The knob only ever makes a run SMALLER: below the ceiling the operator's value stands,
      # an unknown option passes through, and both keys are always set (the retry subtracts
      # from `:budget`, so it has to be there).
      assert DeliveryLoopPruneWorker.intake_opts(batch_size: 5, budget: 7, other: :x) == [
               batch_size: 5,
               budget: 7,
               other: :x
             ]

      assert DeliveryLoopPruneWorker.trace_opts([]) == [
               batch_size: DispatchLedger.prune_batch_size(),
               budget: DispatchLedger.prune_budget()
             ]
    end

    test "a trace-sized override cannot put one huge DELETE on the RLS pool" do
      story = fixture(:stage_story, %{})
      runner = fixture(:stage_runner, %{tenant_id: story.tenant_id})
      dispatch = terminal_dispatch(story.tenant_id, runner)

      for seq <- 1..3,
          do: fixture(:trace_event, %{dispatch: dispatch, seq: seq, inserted_at: ago(30)})

      # The capped batch is what runs, so the rows still go — the cap bounds the STATEMENT,
      # not the work. What it forbids is the single 20,000-row transaction.
      assert %{trace: %{deleted: 3, failed: 0}} =
               DeliveryLoopPruneWorker.prune_tenant(
                 tenant_struct(story.tenant_id),
                 DateTime.utc_now(),
                 batch_size: 20_000,
                 budget: 1_000_000
               )

      assert DispatchLedger.prune_batch_size() < 20_000
      assert DispatchLedger.prune_budget() < 1_000_000
    end

    test "a trace-sized drain override does not run unbounded against the admin pool" do
      # The ceiling is only OBSERVABLE past itself, so this test crosses it: one more delivery
      # than the intake budget allows. Uncapped, the override's 500,000 takes them all in one
      # run against the three-connection pool; capped, the run stops at the budget and says so.
      {_secret, source} = fixture(:intake_source, %{})
      over = Intake.prune_budget() + 1
      fixture(:intake_deliveries, %{source: source, count: over, inserted_at: ago(200)})

      assert %{intake: %{deleted: deleted, budget_exhausted: true}} =
               DeliveryLoopPruneWorker.prune_tenant(
                 %Tenant{id: source.tenant_id, settings: %{}},
                 DateTime.utc_now(),
                 batch_size: 100_000,
                 budget: 500_000
               )

      assert deleted == Intake.prune_budget()
      assert length(delivery_ids(source.tenant_id)) == 1
    end
  end

  describe "the in-run retry (attempt_prune/5, with an injected prune)" do
    setup do
      %{tenant: %Tenant{id: Ecto.UUID.generate(), settings: %{}}}
    end

    defp injected(results) do
      {:ok, agent} = Agent.start_link(fn -> {results, []} end)

      fun = fn opts ->
        Agent.get_and_update(agent, fn {[head | rest], seen} ->
          {head, {rest, seen ++ [opts]}}
        end)
      end

      {fun, fn -> Agent.get(agent, fn {_rest, seen} -> seen end) end}
    end

    @contention %Postgrex.Error{postgres: %{code: :lock_not_available}}

    test "the retry gets the budget MINUS what the first attempt already deleted", ctx do
      # Re-invoking a closure with the budget baked in let one tenant and table delete up to
      # TWICE its budget in a run — the second helping against a pool that had just reported
      # contention.
      {fun, calls} =
        injected([
          %{deleted: 30, budget_exhausted: false, error: @contention},
          %{deleted: 12, budget_exhausted: false, error: nil}
        ])

      assert %{deleted: 42, failed: 0, budget_exhausted: false} =
               DeliveryLoopPruneWorker.attempt_prune(
                 "runner_trace_events",
                 ctx.tenant,
                 14,
                 [batch_size: 10, budget: 100],
                 fun
               )

      assert [first, second] = calls.()
      assert first[:budget] == 100
      assert second[:budget] == 70
      assert second[:batch_size] == 10
    end

    test "the remaining budget floors at zero rather than going negative", ctx do
      {fun, calls} =
        injected([
          %{deleted: 100, budget_exhausted: false, error: @contention},
          %{deleted: 0, budget_exhausted: false, error: nil}
        ])

      assert %{deleted: 100, failed: 0} =
               DeliveryLoopPruneWorker.attempt_prune(
                 "runner_trace_events",
                 ctx.tenant,
                 14,
                 [batch_size: 10, budget: 100],
                 fun
               )

      assert [_first, second] = calls.()
      assert second[:budget] == 0
    end

    test "a second contention fault ends it, counted, with both attempts' rows", ctx do
      {fun, calls} =
        injected([
          %{deleted: 30, budget_exhausted: false, error: @contention},
          %{deleted: 5, budget_exhausted: false, error: @contention}
        ])

      assert %{deleted: 35, failed: 1} =
               DeliveryLoopPruneWorker.attempt_prune(
                 "runner_trace_events",
                 ctx.tenant,
                 14,
                 [batch_size: 10, budget: 100],
                 fun
               )

      assert length(calls.()) == 2, "a contention fault gets exactly one retry, not more"
    end

    test "a connection-class fault is NOT retried in-run", ctx do
      # The backend or pool is gone; an immediate retry cannot clear it, and spending the
      # attempt only brings the failure forward. `backoff/1` is its retry.
      {fun, calls} =
        injected([
          %{deleted: 7, budget_exhausted: false, error: %DBConnection.ConnectionError{}},
          %{deleted: 999, budget_exhausted: false, error: nil}
        ])

      assert %{deleted: 7, failed: 1} =
               DeliveryLoopPruneWorker.attempt_prune(
                 "intake_deliveries",
                 ctx.tenant,
                 90,
                 [batch_size: 10, budget: 100],
                 fun
               )

      assert length(calls.()) == 1
    end

    test "a failed probe's conservative budget_exhausted survives the failure", ctx do
      # Both prune loops set it true when the PROBE faulted, because a probe that could not
      # run cannot say the backlog is empty. Hard-coding false there threw that away.
      {fun, _calls} =
        injected([%{deleted: 4, budget_exhausted: true, error: %RuntimeError{message: "x"}}])

      assert %{deleted: 4, failed: 1, budget_exhausted: true} =
               DeliveryLoopPruneWorker.attempt_prune(
                 "runner_trace_events",
                 ctx.tenant,
                 14,
                 [batch_size: 10, budget: 100],
                 fun
               )
    end
  end

  describe "verdict/2 (the pure retry decision)" do
    # A real lock wait needs a second connection holding the row, and the SQL sandbox gives a
    # test one connection per repo — so the branch a transient fault takes is exercised here,
    # against synthesized errors, rather than by provoking one.
    @contention_errors [
      %Postgrex.Error{postgres: %{code: :lock_not_available}},
      %Postgrex.Error{postgres: %{code: :deadlock_detected}},
      %Postgrex.Error{postgres: %{code: :query_canceled}},
      %Postgrex.Error{postgres: %{code: :serialization_failure}}
    ]

    @connection_errors [
      %DBConnection.ConnectionError{message: "pool is down"},
      {:exit, :killed},
      %Postgrex.Error{postgres: %{code: :admin_shutdown}},
      %Postgrex.Error{postgres: %{code: :crash_shutdown}},
      %Postgrex.Error{postgres: %{code: :cannot_connect_now}}
    ]

    test "CONTENTION is retried once, then treated like any other failure" do
      for error <- @contention_errors do
        assert DeliveryLoopPruneWorker.verdict(error, 1) == :retry,
               "#{inspect(error)} is another transaction's doing and can be gone in ms"

        # THE bound. Without it a deterministic 15-second timeout is 'transient' for ever:
        # retried hourly, job green, every alert metric at zero.
        assert DeliveryLoopPruneWorker.verdict(error, 2) == :fail,
               "#{inspect(error)} must not be retried a second time"
      end
    end

    test "a CONNECTION-class fault is never retried in-run — backoff/1 is its retry" do
      # The backend or pool is gone, so an immediate retry cannot clear it: it spends the
      # attempt for nothing and brings the failure forward. With Oban's default backoff that
      # discarded the job inside a minute, which is shorter than a rolling deploy.
      for error <- @connection_errors do
        assert DeliveryLoopPruneWorker.verdict(error, 1) == :fail,
               "#{inspect(error)} cannot clear on an immediate retry"

        assert DeliveryLoopPruneWorker.connection_fault?(error),
               "#{inspect(error)} must be logged as the connection class, not as contention"
      end

      for error <- @contention_errors do
        refute DeliveryLoopPruneWorker.connection_fault?(error)
      end
    end

    test "anything else fails on the first attempt, with no retry" do
      for error <- [
            %Postgrex.Error{postgres: %{code: :invalid_text_representation}},
            %ArgumentError{message: "bad"},
            %RuntimeError{message: "boom"}
          ] do
        assert DeliveryLoopPruneWorker.verdict(error, 1) == :fail,
               "#{inspect(error)} is not contention and must not be retried"
      end
    end

    test "the backoff is minutes, so a rolling deploy outlasts nothing" do
      assert DeliveryLoopPruneWorker.backoff(%Oban.Job{attempt: 1}) == 60
      assert DeliveryLoopPruneWorker.backoff(%Oban.Job{attempt: 4}) == 240
    end
  end

  describe "the run's wall clock" do
    test "a run past its deadline stops, says how many it did not reach, and stays :ok" do
      {_secret, source} = fixture(:intake_source, %{})

      fixture(:intake_delivery, %{
        source: source,
        github_delivery_id: "untouched",
        inserted_at: ago(200)
      })

      tenants = [%Tenant{id: source.tenant_id, settings: %{}}]

      ref = :telemetry_test.attach_event_handlers(self(), [[:loopctl, :delivery_loop, :prune]])
      on_exit(fn -> :telemetry.detach(ref) end)

      # A deadline already spent: every tenant is skipped rather than the run holding a
      # :cleanup slot for hours. Nothing failed, so the job is still :ok.
      assert :ok = DeliveryLoopPruneWorker.run(tenants, DateTime.utc_now(), deadline_ms: -1)

      assert_receive {[:loopctl, :delivery_loop, :prune], ^ref, intake,
                      %{
                        table: "intake_deliveries"
                      }}

      assert intake.tenants_skipped == 1
      assert intake.tenants == 0
      assert intake.deleted == 0
      assert delivery_ids(source.tenant_id) == ["untouched"]
    end

    test "a run inside its deadline reaches everyone and skips nobody" do
      {_secret, source} = fixture(:intake_source, %{})

      fixture(:intake_delivery, %{
        source: source,
        github_delivery_id: "old",
        inserted_at: ago(200)
      })

      ref = :telemetry_test.attach_event_handlers(self(), [[:loopctl, :delivery_loop, :prune]])
      on_exit(fn -> :telemetry.detach(ref) end)

      assert :ok = run()

      assert_receive {[:loopctl, :delivery_loop, :prune], ^ref, intake,
                      %{
                        table: "intake_deliveries"
                      }}

      assert intake.tenants_skipped == 0
      assert intake.deleted == 1
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
