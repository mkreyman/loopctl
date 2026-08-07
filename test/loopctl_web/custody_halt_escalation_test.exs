defmodule LoopctlWeb.CustodyHaltEscalationTest do
  @moduledoc """
  What may — and may not — arm a tenant-wide custody halt.

  A halt freezes the tenant's custody surface until a human WebAuthn break-glass
  ceremony clears it. Two invariants hold it in proportion:

    1. An ordinary PROTOCOL error never arms it. A capability token is
       single-use with a bounded TTL, so a plain client retry presents a
       consumed token and a resumed agent presents an expired one. Escalating
       that to a tenant-wide freeze would let routine retry behaviour take a
       tenant down; the 403 refusal is the enforcement, and it still happens.
    2. A REPEATED self-report / self-verify pattern still arms it. That is L6
       byzantine detection and it stays load-bearing — the threshold changed
       WHEN it fires, not WHETHER.

  Async: every path runs on `Loopctl.AdminRepo`, sharing the sandbox connection
  the fixtures insert through.
  """
  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query, only: [where: 3]

  alias Loopctl.AdminRepo
  alias Loopctl.Capabilities
  alias Loopctl.Custody.Violation
  alias Loopctl.Custody.ViolationMonitor
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Progress
  alias Loopctl.Tenants
  alias LoopctlWeb.FallbackController

  setup :verify_on_exit!

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp base_conn,
    do: put_req_header(build_conn(), "x-loopctl-last-known-sth", "0:AAAAAAAAAAAAAAAAAAAAAA")

  defp halted?(tenant_id) do
    {:ok, tenant} = Tenants.get_tenant(tenant_id)
    Tenants.custody_halted?(tenant)
  end

  # A tenant whose audit signing key is available, so capability tokens can be
  # minted and their signatures verified.
  defp tenant_with_audit_key do
    tenant = fixture(:tenant)
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    tenant =
      tenant
      |> Ecto.Changeset.change(audit_signing_public_key: pub)
      |> AdminRepo.update!()

    Mox.stub(Loopctl.MockSecrets, :get, fn _name -> {:ok, priv} end)
    Loopctl.TenantKeys.init_cache()

    tenant
  end

  defp story_ready_for_verify(tenant) do
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    implementer = fixture(:agent, %{tenant_id: tenant.id})
    lineage = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    dispatch =
      %Dispatch{tenant_id: tenant.id}
      |> Dispatch.changeset(%{
        role: :agent,
        agent_id: implementer.id,
        lineage_path: lineage,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })
      |> AdminRepo.insert!()

    story =
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
      |> Ecto.Changeset.change(
        agent_status: :reported_done,
        assigned_agent_id: implementer.id,
        implementer_dispatch_id: dispatch.id,
        reported_done_at: DateTime.utc_now()
      )
      |> AdminRepo.update!()

    %{story: story, implementer: implementer, lineage: lineage}
  end

  describe "a retried capability must not halt the tenant (the retry case)" do
    test "a REPLAYED start_cap is refused without halting the tenant" do
      tenant = tenant_with_audit_key()
      %{story: story, lineage: lineage, implementer: implementer} = story_ready_for_verify(tenant)

      # #621 retired verify_cap, so `start` is now the only transition that consumes
      # a capability — this test moved here with it. The scenario is unchanged and is
      # the one that matters: a client retry, timeout-and-resend, or crash-and-resume
      # presents a token the first attempt already spent.
      {:ok, cap} = Capabilities.mint(tenant.id, "start_cap", story.id, lineage)
      {:ok, _} = Capabilities.consume(cap)

      # Driven at the context layer so the replay reaches the capability check; over
      # HTTP the state machine refuses a second start with a 409 first, which is its
      # own (desirable) protection and would not exercise this path.
      result =
        Progress.start_story(tenant.id, story.id,
          agent_id: implementer.id,
          cap_id: cap.id,
          lineage: lineage
        )

      assert match?({:error, _}, result), "a replayed capability must be refused"

      # THE POINT: the retry was refused, and the tenant is still up. A single
      # capability refusal must never cost the operator a WebAuthn ceremony.
      refute halted?(tenant.id)
      assert ViolationMonitor.count_in_window(tenant.id) == 0
    end

    test "rendering cap_rejected returns 403 and halts nothing, however many times it happens" do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id})

      {_raw, api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      for reason <- [:replay, :expired, :invalid_signature, :wrong_lineage, :replay, :replay] do
        result =
          base_conn()
          |> assign(:current_api_key, api_key)
          |> FallbackController.call({:error, {:cap_rejected, reason}})

        assert result.status == 403
        body = Jason.decode!(result.resp_body)
        assert body["error"]["code"] == "cap_rejected"
        # The old copy claimed "Custody operations halted", which was both the
        # behaviour and the message this change removes.
        refute body["error"]["message"] =~ "halted"
      end

      refute halted?(tenant.id)
      assert ViolationMonitor.count_in_window(tenant.id) == 0
    end

    test "a cap rejection is still OBSERVABLE — it emits telemetry for an operator to alert on" do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id})

      {_raw, api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      test_pid = self()
      ref = make_ref()
      handler_id = "cap-rejected-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:loopctl, :custody, :cap_rejected],
        fn _event, _measurements, metadata, _config ->
          if metadata[:tenant_id] == tenant.id, do: send(test_pid, {ref, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      base_conn()
      |> assign(:current_api_key, api_key)
      |> FallbackController.call({:error, {:cap_rejected, :replay}})

      assert_receive {^ref, metadata}
      assert metadata.reason == :replay
    end
  end

  describe "a repeated self-report pattern still halts (L6 stays load-bearing)" do
    setup do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      agent = fixture(:agent, %{tenant_id: tenant.id})

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      %{tenant: tenant, epic: epic, agent: agent, raw_key: raw_key}
    end

    defp assigned_story(%{tenant: tenant, epic: epic, agent: agent}) do
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
      |> Ecto.Changeset.change(
        agent_status: :implementing,
        assigned_agent_id: agent.id,
        assigned_at: DateTime.utc_now()
      )
      |> AdminRepo.update!()
    end

    test "ONE self-report is refused with 409 and leaves the tenant up", ctx do
      story = assigned_story(ctx)

      body =
        base_conn()
        |> auth(ctx.raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/report", %{})
        |> json_response(409)

      assert body["error"]["code"] == "self_report_blocked"
      refute halted?(ctx.tenant.id)
      assert ViolationMonitor.count_in_window(ctx.tenant.id) == 1
    end

    test "the tenant is halted once the pattern repeats to the threshold", ctx do
      threshold = ViolationMonitor.threshold()

      for _ <- 1..threshold do
        story = assigned_story(ctx)

        base_conn()
        |> auth(ctx.raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/report", %{})
        |> json_response(409)
      end

      assert halted?(ctx.tenant.id)

      # The counter is back to zero because the halt CLAIMED its evidence — the
      # rows survive as the forensic record, but they cannot arm a second halt,
      # which is what lets the break-glass ceremony recover the tenant.
      assert ViolationMonitor.count_in_window(ctx.tenant.id) == 0

      tenant_id = ctx.tenant.id

      assert Violation
             |> where([v], v.tenant_id == ^tenant_id)
             |> AdminRepo.aggregate(:count) == threshold
    end

    # The self_review_blocked gate is the one that recorded NOTHING until #624, and
    # it was invisible because every test drove ViolationMonitor.record/3 directly.
    # This one drives the HTTP path, so the FallbackController wiring is bound:
    # delete the record_custody_violation call and it fails.
    test "a self-review 409 is recorded through the FallbackController too", ctx do
      story =
        ctx
        |> assigned_story()
        |> Ecto.Changeset.change(
          agent_status: :reported_done,
          reported_done_at: DateTime.utc_now()
        )
        |> AdminRepo.update!()

      # An ORCHESTRATOR key (review-complete is exact_role [:orchestrator, :user])
      # carrying the implementing agent's own id — the reviewer is the implementer.
      {orch_key, _api_key} =
        fixture(:api_key, %{
          tenant_id: ctx.tenant.id,
          role: :orchestrator,
          agent_id: ctx.agent.id
        })

      body =
        base_conn()
        |> auth(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/review-complete", %{
          "review_type" => "enhanced",
          "summary" => "reviewed"
        })
        |> json_response(409)

      assert body["error"]["code"] == "self_review_blocked"
      assert body["error"]["remediation"]["learn_more"] =~ "self-review-blocked"
      assert ViolationMonitor.count_in_window(ctx.tenant.id) == 1
      refute halted?(ctx.tenant.id)
    end

    test "one tenant's self-report pattern never halts another tenant", ctx do
      other = fixture(:tenant)

      for _ <- 1..ViolationMonitor.threshold() do
        story = assigned_story(ctx)

        base_conn()
        |> auth(ctx.raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/report", %{})
        |> json_response(409)
      end

      assert halted?(ctx.tenant.id)
      refute halted?(other.id)
      assert ViolationMonitor.count_in_window(other.id) == 0
    end
  end
end
