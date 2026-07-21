defmodule Loopctl.Egress.WebhookEgressTest do
  @moduledoc """
  US-41.5 — webhook delivery under the ONE egress policy.

  Covers TC-41.5.1 (local_only blocks a public destination), TC-41.5.2
  (allowlisted / tenant-declared destinations still deliver, plus the SSRF
  control case), TC-41.5.3 (config-time rejection), TC-41.5.4 (pre-existing
  subscriptions surfaced on enable), TC-41.5.6 (blocked records are
  tenant-isolated) and the AC-41.5.5 posture extension.

  TC-41.5.5 (no unbounded retry backlog) needs the real Oban queue and lives in
  `Loopctl.Egress.WebhookObanTerminalTest`.
  """

  use Loopctl.DataCase, async: true

  import Mox

  alias Loopctl.AdminRepo
  alias Loopctl.Egress
  alias Loopctl.Egress.PinCache
  alias Loopctl.Egress.Scope
  alias Loopctl.Test.AllowlistSource
  alias Loopctl.Webhooks
  alias Loopctl.Webhooks.WebhookEvent
  alias Loopctl.Workers.WebhookDeliveryWorker

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant)
    on_exit(fn -> PinCache.invalidate_tenant(tenant.id) end)
    {:ok, tenant: tenant, scope: Scope.new(tenant.id)}
  end

  # --- helpers ---------------------------------------------------------------

  defp mark_local_only(tenant_id, project_id \\ nil) do
    {:ok, _} = Egress.enable_local_only(tenant_id, project_id, acknowledge: true)
    PinCache.invalidate_tenant(tenant_id)
    :ok
  end

  defp with_allowlist(entries, fun) do
    AllowlistSource.put(entries)

    try do
      fun.()
    after
      AllowlistSource.clear()
    end
  end

  # A stub that FAILS the test if the delivery path ever issues a request.
  defp forbid_http! do
    test_pid = self()

    Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
      send(test_pid, :unexpected_http_call)
      Req.Test.json(conn, %{"ok" => true})
    end)
  end

  defp subscription(tenant_id, url, attrs \\ %{}) do
    fixture(
      :webhook,
      Map.merge(
        %{tenant_id: tenant_id, url: url, events: ["story.status_changed"]},
        attrs
      )
    )
  end

  defp pending_event(tenant_id, webhook_id) do
    fixture(:webhook_event, %{
      tenant_id: tenant_id,
      webhook_id: webhook_id,
      event_type: "story.status_changed",
      payload: %{"event" => "story.status_changed", "story_id" => Ecto.UUID.generate()},
      status: :pending
    })
  end

  defp deliver(event, tenant_id) do
    WebhookDeliveryWorker.perform(%Oban.Job{
      args: %{"webhook_event_id" => event.id, "tenant_id" => tenant_id}
    })
  end

  # --- TC-41.5.1 -------------------------------------------------------------

  describe "TC-41.5.1 — local_only blocks a public webhook destination" do
    setup %{tenant: tenant} do
      webhook = subscription(tenant.id, "https://hooks.example.com/inbound")
      :ok = mark_local_only(tenant.id)
      forbid_http!()
      {:ok, webhook: webhook, event: pending_event(tenant.id, webhook.id)}
    end

    test "NO request is issued and the delivery is recorded as blocked, not failed",
         %{tenant: tenant, event: event} do
      assert :ok = deliver(event, tenant.id)
      refute_received :unexpected_http_call

      reloaded = AdminRepo.get!(WebhookEvent, event.id)

      # Blocked is its OWN status: an operator reading failures must be able to
      # tell a configuration conflict from a flaky subscriber.
      assert reloaded.status == :blocked
      refute reloaded.status in [:failed, :exhausted]

      # ... and it is TERMINAL: no attempt burned, nothing to retry.
      assert reloaded.attempts == 0
      assert reloaded.last_attempt_at != nil
    end

    test "the recorded reason is AGENT-READABLE and names the conflict",
         %{tenant: tenant, event: event} do
      assert :ok = deliver(event, tenant.id)

      reason = AdminRepo.get!(WebhookEvent, event.id).error

      assert reason =~ "locality_denied"
      assert reason =~ "egress_blocked"
      assert reason =~ "tenant:#{tenant.id}"
      assert reason =~ "hooks.example.com"
      assert reason =~ "remediation="
    end

    test "the subscriber's consecutive_failures is NOT incremented (it never failed)",
         %{tenant: tenant, webhook: webhook, event: event} do
      assert :ok = deliver(event, tenant.id)

      assert AdminRepo.get!(Loopctl.Webhooks.Webhook, webhook.id).consecutive_failures == 0
    end

    test "the blocked decision is surfaced through the aggregated egress record",
         %{tenant: tenant, event: event} do
      assert :ok = deliver(event, tenant.id)
      :ok = Egress.flush_blocked_decisions(tenant.id)

      assert [decision] = Egress.list_blocked_decisions(tenant.id)
      assert decision.endpoint_host == "hooks.example.com"
      assert decision.reason == "non_local"
    end
  end

  # --- TC-41.5.2 -------------------------------------------------------------

  describe "TC-41.5.2 — allowlisted / tenant-declared destinations still deliver" do
    test "an OPERATOR-allowlisted private destination is deliverable under local_only",
         %{tenant: tenant} do
      webhook = subscription(tenant.id, "https://93.184.216.34/inbound")
      event = pending_event(tenant.id, webhook.id)

      # Repoint the subscription at the allowlisted loopback destination without
      # going through the context (which would reject it BEFORE the allowlist
      # entry exists — that is AC-41.5.3 working).
      webhook
      |> Ecto.Changeset.change(%{url: "http://127.0.0.1:9000/inbound"})
      |> AdminRepo.update!()

      :ok = mark_local_only(tenant.id)

      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
        Req.Test.json(conn, %{"ok" => true})
      end)

      with_allowlist(["127.0.0.1"], fn ->
        assert :ok = deliver(event, tenant.id)
      end)

      assert AdminRepo.get!(WebhookEvent, event.id).status == :delivered
    end

    # The control case: the SAME private-range host with NO allowlist entry and no
    # declaration is still refused. GHSA-jh42-wf7g-f5rg stays closed.
    test "the same private host WITHOUT an allowlist entry is still refused",
         %{tenant: tenant} do
      webhook = subscription(tenant.id, "https://93.184.216.34/inbound")

      webhook
      |> Ecto.Changeset.change(%{url: "http://127.0.0.1:9000/inbound"})
      |> AdminRepo.update!()

      event = pending_event(tenant.id, webhook.id)
      :ok = mark_local_only(tenant.id)
      forbid_http!()

      assert :ok = deliver(event, tenant.id)
      refute_received :unexpected_http_call

      reloaded = AdminRepo.get!(WebhookEvent, event.id)
      assert reloaded.status == :blocked
      # The SSRF cause, not the locality one — different remediation, different owner.
      assert reloaded.error =~ "ssrf_denied"
      assert reloaded.error =~ "OPERATOR deployment allowlist"
    end

    test "a TENANT-DECLARED host with the 'webhook' purpose is deliverable", %{tenant: tenant} do
      stub(Loopctl.MockDnsResolver, :resolve, fn
        "hooks.tenant-owned.example.com" -> {:ok, [{203, 0, 113, 10}]}
        _ -> {:ok, [{93, 184, 216, 34}]}
      end)

      webhook = subscription(tenant.id, "https://hooks.tenant-owned.example.com/inbound")
      event = pending_event(tenant.id, webhook.id)

      {:ok, _} =
        Egress.declare_trusted_endpoint(tenant.id, %{
          "host" => "hooks.tenant-owned.example.com",
          "purposes" => ["webhook"]
        })

      :ok = mark_local_only(tenant.id)

      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert :ok = deliver(event, tenant.id)
      assert AdminRepo.get!(WebhookEvent, event.id).status == :delivered
    end

    # Purpose scoping is a SECURITY invariant (AC-41.4.5 constraint 2): a host
    # declared for an Ollama INFERENCE box does not authorize POSTing tenant
    # content to it.
    test "a host declared for INFERENCE only does NOT authorize webhook delivery",
         %{tenant: tenant} do
      stub(Loopctl.MockDnsResolver, :resolve, fn
        "ollama.example.com" -> {:ok, [{203, 0, 113, 10}]}
        _ -> {:ok, [{93, 184, 216, 34}]}
      end)

      webhook = subscription(tenant.id, "https://ollama.example.com/inbound")
      event = pending_event(tenant.id, webhook.id)

      {:ok, _} =
        Egress.declare_trusted_endpoint(tenant.id, %{
          "host" => "ollama.example.com",
          "purposes" => ["inference"]
        })

      :ok = mark_local_only(tenant.id)
      forbid_http!()

      assert :ok = deliver(event, tenant.id)
      refute_received :unexpected_http_call
      assert AdminRepo.get!(WebhookEvent, event.id).status == :blocked
    end
  end

  # --- TC-41.5.3 -------------------------------------------------------------

  describe "TC-41.5.3 — an incompatible subscription is rejected at CREATION" do
    setup %{tenant: tenant} do
      :ok = mark_local_only(tenant.id)
      :ok
    end

    test "creation is rejected with a legible remediation and NOTHING is persisted",
         %{tenant: tenant} do
      assert {:error, changeset} =
               Webhooks.create_webhook(tenant.id, %{
                 "url" => "https://hooks.example.com/inbound",
                 "events" => ["story.status_changed"]
               })

      assert %{url: [message]} = errors_on(changeset)
      assert message =~ "local_only"
      assert message =~ "hooks.example.com"
      assert message =~ "webhook"
      assert message =~ "clear the local_only marking"

      assert Webhooks.count_webhooks(tenant.id) == 0
    end

    test "an UPDATE that repoints an existing subscription at a non-local host is rejected",
         %{tenant: tenant} do
      webhook = subscription(tenant.id, "https://hooks.example.com/inbound")

      assert {:error, changeset} =
               Webhooks.update_webhook(tenant.id, webhook.id, %{
                 "url" => "https://elsewhere.example.com/inbound"
               })

      assert %{url: [_message]} = errors_on(changeset)

      assert AdminRepo.get!(Loopctl.Webhooks.Webhook, webhook.id).url ==
               "https://hooks.example.com/inbound"
    end

    # A pre-existing (now incompatible) subscription must stay EDITABLE — including
    # by the very edit that fixes it. Re-classifying an unchanged url on an
    # unrelated field update would make it un-savable.
    test "an unrelated update to a pre-existing incompatible subscription still works",
         %{tenant: tenant} do
      webhook = subscription(tenant.id, "https://hooks.example.com/inbound")

      assert {:ok, updated} =
               Webhooks.update_webhook(tenant.id, webhook.id, %{"active" => false})

      refute updated.active
    end

    test "a DELIVERABLE destination is accepted under the same marking", %{tenant: tenant} do
      with_allowlist(["127.0.0.1"], fn ->
        assert {:ok, %{webhook: webhook}} =
                 Webhooks.create_webhook(tenant.id, %{
                   "url" => "http://127.0.0.1:9000/inbound",
                   "events" => ["story.status_changed"]
                 })

        assert webhook.url == "http://127.0.0.1:9000/inbound"
      end)
    end

    test "an unmarked tenant is unaffected — the default posture never rejects", %{} do
      other = fixture(:tenant)
      on_exit(fn -> PinCache.invalidate_tenant(other.id) end)

      assert {:ok, _} =
               Webhooks.create_webhook(other.id, %{
                 "url" => "https://hooks.example.com/inbound",
                 "events" => ["story.status_changed"]
               })
    end
  end

  # --- TC-41.5.4 -------------------------------------------------------------

  describe "TC-41.5.4 — pre-existing subscriptions are surfaced when enabling local_only" do
    test "the enable is REFUSED and names the offending subscription", %{tenant: tenant} do
      webhook = subscription(tenant.id, "https://hooks.example.com/inbound")

      assert {:error, {:would_block, endpoints}} = Egress.enable_local_only(tenant.id, nil)

      assert entry = Enum.find(endpoints, &(&1.kind == :webhook))
      assert entry.webhook_id == webhook.id
      assert entry.endpoint == "https://hooks.example.com/inbound"
      assert entry.verdict == "non_local"
      assert entry.active

      # Never a silent state change: nothing was marked, nothing was disabled.
      refute Egress.effective_local_only?(Scope.new(tenant.id))
      assert AdminRepo.get!(Loopctl.Webhooks.Webhook, webhook.id).active
    end

    test "acknowledge: true completes the enable and REPORTS them explicitly",
         %{tenant: tenant} do
      webhook = subscription(tenant.id, "https://hooks.example.com/inbound")

      assert {:ok, %{blocked_endpoints: blocked, marking: marking}} =
               Egress.enable_local_only(tenant.id, nil, acknowledge: true)

      assert Enum.any?(blocked, &(&1[:webhook_id] == webhook.id))
      assert "https://hooks.example.com/inbound" in marking.acknowledged_blocked_endpoints

      # The subscription is untouched — reported, never silently disabled.
      reloaded = AdminRepo.get!(Loopctl.Webhooks.Webhook, webhook.id)
      assert reloaded.active
      assert reloaded.url == "https://hooks.example.com/inbound"
    end

    test "a PROJECT marking does not report a tenant-wide (project-less) subscription",
         %{tenant: tenant} do
      project = fixture(:project, %{tenant_id: tenant.id})
      _tenant_wide = subscription(tenant.id, "https://hooks.example.com/inbound")

      scoped =
        subscription(tenant.id, "https://scoped.example.com/inbound", %{project_id: project.id})

      blocked = Egress.blocked_webhook_subscriptions(Scope.new(tenant.id, project.id))

      assert Enum.map(blocked, & &1.webhook_id) == [scoped.id]
    end
  end

  # --- TC-41.5.6 -------------------------------------------------------------

  # AC-41.5.7. This story introduced NO new table and NO new column: a blocked
  # delivery is a `webhook_events` row with `status: :blocked`, and the
  # aggregated record is an `egress_blocked_decisions` row. BOTH tables already
  # carry `tenant_id` and are created with `enable_rls/1` (ENABLE, not FORCE).
  #
  # What ACTUALLY isolates tenants on these paths is the mandatory
  # `where tenant_id == ^tenant_id` on every read — both contexts go through
  # `AdminRepo` (BYPASSRLS) by design, exactly as `Loopctl.Egress`'s moduledoc
  # states — so that is what this test proves, plus the presence of the RLS
  # policy as defence in depth. Labelling a BYPASSRLS-path test "RLS" would be a
  # lie about which control is load-bearing.
  describe "TC-41.5.6 — blocked-delivery records are tenant-isolated" do
    setup %{tenant: tenant_a} do
      tenant_b = fixture(:tenant)
      on_exit(fn -> PinCache.invalidate_tenant(tenant_b.id) end)

      webhook = subscription(tenant_a.id, "https://hooks.example.com/inbound")
      event = pending_event(tenant_a.id, webhook.id)
      :ok = mark_local_only(tenant_a.id)
      forbid_http!()

      assert :ok = deliver(event, tenant_a.id)
      :ok = Egress.flush_blocked_decisions(tenant_a.id)

      {:ok, tenant_b: tenant_b, webhook: webhook, event: event}
    end

    test "tenant B cannot read tenant A's blocked deliveries", %{
      tenant: tenant_a,
      tenant_b: tenant_b,
      webhook: webhook,
      event: event
    } do
      # The subscription itself is invisible, so its deliveries are unreachable.
      assert {:error, :not_found} = Webhooks.list_deliveries(tenant_b.id, webhook.id)

      # ... and it IS reachable for its owner, so this is isolation, not a 404 for
      # everyone.
      assert {:ok, %{data: deliveries}} = Webhooks.list_deliveries(tenant_a.id, webhook.id)
      assert [%{id: id, status: :blocked}] = deliveries
      assert id == event.id
    end

    test "tenant B cannot read tenant A's aggregated blocked decisions", %{
      tenant: tenant_a,
      tenant_b: tenant_b
    } do
      assert [_ | _] = Egress.list_blocked_decisions(tenant_a.id)
      assert Egress.list_blocked_decisions(tenant_b.id) == []
    end

    test "tenant B's posture reports none of tenant A's destinations", %{
      tenant_b: tenant_b,
      webhook: webhook
    } do
      posture = Egress.posture(tenant_b.id, :agent)

      assert posture.webhook_destinations == []
      refute Enum.any?(posture.webhook_destinations, &(&1.webhook_id == webhook.id))
    end

    test "the blocked row carries tenant_id and both tables have an RLS policy", %{
      tenant: tenant_a,
      event: event
    } do
      assert AdminRepo.get!(WebhookEvent, event.id).tenant_id == tenant_a.id

      for table <- ["webhook_events", "egress_blocked_decisions"] do
        %{rows: rows} =
          AdminRepo.query!("SELECT policyname FROM pg_policies WHERE tablename = $1", [table])

        assert rows != [], "#{table} has no RLS policy (AC-41.5.7)"
      end
    end
  end

  # --- AC-41.5.5 -------------------------------------------------------------

  describe "AC-41.5.5 — posture reports webhook destinations" do
    test "every subscription is classified, with the allowlist disclosed as a BOOLEAN at :agent",
         %{tenant: tenant} do
      webhook = subscription(tenant.id, "https://hooks.example.com/inbound")
      :ok = mark_local_only(tenant.id)

      posture = Egress.posture(tenant.id, :agent)

      assert [destination] = posture.webhook_destinations
      assert destination.webhook_id == webhook.id
      assert destination.endpoint == "https://hooks.example.com/inbound"
      assert destination.host == "hooks.example.com"
      assert destination.verdict == "non-local"
      assert destination.verdict_from_deployment_allowlist == false
      assert destination.blocked_by_local_only
      assert destination.active
    end

    test "a tenant-declared destination is labelled as an UNVERIFIED ATTESTATION",
         %{tenant: tenant} do
      stub(Loopctl.MockDnsResolver, :resolve, fn
        "hooks.tenant-owned.example.com" -> {:ok, [{203, 0, 113, 10}]}
        _ -> {:ok, [{93, 184, 216, 34}]}
      end)

      _webhook = subscription(tenant.id, "https://hooks.tenant-owned.example.com/inbound")

      {:ok, _} =
        Egress.declare_trusted_endpoint(tenant.id, %{
          "host" => "hooks.tenant-owned.example.com",
          "purposes" => ["webhook"]
        })

      :ok = mark_local_only(tenant.id)

      assert [destination] = Egress.posture(tenant.id, :agent).webhook_destinations
      assert destination.verdict == Egress.tenant_declared_label()
      assert destination.verdict =~ "unverified attestation"
      refute destination.blocked_by_local_only
    end

    test "the guarantee wording no longer excludes webhook delivery", %{tenant: tenant} do
      guarantee = Egress.posture(tenant.id, :agent).guarantee_scope

      assert guarantee =~ "WEBHOOK DELIVERY"
      refute guarantee =~ "NOT yet covered"
      refute guarantee =~ "US-41.5"
    end
  end
end
