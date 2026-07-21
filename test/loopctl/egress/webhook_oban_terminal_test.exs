defmodule Loopctl.Egress.WebhookObanTerminalTest do
  @moduledoc """
  US-41.5 (AC-41.5.2, TC-41.5.5) — a blocked webhook delivery is TERMINAL.

  The `:webhooks` queue is `max_attempts: 1` with APP-LEVEL snooze retries, so a
  refusal that took the ordinary failure path would re-enter the backoff ladder
  and sit `scheduled` for hours, once per event, against a configuration that
  cannot change on its own. This file proves the consequence: a batch of events
  against a blocked subscription leaves NO retry backlog and issues NO request.

  `async: false`: the drain runs jobs through the real Oban queue (inserted under
  a process-scoped `:manual` testing mode) and the counts asserted are queue-wide.
  """

  use Loopctl.DataCase, async: false
  use Oban.Testing, repo: Loopctl.Repo

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Egress
  alias Loopctl.Egress.PinCache
  alias Loopctl.Webhooks.WebhookEvent
  alias Loopctl.Workers.WebhookDeliveryWorker

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant)
    on_exit(fn -> PinCache.invalidate_tenant(tenant.id) end)

    webhook =
      fixture(:webhook, %{
        tenant_id: tenant.id,
        url: "https://hooks.example.com/inbound",
        events: ["story.status_changed"]
      })

    {:ok, _} = Egress.enable_local_only(tenant.id, nil, acknowledge: true)
    PinCache.invalidate_tenant(tenant.id)

    test_pid = self()

    Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
      send(test_pid, :unexpected_http_call)
      Req.Test.json(conn, %{"ok" => true})
    end)

    {:ok, tenant: tenant, webhook: webhook}
  end

  defp job_states(queue) do
    Loopctl.Repo.all(
      from j in "oban_jobs",
        where: j.queue == ^queue,
        group_by: j.state,
        select: {j.state, count(j.id)}
    )
    |> Map.new()
  end

  # Drains until the queue holds no runnable job, returning the number of passes
  # it took. Bounded so a job that never terminates FAILS the test instead of
  # hanging the suite.
  defp drain_until_settled(max_passes, pass \\ 0) do
    drained = Oban.drain_queue(queue: :webhooks, with_scheduled: true)
    executed = Map.get(drained, :snoozed, 0) + Map.get(drained, :success, 0)

    cond do
      executed == 0 -> pass
      pass + 1 >= max_passes -> max_passes
      true -> drain_until_settled(max_passes, pass + 1)
    end
  end

  test "several blocked deliveries leave NO retry backlog", %{tenant: tenant, webhook: webhook} do
    events =
      for _i <- 1..5 do
        fixture(:webhook_event, %{
          tenant_id: tenant.id,
          webhook_id: webhook.id,
          event_type: "story.status_changed",
          payload: %{"event" => "story.status_changed"},
          status: :pending
        })
      end

    Oban.Testing.with_testing_mode(:manual, fn ->
      for event <- events do
        {:ok, _} =
          %{"webhook_event_id" => event.id, "tenant_id" => tenant.id}
          |> WebhookDeliveryWorker.new()
          |> Oban.insert()
      end

      assert 5 == Enum.count(all_enqueued(worker: WebhookDeliveryWorker))

      drained = Oban.drain_queue(queue: :webhooks)

      # Blocked is TERMINAL and CLEAN: the job succeeded at doing the right thing
      # (recording the refusal), so it neither fails nor snoozes.
      assert Map.get(drained, :success, 0) == 5
      assert Map.get(drained, :failure, 0) == 0
      assert Map.get(drained, :snoozed, 0) == 0

      states = job_states("webhooks")
      assert Map.get(states, "retryable", 0) == 0
      assert Map.get(states, "available", 0) == 0
      assert Map.get(states, "scheduled", 0) == 0
    end)

    # No data ever left the boundary.
    refute_received :unexpected_http_call

    # Every event is blocked, and no attempt was burned on any of them.
    blocked =
      AdminRepo.all(
        from e in WebhookEvent, where: e.tenant_id == ^tenant.id, select: {e.status, e.attempts}
      )

    assert length(blocked) == 5
    assert Enum.all?(blocked, &(&1 == {:blocked, 0}))
  end

  # REVIEW FIX (AC-41.5.2). The TRANSIENT branch snoozed unconditionally, and on a
  # `max_attempts: 1` queue every snooze also bumps `max_attempts` — so a
  # destination that can never be classified (lapsed domain, NXDOMAIN, resolve
  # timeout) produced an IMMORTAL job per event. Draining `with_scheduled: true`
  # is the end-to-end proof: under the old code this test would never terminate.
  test "a permanently-unresolvable destination TERMINATES instead of snoozing forever" do
    tenant = fixture(:tenant)
    on_exit(fn -> PinCache.invalidate_tenant(tenant.id) end)

    # No local_only marking: this is the DEFAULT posture, where a tenant-supplied
    # url that cannot be classified fails closed as the TRANSIENT
    # `:egress_unavailable` on every single attempt.
    stub(Loopctl.MockDnsResolver, :resolve, fn _host -> {:error, :nxdomain} end)

    webhook =
      fixture(:webhook, %{
        tenant_id: tenant.id,
        url: "https://lapsed.example.invalid/inbound",
        events: ["story.status_changed"]
      })

    event =
      fixture(:webhook_event, %{
        tenant_id: tenant.id,
        webhook_id: webhook.id,
        event_type: "story.status_changed",
        payload: %{"event" => "story.status_changed"},
        status: :pending
      })

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _} =
        %{"webhook_event_id" => event.id, "tenant_id" => tenant.id}
        |> WebhookDeliveryWorker.new()
        |> Oban.insert()

      # Each drain pass runs the jobs that exist NOW (snoozes re-schedule into the
      # future), so drain repeatedly. The BOUND is what is under test: the job must
      # stop needing passes. Under the old unconditional snooze it never would —
      # the loop would exhaust its cap with the job still scheduled.
      passes = drain_until_settled(20)

      assert passes < 20, "the job never reached a terminal state (unbounded snooze)"

      states = job_states("webhooks")
      assert Map.get(states, "scheduled", 0) == 0
      assert Map.get(states, "available", 0) == 0
      assert Map.get(states, "retryable", 0) == 0
    end)

    refute_received :unexpected_http_call

    # The event reached the ordinary ladder's end...
    reloaded = AdminRepo.get!(WebhookEvent, event.id)
    assert reloaded.status == :exhausted
    assert reloaded.attempts == 6
    assert reloaded.error =~ "egress_unavailable_persisted"

    # ...and the auto-disable safety valve — dead while the snooze was unbounded —
    # is reachable again.
    assert AdminRepo.get!(Loopctl.Webhooks.Webhook, webhook.id).consecutive_failures == 1
  end
end
