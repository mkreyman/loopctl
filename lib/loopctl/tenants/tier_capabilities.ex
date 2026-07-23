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
  include", consumed by:

  - `LoopctlWeb.TenantController.show/2` — so `GET /api/v1/tenants/me`
    (`mcp__loopctl__get_tenant`) advertises the tier's surfaces up front,
  - `LoopctlWeb.SignupController` and `LoopctlWeb.TenantAuthenticatorController` —
    so the map ships with the one-time root key and with the enrollment upgrade,
    the two moments the tier changes or is first learned, and
  - `LoopctlWeb.Plugs.RequireHumanAnchor` — so the 403 carries the same map and
    the caller can immediately see what IS open to it.

  ## Scope of the map: the TIER gate, on MUTATING actions

  Two things this map deliberately does NOT cover, both stated in the payload
  itself (`scope`, `applies_to`, `note`) so a caller reading it machine-side sees
  them too:

  - **Role gates are orthogonal.** `RequireRole` is a separate gate on the same
    endpoints. `allowed` means "your TIER permits this surface" — a key whose
    role is too low still takes a `403 insufficient_role`. Upgrading the tier is
    necessary, not always sufficient.
  - **Statuses describe MUTATING actions.** Every `RequireHumanAnchor` mount is
    per-action (`when action in [:create, :update, :delete]`); READS stay open on
    every surface, including the blocked ones. A caller branching on `blocked`
    without that qualifier would skip reads it is entitled to — an
    under-advertising failure in the map meant to remove guesswork.

  ## Surfaces, and what stops them lying

  Surfaces are COARSE and named for the trust boundary, not for individual
  endpoints — an endpoint list would be stale by the next merge. Each entry maps
  a surface to the minimum `trust_tier` that unlocks it.

  One derivation for every consumer is not, on its own, enough: the REAL boundary
  is the set of `plug LoopctlWeb.Plugs.RequireHumanAnchor` mounts spread across
  the controllers, and a hand-maintained parallel list drifts from it silently.
  `gated_controllers/0` is the mechanical binding — it names, per
  `:human_anchored` surface, the controllers that mount the plug, and
  `test/loopctl/tenants/tier_capabilities_test.exs` scans the controller sources
  and fails when a mount is added, dropped, or moved without updating this module.
  Without that scan, an over-promising entry (a surface advertised `allowed`
  whose endpoints are actually gated) hands a caller the confident-then-403
  failure this feature exists to remove.

  Controllers are named as STRINGS deliberately: `Loopctl.*` must not take a
  compile-time dependency on `LoopctlWeb.*`.
  """

  alias Loopctl.Tenants.Tenant

  @type surface :: atom()
  @type tier :: :agent_rooted | :human_anchored

  # {surface, minimum trust_tier, human-readable description}
  #
  # `:agent_rooted` entries are the surfaces an agent-rooted (self-signup) tenant
  # can drive on its own. `:human_anchored` entries are the ones mounted behind
  # `LoopctlWeb.Plugs.RequireHumanAnchor` (see `@gated_controllers`).
  #
  # Every `:human_anchored` description ends by naming the WRITES the tier gate
  # blocks and stating that reads stay open — the mounts are per-action, so a
  # surface-level "requires_human_anchor" would otherwise read as "you may not
  # touch this at all" and cost the caller reads it is entitled to.
  @surfaces [
    {:knowledge_base, :agent_rooted,
     "Knowledge wiki CONTENT curation (#331): create/update/search/archive articles, " <>
       "conflict resolution, KB scopes. Corpus ADMINISTRATION (re-embedding, " <>
       "ingestion-anomaly resolution) is a separate, human-anchored surface — see " <>
       "knowledge_corpus_admin."},
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
     "WRITES to kind: work projects, epics, stories, dependencies, orchestrator state, " <>
       "and bulk IMPORT. Reading projects/epics/stories stays open, and so does bulk " <>
       "EXPORT — it reads what you already own."},
    {:chain_of_custody, :human_anchored,
     "Story lifecycle WRITES (claim/start/report/review-complete/verify), bulk lifecycle " <>
       "operations, artifact reports, capability-token recovery. Reading story status, " <>
       "history and artifact reports stays open."},
    {:dispatch, :human_anchored,
     "Minting per-dispatch ephemeral keys and lineage paths (L4). Reading your own " <>
       "dispatches stays open."},
    {:token_budgets, :human_anchored,
     "RECORDING token usage (POST /api/v1/token-usage — the per-dispatch usage report " <>
       "agents emit at end of work), correcting/deleting usage records, token budgets, " <>
       "and cost-anomaly triage. Reading usage, budgets and anomalies stays open."},
    {:context_retriever_entities, :human_anchored,
     "Declaring/updating/deleting Context Retriever entity definitions (a security root). " <>
       "Listing entities and QUERYING them via the cr_* tools stays open — see " <>
       "context_retriever_queries."},
    {:knowledge_corpus_admin, :human_anchored,
     "Knowledge CORPUS administration WRITES: re-embedding the corpus and resolving " <>
       "ingestion anomalies. Corpus-wide and cost-bearing, unlike single-article curation " <>
       "(knowledge_base), which stays agent-native. Listing/reading embedding status and " <>
       "ingestion anomalies stays open."},
    {:skills, :human_anchored,
     "Skill definitions and versions (create/update/archive/new version/import) and " <>
       "recorded skill results. Reading skills and cost-performance stays open."}
  ]

  # The `RequireHumanAnchor` mounts each `:human_anchored` surface covers. This is
  # the mechanical binding between the advertised map and the enforced gate —
  # `tier_capabilities_test.exs` scans `lib/loopctl_web/controllers` for the plug
  # and asserts this map matches, in BOTH directions.
  @gated_controllers %{
    work_breakdown: [
      "LoopctlWeb.ProjectController",
      "LoopctlWeb.EpicController",
      "LoopctlWeb.StoryController",
      "LoopctlWeb.EpicDependencyController",
      "LoopctlWeb.StoryDependencyController",
      "LoopctlWeb.OrchestratorStateController",
      "LoopctlWeb.ImportExportController"
    ],
    chain_of_custody: [
      "LoopctlWeb.StoryStatusController",
      "LoopctlWeb.StoryVerificationController",
      "LoopctlWeb.ReviewRecordController",
      "LoopctlWeb.ArtifactReportController",
      "LoopctlWeb.BulkOperationsController",
      "LoopctlWeb.CapRecoveryController"
    ],
    dispatch: ["LoopctlWeb.DispatchController"],
    token_budgets: [
      "LoopctlWeb.TokenBudgetController",
      "LoopctlWeb.TokenUsageController",
      "LoopctlWeb.CostAnomalyController"
    ],
    context_retriever_entities: ["LoopctlWeb.ContextRetrieverController"],
    knowledge_corpus_admin: [
      "LoopctlWeb.KnowledgeEmbeddingController",
      "LoopctlWeb.IngestionAnomalyController"
    ],
    skills: ["LoopctlWeb.SkillController", "LoopctlWeb.SkillResultController"]
  }

  @learn_more "https://loopctl.com/wiki/chain-of-custody"

  # The upgrade is an IN-PLACE tier flip on the tenant you already own, not a new
  # signup: enrolling the first WebAuthn authenticator against an existing
  # agent_rooted tenant flips it to human_anchored
  # (`LoopctlWeb.TenantAuthenticatorController.create/2`). A bare link to the
  # signup ceremony sent the caller to create a SECOND tenant and strand the
  # knowledge this one owns, so this block carries the machine-actionable tools
  # and endpoints, exactly like `agent_native_alternative` does.
  @enrollment_upgrade %{
    summary:
      "Upgrade THIS tenant in place by enrolling a WebAuthn authenticator against it. " <>
        "Do NOT sign up a second tenant — that strands the knowledge this one already owns. " <>
        "The first enrollment on an agent_rooted tenant flips it to human_anchored.",
    tools: ["request_authenticator_challenge", "enroll_authenticator"],
    endpoints: [
      "POST /api/v1/tenants/:id/authenticators/challenge",
      "POST /api/v1/tenants/:id/authenticators"
    ],
    requires_human: true,
    requires_role: "user",
    docs: "https://loopctl.com/wiki/tenant-signup"
  }

  @role_note "Statuses describe the TRUST-TIER gate on MUTATING actions only. " <>
               "Reads stay open on every surface, including blocked ones, and the " <>
               "role gate (RequireRole) applies independently — an `allowed` surface " <>
               "can still return 403 insufficient_role if your key's role is too low."

  @remediation %{learn_more: @learn_more, enrollment_upgrade: @enrollment_upgrade}

  # Built ONCE at compile time, per tier: the map is static per `trust_tier` (no
  # tenant data in it), so there is nothing to recompute per request. Rebuilding
  # it on every `GET /tenants/me` and every 403 was pure repeated work.
  @tier_maps (fn ->
                at_least? = fn
                  _tier, :agent_rooted -> true
                  :human_anchored, :human_anchored -> true
                  _tier, :human_anchored -> false
                end

                build = fn tier ->
                  {allowed, blocked} =
                    Enum.split_with(@surfaces, fn {_surface, min_tier, _desc} ->
                      at_least?.(tier, min_tier)
                    end)

                  blocked_names = Enum.map(blocked, &elem(&1, 0))

                  base = %{
                    trust_tier: tier,
                    scope: "trust_tier_only",
                    applies_to: "mutating_actions",
                    note: @role_note,
                    surfaces:
                      Map.new(@surfaces, fn {surface, min_tier, _desc} ->
                        {surface,
                         if(at_least?.(tier, min_tier),
                           do: "allowed",
                           else: "requires_human_anchor"
                         )}
                      end),
                    allowed: Enum.map(allowed, &elem(&1, 0)),
                    blocked: blocked_names,
                    descriptions:
                      Map.new(@surfaces, fn {surface, _min, desc} -> {surface, desc} end)
                  }

                  case blocked_names do
                    [] -> base
                    _ -> Map.put(base, :remediation, @remediation)
                  end
                end

                Map.new([:agent_rooted, :human_anchored], fn tier -> {tier, build.(tier)} end)
              end).()

  @doc """
  Capability map for a tenant. See `for_tier/1`.

  Accepts anything carrying a `:trust_tier` key (a `Tenant` struct in production;
  a bare map in tests and in the plug's defensive path), and an unknown shape
  falls back to the most restrictive map rather than crashing a read endpoint.
  The spec is deliberately wider than `Tenant.t()` so those fail-safe clauses are
  contractually reachable — this repo bans `@dialyzer` suppressions.
  """
  @spec for_tenant(Tenant.t() | map() | term()) :: map()
  def for_tenant(%Tenant{trust_tier: tier}), do: for_tier(tier)
  def for_tenant(%{trust_tier: tier}), do: for_tier(tier)

  # An unshaped/nil tenant is a genuine misconfiguration — route it through the
  # SAME flagging path as an unknown tier (`unknown_tier: true`) rather than
  # returning a clean agent_rooted map. Returning the unflagged map would have
  # the body assert `trust_tier: agent_rooted` as fact about a tenant that could
  # not be resolved, and a client branching on `unknown_tier` would get a false
  # negative on exactly the path the flag exists for.
  def for_tenant(_other), do: for_tier(:unknown_tenant)

  @doc """
  Capability map for a `trust_tier`.

  Shape:

      %{
        trust_tier: :agent_rooted,
        scope: "trust_tier_only",       # role gates apply independently
        applies_to: "mutating_actions", # reads stay open on every surface
        note: "...",
        surfaces: %{knowledge_base: "allowed", work_breakdown: "requires_human_anchor", ...},
        allowed: [:agent_memory, :coordination_bus, ...],
        blocked: [:chain_of_custody, :dispatch, ...],
        descriptions: %{work_breakdown: "kind: work projects, epics, ...", ...},
        remediation: %{...}   # present only when `blocked` is non-empty
      }

  A `:human_anchored` tenant has an EMPTY `blocked` list and no `remediation` key
  — there is nothing left to remediate.

  An unknown tier yields the most restrictive map, re-stamped with the tier it was
  actually asked about plus `unknown_tier: true`, so a misconfiguration is visible
  instead of the body self-reporting a tier the tenant is not on.
  """
  @spec for_tier(tier() | term()) :: map()
  def for_tier(tier) when tier in [:agent_rooted, :human_anchored],
    do: Map.fetch!(@tier_maps, tier)

  # An unknown or nil tier must not crash `GET /tenants/me`, and must not be
  # advertised optimistically: fall back to the MOST RESTRICTIVE map. If a third
  # tier is ever added, this under-advertises it (surfaces read as blocked that
  # the tier may actually allow) rather than promising a surface the gate denies
  # — the direction that fails safe. Add the tier to @surfaces to fix it properly.
  def for_tier(unknown) do
    @tier_maps
    |> Map.fetch!(:agent_rooted)
    |> Map.merge(%{trust_tier: printable_tier(unknown), unknown_tier: true})
  end

  # This map is JSON-encoded inside a 403 body and in `GET /tenants/me`. Echoing
  # a caller-supplied term verbatim would let a non-encodable one (tuple, pid,
  # struct) raise from inside the error path and turn a deliberate fail-safe 403
  # into a 500 — the opposite of what this defensive clause is for.
  defp printable_tier(tier) when is_atom(tier) or is_binary(tier), do: tier
  defp printable_tier(tier), do: inspect(tier)

  @doc """
  The capability map minus `:descriptions`.

  The descriptions are static prose (a couple of KB) that never change per
  tenant. They belong on the up-front advertisement (`GET /api/v1/tenants/me`),
  which a caller reads once; repeating them on every 403 is gratuitous bandwidth
  on an error path. Everything a caller must BRANCH on — `surfaces`, `allowed`,
  `blocked`, `scope`, `note`, `remediation` — is retained.
  """
  @spec compact(map()) :: map()
  def compact(capabilities), do: Map.delete(capabilities, :descriptions)

  @doc """
  `for_tenant/1`, compacted for embedding in an error body. See `compact/1`.
  """
  @spec compact_for_tenant(Tenant.t() | map() | term()) :: map()
  def compact_for_tenant(tenant), do: tenant |> for_tenant() |> compact()

  @doc """
  The remediation block shared by the capability map and the
  `custody_tier_required` 403 body, so both point at the same upgrade path.
  """
  @spec remediation() :: map()
  def remediation, do: @remediation

  @doc """
  Every known surface name. Useful for tests asserting the map is exhaustive.
  """
  @spec surfaces() :: [surface()]
  def surfaces, do: Enum.map(@surfaces, &elem(&1, 0))

  @doc """
  Per-`:human_anchored`-surface list of the controller module names (as strings)
  that mount `LoopctlWeb.Plugs.RequireHumanAnchor`.

  The drift guard in `tier_capabilities_test.exs` compares this against a scan of
  the controller sources in both directions, so `@surfaces` cannot silently
  advertise a gated surface as allowed.
  """
  @spec gated_controllers() :: %{surface() => [String.t()]}
  def gated_controllers, do: @gated_controllers
end
