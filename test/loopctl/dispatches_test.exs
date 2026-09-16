defmodule Loopctl.DispatchesTest do
  @moduledoc """
  Tests for US-26.2.1 — Dispatch lineage management.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query
  import Loopctl.Fixtures

  alias Loopctl.AdminRepo
  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch

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

    test "a REVOKED parent cannot authorize a new child enrollment (fails closed)" do
      %{tenant: tenant, agent: agent} = setup_dispatch_context()

      {:ok, %{dispatch: parent}} =
        Dispatches.create_dispatch(tenant.id, %{role: :orchestrator, agent_id: agent.id})

      {:ok, _} = Dispatches.revoke(tenant.id, parent.id)

      child_agent = fixture(:agent, %{tenant_id: tenant.id})

      # create_dispatch is the security boundary — it must reject a revoked delegator
      # itself, not lean on the controller's direct-parent pre-check.
      assert {:error, :parent_not_found} =
               Dispatches.create_dispatch(tenant.id, %{
                 parent_dispatch_id: parent.id,
                 role: :agent,
                 agent_id: child_agent.id
               })
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

  describe "revoke_dispatch_rows/2 — the advisory read's re-assertion" do
    # #862 review round 2, finding 2. `revoke/3`'s candidate read (`dispatches_query`) runs
    # OUTSIDE the transaction and already carries `is_nil(d.revoked_at)`, so through `revoke/3`
    # the two guards are REDUNDANT: a sequential re-revoke hands the write an EMPTY id list and
    # the write's own predicate can be deleted with every assertion still green. Under READ
    # COMMITTED that predicate is the ONLY thing that stops a second concurrent writer, whose
    # candidate read also saw the row un-revoked and which re-evaluates just its own `where`
    # after the row lock clears.
    #
    # THAT CONCURRENCY IS NOT REPRODUCIBLE HERE — the Ecto SQL sandbox runs the whole test on
    # one checked-out connection, so two "concurrent" transactions serialise instead of
    # contending — so these reach the write DIRECTLY with ids the candidate read would never
    # have produced. Both consequences of the missing predicate are asserted separately: the
    # timestamp rewrite, and the COUNT, which is what `revoke/3` audits on.
    defp revoked_dispatch(tenant, agent, at) do
      {:ok, %{dispatch: dispatch}} =
        Dispatches.create_dispatch(tenant.id, %{role: :agent, agent_id: agent.id})

      {1, _} =
        AdminRepo.update_all(
          from(d in Dispatch, where: d.id == ^dispatch.id),
          set: [revoked_at: at]
        )

      dispatch
    end

    defp reload_dispatch(id), do: AdminRepo.get!(Dispatch, id)

    test "an id that is already revoked is skipped, keeping its ORIGINAL revoked_at" do
      %{tenant: tenant, agent: agent} = setup_dispatch_context()

      original =
        DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:microsecond)

      dispatch = revoked_dispatch(tenant, agent, original)

      assert Dispatches.revoke_dispatch_rows([dispatch.id], DateTime.utc_now()) == 0

      assert DateTime.compare(reload_dispatch(dispatch.id).revoked_at, original) == :eq,
             "a second revoker must not rewrite a revocation timestamp the chain already names"
    end

    test "an un-revoked id IS revoked and counted" do
      # The positive control: without it, "skip the revoked one" is satisfied by a function
      # that writes nothing at all.
      %{tenant: tenant, agent: agent} = setup_dispatch_context()

      {:ok, %{dispatch: dispatch}} =
        Dispatches.create_dispatch(tenant.id, %{role: :agent, agent_id: agent.id})

      now = DateTime.utc_now()

      assert Dispatches.revoke_dispatch_rows([dispatch.id], now) == 1
      assert reload_dispatch(dispatch.id).revoked_at
    end

    test "the COUNT is what the statement CHANGED, not how many ids it was handed" do
      # This is the half that reaches the hash chain. `revoke/3` audits on `count > 0` and
      # writes `revoked_count` into an IMMUTABLE, STH-covered entry, so a count taken from the
      # id list rather than from the UPDATE inflates a number nobody can correct afterwards.
      %{tenant: tenant, agent: agent} = setup_dispatch_context()
      already = revoked_dispatch(tenant, agent, DateTime.utc_now())
      other_agent = fixture(:agent, %{tenant_id: tenant.id})

      {:ok, %{dispatch: live}} =
        Dispatches.create_dispatch(tenant.id, %{role: :agent, agent_id: other_agent.id})

      assert Dispatches.revoke_dispatch_rows([already.id, live.id], DateTime.utc_now()) == 1
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
