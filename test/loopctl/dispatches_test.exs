defmodule Loopctl.DispatchesTest do
  @moduledoc """
  Tests for US-26.2.1 — Dispatch lineage management.
  """

  use Loopctl.DataCase, async: true

  import Loopctl.Fixtures

  alias Loopctl.Dispatches

  setup :verify_on_exit!

  defp setup_dispatch_context do
    tenant = fixture(:tenant)
    agent = fixture(:agent, %{tenant_id: tenant.id})

    # Need a mock secrets adapter for audit chain key lookups
    Mox.stub(Loopctl.MockSecrets, :get, fn _name -> {:ok, :crypto.strong_rand_bytes(32)} end)
    Loopctl.TenantKeys.init_cache()

    %{tenant: tenant, agent: agent}
  end

  describe "create_dispatch/3" do
    test "creates a root dispatch with lineage_path = [self]" do
      %{tenant: tenant, agent: agent} = setup_dispatch_context()

      assert {:ok, %{dispatch: dispatch, raw_key: raw_key}} =
               Dispatches.create_dispatch(tenant.id, %{
                 role: :agent,
                 agent_id: agent.id,
                 expires_in_seconds: 3600
               })

      assert dispatch.parent_dispatch_id == nil
      assert dispatch.lineage_path == [dispatch.id]
      assert dispatch.role == :agent
      assert dispatch.agent_id == agent.id
      assert is_binary(raw_key)
      assert String.starts_with?(raw_key, "lc_")
    end

    test "child dispatch extends parent's lineage_path" do
      %{tenant: tenant, agent: agent} = setup_dispatch_context()

      {:ok, %{dispatch: parent}} =
        Dispatches.create_dispatch(tenant.id, %{role: :orchestrator, agent_id: agent.id})

      child_agent = fixture(:agent, %{tenant_id: tenant.id})

      {:ok, %{dispatch: child}} =
        Dispatches.create_dispatch(tenant.id, %{
          parent_dispatch_id: parent.id,
          role: :agent,
          agent_id: child_agent.id
        })

      assert child.lineage_path == parent.lineage_path ++ [child.id]
      assert child.parent_dispatch_id == parent.id
    end

    test "returns error for non-existent parent" do
      %{tenant: tenant, agent: agent} = setup_dispatch_context()

      assert {:error, :parent_not_found} =
               Dispatches.create_dispatch(tenant.id, %{
                 parent_dispatch_id: Ecto.UUID.generate(),
                 role: :agent,
                 agent_id: agent.id
               })
    end

    test "caps expires_in_seconds at max" do
      %{tenant: tenant, agent: agent} = setup_dispatch_context()

      {:ok, %{dispatch: dispatch}} =
        Dispatches.create_dispatch(tenant.id, %{
          role: :agent,
          agent_id: agent.id,
          expires_in_seconds: 999_999
        })

      diff = DateTime.diff(dispatch.expires_at, dispatch.created_at, :second)
      assert diff <= 14_400
    end
  end

  describe "revoke/2" do
    test "revokes a dispatch and its descendants" do
      %{tenant: tenant, agent: agent} = setup_dispatch_context()

      {:ok, %{dispatch: root}} =
        Dispatches.create_dispatch(tenant.id, %{role: :orchestrator, agent_id: agent.id})

      child_agent = fixture(:agent, %{tenant_id: tenant.id})

      {:ok, %{dispatch: _child}} =
        Dispatches.create_dispatch(tenant.id, %{
          parent_dispatch_id: root.id,
          role: :agent,
          agent_id: child_agent.id
        })

      assert {:ok, count} = Dispatches.revoke(tenant.id, root.id)
      assert count >= 1

      {:ok, revoked_root} = Dispatches.get_dispatch(tenant.id, root.id)
      assert revoked_root.revoked_at != nil
    end
  end

  describe "lineage_shares_prefix?/2" do
    test "detects shared prefix" do
      assert Dispatches.lineage_shares_prefix?(["a", "b", "c"], ["a", "b", "d"])
    end

    test "rejects disjoint lineages" do
      refute Dispatches.lineage_shares_prefix?(["a"], ["b"])
    end

    test "rejects empty lineages" do
      refute Dispatches.lineage_shares_prefix?([], ["a"])
      refute Dispatches.lineage_shares_prefix?(["a"], [])
    end
  end

  describe "list_dispatches/2" do
    test "returns dispatches for a tenant" do
      %{tenant: tenant, agent: agent} = setup_dispatch_context()

      Dispatches.create_dispatch(tenant.id, %{role: :agent, agent_id: agent.id})

      result = Dispatches.list_dispatches(tenant.id)
      assert result.meta.total_count >= 1
    end

    test "filters by active_only" do
      %{tenant: tenant, agent: agent} = setup_dispatch_context()

      {:ok, %{dispatch: dispatch}} =
        Dispatches.create_dispatch(tenant.id, %{
          role: :agent,
          agent_id: agent.id,
          expires_in_seconds: 60
        })

      # Active dispatches should include the one we just created
      result = Dispatches.list_dispatches(tenant.id, active_only: true)
      ids = Enum.map(result.data, & &1.id)
      assert dispatch.id in ids
    end
  end

  describe "tenant isolation" do
    test "cannot access another tenant's dispatches" do
      %{tenant: tenant_a, agent: agent_a} = setup_dispatch_context()
      %{tenant: tenant_b} = setup_dispatch_context()

      {:ok, %{dispatch: dispatch}} =
        Dispatches.create_dispatch(tenant_a.id, %{role: :agent, agent_id: agent_a.id})

      assert {:error, :not_found} = Dispatches.get_dispatch(tenant_b.id, dispatch.id)
    end
  end
end
