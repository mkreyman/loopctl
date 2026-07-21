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
end
