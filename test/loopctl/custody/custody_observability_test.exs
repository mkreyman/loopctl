defmodule Loopctl.Custody.CustodyObservabilityTest do
  @moduledoc """
  Three places where a custody control was in force but invisible:

  * a post-commit audit-chain append whose failure was discarded, leaving the
    hash-chained log quietly incomplete;
  * the signed-profile resolution, which announced a misconfigured value but said
    nothing at all when the config was simply absent — the likeliest way a
    deployment meant to run `signed` ends up serving `bearer`;
  * the bulk custody gate, which recognised fewer "enrolled" callers than the
    single-story gate it mirrors.
  """
  use Loopctl.DataCase, async: true

  import ExUnit.CaptureLog

  alias Loopctl.AuditChain
  alias Loopctl.Custody.SignedProfilePolicy
  alias Loopctl.Test.CustodyEnrollment
  alias Loopctl.Test.CustodyProfileStub

  setup :verify_on_exit!

  describe "AuditChain.log_append_failure/4" do
    test "a failed post-commit append is logged loudly and passed through" do
      log =
        capture_log(fn ->
          assert {:error, :boom} =
                   AuditChain.log_append_failure(
                     {:error, :boom},
                     "verifier_selected",
                     Ecto.UUID.generate(),
                     Ecto.UUID.generate()
                   )
        end)

      assert log =~ "audit_chain_append_failed"
      assert log =~ "verifier_selected"
    end

    test "a successful append logs nothing and is passed through unchanged" do
      log =
        capture_log(fn ->
          assert {:ok, :entry} =
                   AuditChain.log_append_failure(
                     {:ok, :entry},
                     "verifier_selected",
                     Ecto.UUID.generate(),
                     nil
                   )
        end)

      refute log =~ "audit_chain_append_failed"
    end
  end

  describe "both post-commit appends in Progress route through the guard" do
    # These two appends run AFTER their state change has committed, so nothing can
    # roll them back — the only available response to a failure is to say so. A
    # source scan keeps a future edit from quietly reverting to a discarded result.
    test "verifier_selected and verifier_not_assigned pipe into log_append_failure" do
      source = File.read!("lib/loopctl/progress.ex")

      for action <- ["verifier_selected", "verifier_not_assigned"] do
        assert source =~ ~s|log_append_failure("#{action}"|,
               "#{action}'s audit-chain append must pipe into AuditChain.log_append_failure/4"
      end
    end
  end

  describe "signed profile resolution telemetry" do
    setup do
      handler = "custody-profile-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:loopctl, :custody, :profile_resolved],
        fn _event, measurements, metadata, _cfg ->
          send(test_pid, {:profile_resolved, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "an UNSET config emits telemetry naming the source, not just a silent bearer" do
      assert SignedProfilePolicy.profile() == :bearer

      assert_received {:profile_resolved, %{count: 1}, %{profile: :bearer, source: :unset}}
    end

    test "an explicitly configured signed profile is distinguishable from a default" do
      CustodyProfileStub.set_profile(:signed)
      on_exit(fn -> CustodyProfileStub.set_profile(:bearer) end)

      assert SignedProfilePolicy.profile() == :signed

      assert_received {:profile_resolved, %{count: 1}, %{profile: :signed, source: :configured}}
    end
  end

  describe "verify_bulk_request/3 enrolled-caller parity" do
    setup do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      %{tenant: tenant, agent: agent}
    end

    test "an enrolled dispatch is refused", %{tenant: tenant, agent: agent} do
      %{dispatch: dispatch} = CustodyEnrollment.enroll_root(tenant.id, %{agent_id: agent.id})

      assert {:error, :bulk_signature_unsupported} =
               SignedProfilePolicy.verify_bulk_request(:signed, tenant.id, dispatch.api_key_id)
    end

    test "a BEARER dispatch of an agent that has enrolled elsewhere is refused too",
         %{tenant: tenant, agent: agent} do
      # Same agent_id, two dispatches: one enrolled (signs), one bearer. The single-story
      # gate already refuses the bearer one; the bulk gate must not be the softer door.
      CustodyEnrollment.enroll_root(tenant.id, %{agent_id: agent.id, role: :orchestrator})
      bearer = bearer_dispatch(tenant.id, agent.id)

      assert {:error, :bulk_signature_unsupported} =
               SignedProfilePolicy.verify_bulk_request(:signed, tenant.id, bearer.api_key_id)
    end

    test "a bearer dispatch of an agent with no enrolled key is still waived",
         %{tenant: tenant, agent: agent} do
      bearer = bearer_dispatch(tenant.id, agent.id)

      assert :ok = SignedProfilePolicy.verify_bulk_request(:signed, tenant.id, bearer.api_key_id)
    end

    test "the bearer profile waives everything", %{tenant: tenant, agent: agent} do
      %{dispatch: dispatch} = CustodyEnrollment.enroll_root(tenant.id, %{agent_id: agent.id})

      assert :ok =
               SignedProfilePolicy.verify_bulk_request(:bearer, tenant.id, dispatch.api_key_id)
    end
  end

  defp bearer_dispatch(tenant_id, agent_id) do
    {:ok, %{dispatch: dispatch}} =
      Loopctl.Dispatches.create_dispatch(tenant_id, %{role: :agent, agent_id: agent_id})

    dispatch
  end
end
