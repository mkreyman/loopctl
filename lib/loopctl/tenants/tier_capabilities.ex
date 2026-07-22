defmodule Loopctl.Tenants.TierCapabilities do
  @moduledoc """
  #505 — up-front discoverability for the `trust_tier` gate.

  `LoopctlWeb.Plugs.RequireHumanAnchor` (US-26.7.1) gates the work-breakdown /
  chain-of-custody surface on the TENANT's `trust_tier`. That gate is correct and
  deliberate — L0 (human + hardware anchor) is the root the whole custody chain
  hangs from, so an agent-rooted tenant must NOT be able to open a custody surface
  for itself. What was missing is a way to learn that BEFORE a write: an agent
  discovered the boundary only by taking a `403 custody_tier_required` on
  `POST /projects`, with no machine-readable pointer to the surface it CAN use.

  This module is the single source of truth for "which surfaces does this tier
  include", consumed by both:

  - `LoopctlWeb.TenantController.show/2` — so `GET /api/v1/tenants/me`
    (`mcp__loopctl__get_tenant`) advertises the tier's surfaces up front, and
  - `LoopctlWeb.Plugs.RequireHumanAnchor` — so the 403 carries the same map and
    the caller can immediately see what IS open to it.

  Keeping one derivation for both means the advertised capability set and the
  enforced gate cannot drift apart into a lie.

  ## Surfaces

  Surfaces are COARSE and named for the trust boundary, not for individual
  endpoints — an endpoint list would be stale by the next merge. Each entry maps
  a surface to the minimum `trust_tier` that unlocks it, with the controllers it
  covers named in the description so the mapping can be re-checked against the
  `RequireHumanAnchor` mounts.
  """

  alias Loopctl.Tenants.Tenant

  @type surface :: atom()
  @type tier :: :agent_rooted | :human_anchored

  # {surface, minimum trust_tier, human-readable description}
  #
  # `:agent_rooted` entries are the surfaces an agent-rooted (self-signup) tenant
  # can drive on its own. `:human_anchored` entries are the ones mounted behind
  # `LoopctlWeb.Plugs.RequireHumanAnchor`.
  @surfaces [
    {:knowledge_base, :agent_rooted,
     "Knowledge wiki: create/update/search/archive articles, conflicts, curation (#331)."},
    {:agent_memory, :agent_rooted, "Private per-agent memory (Epic 28): remember/recall/forget."},
    {:kb_project_scopes, :agent_rooted,
     "kind: kb project scopes — create/archive/restore, to partition knowledge by repo. " <>
       "This is the agent-native way to establish a project row for the repo you are on."},
    {:coordination_bus, :agent_rooted,
     "Repo coordination bus (Epic 39/40): channel posts, claims, handoffs."},
    {:context_retriever_queries, :agent_rooted,
     "Querying declared Context Retriever entities (Epic 30) via the cr_* tools."},
    {:tenant_profile, :agent_rooted,
     "Own tenant profile, LLM config, agent registration, audit key, authenticator enrollment."},
    {:work_breakdown, :human_anchored,
     "kind: work projects, epics, stories, dependencies, bulk import/export, orchestrator state."},
    {:chain_of_custody, :human_anchored,
     "Story lifecycle (claim/start/report/review-complete/verify), artifacts, skill results."},
    {:dispatch, :human_anchored, "Minting per-dispatch ephemeral keys and lineage paths (L4)."},
    {:token_budgets, :human_anchored, "Token budgets, usage corrections, cost-anomaly triage."},
    {:context_retriever_entities, :human_anchored,
     "Declaring/updating/deleting Context Retriever entity definitions (a security root)."}
  ]

  @learn_more "https://loopctl.com/wiki/chain-of-custody"
  @enrollment_upgrade "https://loopctl.com/wiki/tenant-signup"

  @doc """
  Capability map for a tenant. See `for_tier/1`.
  """
  @spec for_tenant(Tenant.t()) :: map()
  def for_tenant(%Tenant{trust_tier: tier}), do: for_tier(tier)
  def for_tenant(%{trust_tier: tier}), do: for_tier(tier)

  @doc """
  Capability map for a `trust_tier`.

  Shape:

      %{
        trust_tier: :agent_rooted,
        surfaces: %{knowledge_base: "allowed", work_breakdown: "requires_human_anchor", ...},
        allowed: [:agent_memory, :coordination_bus, ...],
        blocked: [:chain_of_custody, :dispatch, ...],
        descriptions: %{work_breakdown: "kind: work projects, epics, ...", ...},
        remediation: %{...}   # present only when `blocked` is non-empty
      }

  A `:human_anchored` tenant has an EMPTY `blocked` list and no `remediation` key
  — there is nothing left to remediate.
  """
  @spec for_tier(tier()) :: map()
  def for_tier(tier) when tier in [:agent_rooted, :human_anchored] do
    {allowed, blocked} =
      Enum.split_with(@surfaces, fn {_surface, min_tier, _desc} ->
        tier_at_least?(tier, min_tier)
      end)

    allowed_names = Enum.map(allowed, &elem(&1, 0))
    blocked_names = Enum.map(blocked, &elem(&1, 0))

    base = %{
      trust_tier: tier,
      surfaces:
        Map.new(@surfaces, fn {surface, min_tier, _desc} ->
          {surface,
           if(tier_at_least?(tier, min_tier), do: "allowed", else: "requires_human_anchor")}
        end),
      allowed: allowed_names,
      blocked: blocked_names,
      descriptions: Map.new(@surfaces, fn {surface, _min, desc} -> {surface, desc} end)
    }

    case blocked_names do
      [] -> base
      _ -> Map.put(base, :remediation, remediation())
    end
  end

  # An unknown or nil tier must not crash `GET /tenants/me`, and must not be
  # advertised optimistically: fall back to the MOST RESTRICTIVE map. If a third
  # tier is ever added, this under-advertises it (surfaces read as blocked that
  # the tier may actually allow) rather than promising a surface the gate denies
  # — the direction that fails safe. Add the tier to @surfaces to fix it properly.
  def for_tier(_unknown), do: for_tier(:agent_rooted)

  @doc """
  The remediation block shared by the capability map and the
  `custody_tier_required` 403 body, so both point at the same upgrade path.
  """
  @spec remediation() :: map()
  def remediation do
    %{
      learn_more: @learn_more,
      enrollment_upgrade: @enrollment_upgrade
    }
  end

  @doc """
  Every known surface name. Useful for tests asserting the map is exhaustive.
  """
  @spec surfaces() :: [surface()]
  def surfaces, do: Enum.map(@surfaces, &elem(&1, 0))

  # :agent_rooted < :human_anchored. Deliberately NOT reusing the ROLE hierarchy —
  # tier and role are orthogonal (see RequireHumanAnchor's moduledoc).
  defp tier_at_least?(_tier, :agent_rooted), do: true
  defp tier_at_least?(:human_anchored, :human_anchored), do: true
  defp tier_at_least?(_tier, :human_anchored), do: false
end
