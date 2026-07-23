defmodule Loopctl.Tenants.TierCapabilitiesTest do
  @moduledoc """
  #505 — the capability map is the contract a caller reads to discover which
  surfaces its `trust_tier` includes, so its SHAPE is load-bearing: an agent
  branches on it instead of probing for a 403.

  ## What the drift guard here does and does NOT catch

  It scans SOURCE TEXT under `lib/loopctl_web/**` for `plug ... RequireHumanAnchor`
  mounts (parenthesized or not, aliased or not) and binds them to
  `TierCapabilities.gated_controllers/0` in both directions. It is
  CONTROLLER-granular except for the one per-ACTION assertion covering the
  kb-scope actions; a mount injected through a shared `use`/macro is invisible to
  it, and it never checks the prose descriptions against the real mounts. Read
  "do NOT relax this test" as "this floor is lower than it looks — raise it, never
  lower it".
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
      assert caps.remediation.enrollment_upgrade.docs =~ "tenant-signup"
    end

    test "the enrollment upgrade is machine-actionable and names the IN-PLACE path" do
      # A bare link to the signup ceremony sent a caller to create a SECOND
      # tenant and strand the knowledge this one owns. The upgrade is enrolling
      # an authenticator against the EXISTING tenant.
      upgrade = TierCapabilities.for_tier(:agent_rooted).remediation.enrollment_upgrade

      assert "enroll_authenticator" in upgrade.tools
      assert "request_authenticator_challenge" in upgrade.tools
      assert Enum.any?(upgrade.endpoints, &(&1 =~ "/authenticators"))
      assert upgrade.requires_human == true
      refute upgrade.summary =~ "signup"
    end

    test "states that the map is tier-scoped and covers mutating actions only" do
      # The map derives from trust_tier ALONE and every RequireHumanAnchor mount
      # is per-action. Advertising a bare "allowed" would relocate the
      # confident-then-403 failure onto the role axis, and a caller branching on
      # `blocked` would skip reads it is entitled to.
      caps = TierCapabilities.for_tier(:agent_rooted)

      assert caps.scope == "trust_tier_only"
      assert caps.applies_to == "mutating_actions"
      assert caps.note =~ "role"
      assert caps.note =~ "Reads stay open"
    end

    test "every blocked surface's description says reads stay open" do
      caps = TierCapabilities.for_tier(:agent_rooted)

      for surface <- caps.blocked do
        assert caps.descriptions[surface] =~ "stays open",
               "blocked surface #{inspect(surface)} does not say which reads remain open, " <>
                 "so a caller branching on `blocked` will skip reads it is entitled to"
      end
    end

    test "token_budgets names usage RECORDING, which is gated too" do
      # POST /api/v1/token-usage is the routine per-dispatch report every agent
      # emits at end of work, and TokenUsageController gates :create.
      desc = TierCapabilities.for_tier(:agent_rooted).descriptions[:token_budgets]

      assert desc =~ "token-usage"
      assert desc =~ "RECORDING"
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
    test "falls back to the most restrictive surface set instead of raising or over-promising" do
      restrictive = TierCapabilities.for_tier(:agent_rooted)

      for unknown <- [nil, :some_future_tier, "human_anchored"] do
        caps = TierCapabilities.for_tier(unknown)

        assert Map.drop(caps, [:trust_tier, :unknown_tier]) ==
                 Map.drop(restrictive, [:trust_tier, :unknown_tier])
      end
    end

    test "echoes the tier it was actually asked about and flags it, never a tier it is not" do
      caps = TierCapabilities.for_tier(:some_future_tier)

      # Stamping `trust_tier: :agent_rooted` here would make the body contradict
      # the payload's own `trust_tier` and silently mask the misconfiguration.
      assert caps.trust_tier == :some_future_tier
      assert caps.unknown_tier == true
    end

    test "a known tier is never flagged unknown" do
      for tier <- [:agent_rooted, :human_anchored] do
        refute Map.has_key?(TierCapabilities.for_tier(tier), :unknown_tier)
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

    test "a nil/unshaped tenant falls back to the most restrictive map, never crashes" do
      restrictive = TierCapabilities.for_tier(:agent_rooted)

      for input <- [nil, %{}, :not_a_tenant] do
        caps = TierCapabilities.for_tenant(input)

        assert Map.drop(caps, [:trust_tier, :unknown_tier]) ==
                 Map.drop(restrictive, [:trust_tier, :unknown_tier])
      end
    end

    test "an unshaped tenant is FLAGGED, never silently self-reported as agent_rooted" do
      # This clause fires on the genuine misconfiguration (the plug's defensive
      # path with no current_tenant assign). Returning a clean agent_rooted map
      # would assert a tier as fact about a tenant that could not be resolved,
      # and a client branching on `unknown_tier` would get a false negative.
      for input <- [nil, %{}, :not_a_tenant] do
        caps = TierCapabilities.for_tenant(input)

        assert caps.unknown_tier == true
        refute caps.trust_tier == :agent_rooted
      end
    end

    test "a well-shaped tenant is never flagged" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      refute Map.has_key?(TierCapabilities.for_tenant(tenant), :unknown_tier)
    end
  end

  describe "compact/1 — the error-path shape" do
    test "drops the static descriptions and keeps everything a caller branches on" do
      full = TierCapabilities.for_tier(:agent_rooted)
      compact = TierCapabilities.compact(full)

      refute Map.has_key?(compact, :descriptions)

      for key <- [:trust_tier, :scope, :applies_to, :note, :surfaces, :allowed, :blocked] do
        assert compact[key] == full[key]
      end

      assert compact.remediation == full.remediation
    end

    test "compact_for_tenant/1 is for_tenant/1 compacted" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})

      assert TierCapabilities.compact_for_tenant(tenant) ==
               tenant |> TierCapabilities.for_tenant() |> TierCapabilities.compact()
    end
  end

  describe "for_tier/1 — JSON safety of the fallback" do
    test "a non-encodable unknown tier is stringified instead of crashing the error path" do
      # The map is JSON-encoded inside a 403. Echoing a tuple/pid verbatim would
      # raise from inside the error handler and turn a fail-safe 403 into a 500.
      for unknown <- [{:weird, :tuple}, self(), %{not: "a tier"}] do
        caps = TierCapabilities.for_tier(unknown)

        assert is_binary(caps.trust_tier)
        assert caps.unknown_tier == true
        assert {:ok, _json} = Jason.encode(caps)
      end
    end
  end

  describe "drift guard — @surfaces vs the real RequireHumanAnchor mounts" do
    # The advertised map is only trustworthy if it is bound to the ENFORCED gate.
    # The real boundary is the set of `plug LoopctlWeb.Plugs.RequireHumanAnchor`
    # mounts across the controllers; without this scan, a surface advertised
    # "allowed" whose endpoints are gated hands the caller the exact
    # confident-then-403 failure #505 exists to remove.
    test "every gated controller is claimed by exactly one human_anchored surface" do
      claimed = TierCapabilities.gated_controllers() |> Map.values() |> List.flatten()

      assert claimed == Enum.uniq(claimed),
             "a controller is claimed by more than one surface: " <>
               inspect(claimed -- Enum.uniq(claimed))

      assert Enum.sort(claimed) == Enum.sort(mounted_controllers()),
             """
             TierCapabilities.gated_controllers/0 has drifted from the actual
             RequireHumanAnchor mounts.

             Gated but unclaimed by any surface: #{inspect(mounted_controllers() -- claimed)}
             Claimed but not actually gated:     #{inspect(claimed -- mounted_controllers())}

             Fix lib/loopctl/tenants/tier_capabilities.ex — do NOT relax this test.
             """
    end

    test "every surface naming gated controllers is itself human_anchored" do
      blocked = TierCapabilities.for_tier(:agent_rooted).blocked

      for surface <- Map.keys(TierCapabilities.gated_controllers()) do
        assert surface in blocked,
               "surface #{inspect(surface)} covers RequireHumanAnchor-gated controllers " <>
                 "but is advertised as allowed to an agent_rooted tenant"
      end
    end

    test "every human_anchored surface names at least one gated controller" do
      gated = TierCapabilities.gated_controllers()

      for surface <- TierCapabilities.for_tier(:agent_rooted).blocked do
        assert match?([_ | _], Map.get(gated, surface)),
               "surface #{inspect(surface)} is advertised as human-anchored but names no " <>
                 "controller — either it is fictional or gated_controllers/0 is incomplete"
      end
    end

    test "the advertised-allowed kb-scope actions are NOT inside a RequireHumanAnchor mount" do
      # The controller-level guard above is controller-granular while the gate is
      # ACTION-granular: ProjectController hosts a blocked surface
      # (:work_breakdown) AND an advertised-allowed one (:kb_project_scopes).
      # Adding :create_kb_scope to an anchor's `when action in [...]` list keeps
      # the controller-level assertion green while kb_project_scopes silently
      # becomes a lie — so assert the actions directly.
      gated_actions =
        "lib/loopctl_web/controllers/project_controller.ex"
        |> File.read!()
        |> human_anchor_gated_actions()

      assert :create in gated_actions, "the work-breakdown gate on :create disappeared"

      for action <- [:create_kb_scope, :archive_kb_scope, :restore_kb_scope] do
        refute action in gated_actions,
               "#{action} is behind RequireHumanAnchor, but :kb_project_scopes is " <>
                 "advertised as allowed to an agent_rooted tenant. Either the mount is " <>
                 "wrong or tier_capabilities.ex is over-promising."
      end
    end
  end

  # SCOPE LIMITS of this guard, stated so it is not over-trusted: it scans SOURCE
  # TEXT under lib/loopctl_web (controllers, plugs, router — anywhere the plug can
  # be mounted), matching `plug RequireHumanAnchor` with or without parentheses
  # and with or without the full alias. A mount injected by a shared `use`/macro
  # is still invisible to it, and only the kb-scope test above compares per-ACTION
  # guards. It does not check the prose descriptions against reality at all.
  @scan_glob "lib/loopctl_web/**/*.ex"
  @plug_source "lib/loopctl_web/plugs/require_human_anchor.ex"

  defp mounted_controllers do
    @scan_glob
    |> Path.wildcard()
    |> Enum.reject(&(&1 == @plug_source))
    |> Enum.filter(&(&1 |> File.read!() |> mounts_human_anchor?()))
    |> Enum.map(&defmodule_name/1)
  end

  defp mounts_human_anchor?(source) do
    String.match?(source, ~r/^\s*plug[\s(]+(LoopctlWeb\.Plugs\.)?RequireHumanAnchor\b/m)
  end

  # The actions a `plug ... RequireHumanAnchor ... when action in [...]` mount
  # covers. A mount with no `when` clause covers every action in the controller,
  # which we surface as `:__all__` so it can never be mistaken for "none".
  defp human_anchor_gated_actions(source) do
    ~r/^\s*plug[\s(]+(?:LoopctlWeb\.Plugs\.)?RequireHumanAnchor\b(?<rest>.*?)(?=\n\s*(?:plug|def|@|tags)\b|\z)/ms
    |> Regex.scan(source, capture: ["rest"])
    |> Enum.flat_map(fn [rest] ->
      case Regex.run(~r/when\s+action\s+in\s+\[(?<actions>[^\]]*)\]/, rest, capture: ["actions"]) do
        [actions] ->
          actions
          |> String.split(",")
          |> Enum.map(&(&1 |> String.trim() |> String.trim_leading(":")))
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&String.to_atom/1)

        nil ->
          [:__all__]
      end
    end)
  end

  defp defmodule_name(path) do
    case Regex.run(~r/^defmodule\s+([\w.]+)\s+do/m, File.read!(path)) do
      [_, module] ->
        module

      nil ->
        flunk("could not read a defmodule name out of #{path} — widen defmodule_name/1")
    end
  end
end
