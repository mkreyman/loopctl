defmodule LoopctlWeb.Plugs.RequireHumanAnchor do
  @moduledoc """
  US-26.7.1 — gates the work-breakdown / chain-of-custody surface behind the
  TENANT's `trust_tier`, deliberately orthogonal to role.

  A role-based gate would be trivially escaped by a tenant self-minting a
  higher-role key (`ApiKeyController.create` only blocks minting
  `superadmin`; a `role: :user` caller can mint an `orchestrator` key
  today). Keying on `current_tenant.trust_tier` instead closes that bypass:
  no key a tenant can mint for itself changes its own trust tier.

  ## Behavior

  - Superadmin with NO impersonation (`current_tenant: nil` — set by
    `LoopctlWeb.Plugs.SetTenant`'s identical pattern-match convention for a
    `tenant_id: nil` key) passes through unconditionally. This is a LEADING
    clause so it never falls through to a crash on a nil tenant.
  - `trust_tier: :human_anchored` passes through.
  - `trust_tier: :agent_rooted` halts with `403 custody_tier_required`.
  - No `current_tenant` assign AT ALL (the key is absent — distinct from the
    superadmin `current_tenant: nil` case above, which passes) is treated as
    NOT human-anchored and halts.

  `LoopctlWeb.Plugs.Impersonate` reassigns `current_tenant` to the
  impersonated tenant BEFORE controller plugs run, so a superadmin
  impersonating an agent-rooted tenant is correctly routed through THAT
  tenant's tier (not exempted).

  ## Usage

  Applied per-controller, exactly like `RequireRole`, and composes with it
  (both plugs must pass):

      plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:create, :update, :delete]

  ### `:alternative` (optional, #505)

  A mount MAY name the agent-native endpoint that covers the adjacent
  non-custody need, which is surfaced as `remediation.agent_native_alternative`
  in the 403 body:

      plug LoopctlWeb.Plugs.RequireHumanAnchor,
           [
             alternative: %{
               tool: "create_kb_scope",
               endpoint: "POST /api/v1/kb-scopes",
               description: "..."
             }
           ]
           when action in [:create]

  Only pass it where an alternative GENUINELY exists — an invented one is worse
  than none, and "genuinely" is per-ACTION, not per-controller: `create_kb_scope`
  substitutes for `POST /projects` but is no substitute for updating or deleting
  an existing work project, so `ProjectController` mounts it `when action in
  [:create]` and mounts a bare gate for `:update`/`:delete`. Most custody
  endpoints have no substitute by design, and those mounts pass no opts.

  `init/1` validates the opts at COMPILE time: an unknown key (a typo like
  `alternatve:`) or a malformed `:alternative` map raises there rather than
  silently degrading the 403 back into the pre-#505 dead end.

  ## Discoverability (#505)

  The 403 was previously a dead end: it told the caller the surface was closed
  but not which surfaces were open, so an agent-rooted tenant could only map the
  boundary by taking a 403 per endpoint. The body now embeds
  `Loopctl.Tenants.TierCapabilities.compact_for_tenant/1` — the same map advertised
  up front on `GET /api/v1/tenants/me`, minus the static per-surface
  `descriptions` (static prose has no business on a hot error path) — so a caller
  can either read it before writing or recover from the 403 without a second
  round trip.

  The map covers the TIER gate only. `RequireRole` is a separate, orthogonal gate
  that can 403 the same request with `code: "insufficient_role"`; that body
  carries the same capability block for the same reason.

  This is discoverability only. The gate itself is unchanged: it is L0 of the
  trust model, and letting an agent-rooted tenant open a custody surface for
  itself is precisely the failure the product exists to prevent.

  The body carries `error.remediation` AND `error.capabilities.remediation`.
  They are not rivals: the OUTER one wins — it is the same block plus the
  mount's `agent_native_alternative`, when one exists. The inner copy is the
  capability map's own, unconditioned by which endpoint 403'd. This is stated
  on `Loopctl.ApiSpec.Schemas.ErrorResponse` too, so a spec-driven client reads
  the same rule.
  """

  @behaviour Plug

  import Plug.Conn

  alias Loopctl.Tenants.TierCapabilities

  @alternative_keys [:tool, :endpoint, :description]

  @impl true
  # `is_list/1` alone would admit a NON-keyword list (`plug RequireHumanAnchor,
  # ["create_kb_scope"]`), and `Keyword.keys/1` would then raise an opaque stdlib
  # error instead of the guidance below. `Keyword.keyword?/1` is a function, not a
  # guard, so the check has to happen in the body.
  def init(opts) do
    if not Keyword.keyword?(opts) do
      raise ArgumentError,
            "#{inspect(__MODULE__)} expects a keyword list of options, got: #{inspect(opts)}"
    end

    case Keyword.keys(opts) -- [:alternative] do
      [] ->
        validate_alternative!(Keyword.get(opts, :alternative))

      unknown ->
        raise ArgumentError,
              "#{inspect(__MODULE__)}: unknown option(s) #{inspect(unknown)}; only :alternative is supported"
    end

    opts
  end

  @impl true
  def call(%{assigns: %{current_tenant: nil}} = conn, _opts) do
    # Superadmin, not impersonating — ResolveApiKey assigns `current_tenant: nil`
    # for a tenant_id-nil (superadmin) key, mirroring SetTenant's identical
    # `tenant_id: nil` convention. No tenant to gate against.
    conn
  end

  def call(%{assigns: %{current_tenant: %{trust_tier: :human_anchored}}} = conn, _opts) do
    conn
  end

  def call(conn, opts) do
    conn
    |> put_status(:forbidden)
    |> Phoenix.Controller.json(%{
      error: %{
        status: 403,
        code: "custody_tier_required",
        message:
          "This operation requires a human-anchored tenant (a WebAuthn signup ceremony). " <>
            "Your tenant is on the agent-rooted knowledge-base tier, which does not " <>
            "include the work-breakdown / chain-of-custody surface.",
        capabilities: capabilities(conn),
        remediation: remediation(opts)
      }
    })
    |> halt()
  end

  # An ABSENT `current_tenant` assign — distinct from the nil superadmin case,
  # which the leading `call/2` clause above lets through — should not happen this
  # late in the pipeline. If it does, `for_tenant/1` falls back to the most
  # restrictive tier's map (flagged `unknown_tier: true`) rather than crashing or
  # omitting the block.
  #
  # `compact/1`: the per-surface descriptions are static prose repeated on every
  # denial. They are advertised once by `GET /api/v1/tenants/me`; the error path
  # carries only what the caller branches on.
  defp capabilities(conn),
    do: TierCapabilities.compact_for_tenant(conn.assigns[:current_tenant])

  defp remediation(opts) when is_list(opts) do
    base = TierCapabilities.remediation()

    case Keyword.get(opts, :alternative) do
      nil -> base
      alternative -> Map.put(base, :agent_native_alternative, alternative)
    end
  end

  defp remediation(_opts), do: TierCapabilities.remediation()

  # Compile-time opt validation: a silently-dropped alternative regresses the 403
  # to the pre-#505 dead end with no other symptom, so a malformed mount must
  # fail loudly at boot instead.
  defp validate_alternative!(nil), do: :ok

  defp validate_alternative!(%{} = alternative) do
    missing =
      Enum.reject(@alternative_keys, fn key ->
        is_binary(Map.get(alternative, key))
      end)

    case missing do
      [] ->
        :ok

      _ ->
        raise ArgumentError,
              "#{inspect(__MODULE__)}: :alternative must carry string #{inspect(@alternative_keys)}; " <>
                "missing or non-string: #{inspect(missing)}"
    end
  end

  defp validate_alternative!(other) do
    raise ArgumentError,
          "#{inspect(__MODULE__)}: :alternative must be a map, got: #{inspect(other)}"
  end
end
