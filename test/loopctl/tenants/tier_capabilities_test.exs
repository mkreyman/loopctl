defmodule Loopctl.Tenants.TierCapabilitiesTest do
  @moduledoc """
  #505 — the capability map is the contract a caller reads to discover which
  surfaces its `trust_tier` includes, so its SHAPE is load-bearing: an agent
  branches on it instead of probing for a 403.
  """

  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Tenants.TierCapabilities

  describe "for_tier/1 — agent_rooted" do
    test "marks the custody surfaces blocked and the KB surfaces allowed" do
      caps = TierCapabilities.for_tier(:agent_rooted)

      assert caps.trust_tier == :agent_rooted

      for surface <- [:work_breakdown, :chain_of_custody, :dispatch, :token_budgets] do
        assert surface in caps.blocked
        assert caps.surfaces[surface] == "requires_human_anchor"
      end

      for surface <- [:knowledge_base, :agent_memory, :kb_project_scopes, :coordination_bus] do
        assert surface in caps.allowed
        assert caps.surfaces[surface] == "allowed"
      end
    end

    test "kb_project_scopes is allowed — the agent-native answer to issue #505" do
      caps = TierCapabilities.for_tier(:agent_rooted)

      # The whole point: an agent-rooted tenant CAN establish a project row for
      # its own repo, just not one carrying a custody surface.
      assert :kb_project_scopes in caps.allowed
      assert :work_breakdown in caps.blocked
    end

    test "carries a remediation block with the enrollment-upgrade path" do
      caps = TierCapabilities.for_tier(:agent_rooted)

      assert caps.remediation.learn_more =~ "chain-of-custody"
      assert caps.remediation.enrollment_upgrade =~ "tenant-signup"
    end
  end

  describe "for_tier/1 — human_anchored" do
    test "blocks nothing and omits remediation" do
      caps = TierCapabilities.for_tier(:human_anchored)

      assert caps.trust_tier == :human_anchored
      assert caps.blocked == []
      assert Enum.sort(caps.allowed) == Enum.sort(TierCapabilities.surfaces())
      refute Map.has_key?(caps, :remediation)
      assert Enum.all?(Map.values(caps.surfaces), &(&1 == "allowed"))
    end
  end

  describe "for_tier/1 — shape invariants" do
    test "allowed and blocked partition the full surface list exactly, for both tiers" do
      for tier <- [:agent_rooted, :human_anchored] do
        caps = TierCapabilities.for_tier(tier)

        assert Enum.sort(caps.allowed ++ caps.blocked) == Enum.sort(TierCapabilities.surfaces()),
               "allowed ++ blocked must be a partition of surfaces/0 for #{tier}"

        assert [] == caps.allowed -- (caps.allowed -- caps.blocked),
               "a surface must not be both allowed and blocked for #{tier}"

        assert Map.keys(caps.surfaces) |> Enum.sort() == Enum.sort(TierCapabilities.surfaces())

        assert Map.keys(caps.descriptions) |> Enum.sort() ==
                 Enum.sort(TierCapabilities.surfaces())
      end
    end

    test "every surface carries a non-empty description" do
      caps = TierCapabilities.for_tier(:agent_rooted)

      for {surface, desc} <- caps.descriptions do
        assert is_binary(desc) and desc != "", "surface #{surface} has no description"
      end
    end

    test "the surfaces map only ever uses the two documented status strings" do
      for tier <- [:agent_rooted, :human_anchored] do
        statuses = TierCapabilities.for_tier(tier).surfaces |> Map.values() |> Enum.uniq()
        assert statuses -- ["allowed", "requires_human_anchor"] == []
      end
    end
  end

  describe "for_tier/1 — unknown tier" do
    test "falls back to the most restrictive map instead of raising or over-promising" do
      for unknown <- [nil, :some_future_tier, "human_anchored"] do
        assert TierCapabilities.for_tier(unknown) == TierCapabilities.for_tier(:agent_rooted)
      end
    end
  end

  describe "for_tenant/1" do
    test "derives from the tenant's trust_tier" do
      agent_rooted = fixture(:tenant, %{trust_tier: :agent_rooted})
      human_anchored = fixture(:tenant, %{trust_tier: :human_anchored})

      assert TierCapabilities.for_tenant(agent_rooted) == TierCapabilities.for_tier(:agent_rooted)

      assert TierCapabilities.for_tenant(human_anchored) ==
               TierCapabilities.for_tier(:human_anchored)
    end
  end
end
