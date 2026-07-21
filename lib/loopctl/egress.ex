defmodule Loopctl.Egress do
  @moduledoc """
  Context for the fail-closed no-egress guard (US-41.4).

  Owns three pieces of tenant state — all RLS-protected (AC-41.4.11):

    * `local_only` **scope markings** at tenant and project scope (AC-41.4.1/.2);
    * **tenant-declared trusted endpoints** (AC-41.4.5) — an UNVERIFIED TENANT
      ATTESTATION, never network-local;
    * **aggregated blocked-decision records** (AC-41.4.6), deduplicated per
      `(scope, endpoint, reason, window)` with an occurrence count.

  The operator deployment allowlist is deliberately NOT here: it is
  deployment-scoped, unwritable at every role, and lives outside RLS
  (`Loopctl.Egress.Allowlist`).

  ## Asymmetric roles on the marking

  ENABLING `local_only` (tightening) is `:orchestrator`+; DISABLING/CLEARING it
  is `:user`. Clearing is exactly the self-widening move the allowlist forbids,
  and would otherwise let an agent re-open egress one tool call before a harvest
  while US-41.7's witnessed claim faithfully attested the weakened posture. The
  role gate lives in `LoopctlWeb.EgressController`; both transitions are audited
  here.

  ## Mandatory pre-flight on ENABLE

  Because the enabling role cannot undo the transition, `enable_local_only/3`
  classifies the scope's currently-resolved embedding and chat endpoints FIRST.
  If any would become `egress_blocked` the operation is REFUSED with
  `{:error, {:would_block, endpoints}}` naming each offending endpoint — UNLESS
  the caller passes `acknowledge: true`, in which case it completes and REPORTS
  the resulting blocked posture. (We chose refuse-by-default-with-an-explicit-
  acknowledgement rather than hard refusal, so a tenant that genuinely intends a
  temporary blocked posture can still opt in — but never silently.) A silent
  enable would be a tenant-wide outage, undoable only by a human `:user` key,
  triggered by an orchestrator-role or compromised dispatch key.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Egress.Allowlist
  alias Loopctl.Egress.BlockedDecision
  alias Loopctl.Egress.PinCache
  alias Loopctl.Egress.Policy
  alias Loopctl.Egress.Scope
  alias Loopctl.Egress.ScopeMarking
  alias Loopctl.Egress.TrustedEndpoint

  @blocked_window_seconds 60

  @doc """
  The label used EVERYWHERE a tenant declaration surfaces. Verbatim, by contract
  (AC-41.4.5): a declaration is an unverified tenant attestation and must never
  be presented as network-local.
  """
  @tenant_declared_label "tenant-declared (unverified attestation), not network-local"
  @spec tenant_declared_label() :: String.t()
  def tenant_declared_label, do: @tenant_declared_label

  # ---------------------------------------------------------------------------
  # Scope markings
  # ---------------------------------------------------------------------------

  @doc """
  The EFFECTIVE `local_only` marking for `scope`: the MOST RESTRICTIVE of the
  tenant and project markings (`project OR tenant`).

  A project can NEVER relax a tenant marking, and a project-less scope (a
  tenant-wide article, any memory) inherits the TENANT marking.
  """
  @spec effective_local_only?(Scope.t()) :: boolean()
  def effective_local_only?(%Scope{tenant_id: tenant_id, project_id: project_id}) do
    base =
      ScopeMarking
      |> where([m], m.tenant_id == ^tenant_id and m.local_only == true)

    query =
      case project_id do
        # A project-less scope (a tenant-wide article, any memory) sees ONLY the
        # tenant marking. `is_nil/1` is required — Ecto forbids `== ^nil`.
        nil -> where(base, [m], is_nil(m.project_id))
        id -> where(base, [m], is_nil(m.project_id) or m.project_id == ^id)
      end

    query |> limit(1) |> AdminRepo.exists?()
  end

  @doc "The raw marking row for a scope, or `nil`."
  @spec get_marking(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: ScopeMarking.t() | nil
  def get_marking(tenant_id, project_id \\ nil) do
    ScopeMarking
    |> where([m], m.tenant_id == ^tenant_id)
    |> scope_project(project_id)
    |> AdminRepo.one()
  end

  @doc "Every marking row for a tenant (posture report)."
  @spec list_markings(Ecto.UUID.t()) :: [ScopeMarking.t()]
  def list_markings(tenant_id) do
    ScopeMarking
    |> where([m], m.tenant_id == ^tenant_id)
    |> order_by([m], asc: m.project_id)
    |> AdminRepo.all()
  end

  @doc """
  ENABLE `local_only` on a scope (role `:orchestrator`+, gated in the
  controller).

  Runs the MANDATORY PRE-FLIGHT first: every currently-resolved endpoint for the
  scope is classified, and if any would become `egress_blocked` the call returns
  `{:error, {:would_block, endpoints}}` naming each one. Pass
  `acknowledge: true` to proceed anyway; the returned map then REPORTS the
  resulting blocked posture.

  Emits a high-priority audit event AND the alertable
  `[:loopctl, :egress, :local_only_enabled]` telemetry event naming the actor,
  the scope and the count of endpoints that became blocked.
  """
  @spec enable_local_only(Ecto.UUID.t(), Ecto.UUID.t() | nil, keyword()) ::
          {:ok, map()} | {:error, {:would_block, [map()]} | Ecto.Changeset.t()}
  def enable_local_only(tenant_id, project_id, opts \\ []) do
    scope = Scope.new(tenant_id, project_id)
    acknowledge = Keyword.get(opts, :acknowledge, false)
    blocked = preflight_blocked_endpoints(scope)

    if blocked != [] and not acknowledge do
      {:error, {:would_block, blocked}}
    else
      do_enable(scope, blocked, opts)
    end
  end

  @doc """
  CLEAR the `local_only` marking on a scope. Role `:user` ONLY (gated in the
  controller) — clearing is the self-widening move an agent must never make.
  """
  @spec clear_local_only(Ecto.UUID.t(), Ecto.UUID.t() | nil, keyword()) ::
          {:ok, :cleared} | {:error, term()}
  def clear_local_only(tenant_id, project_id, opts \\ []) do
    scope = Scope.new(tenant_id, project_id)

    Multi.new()
    |> Multi.run(:delete, fn _repo, _changes ->
      {count, _} =
        ScopeMarking
        |> where([m], m.tenant_id == ^tenant_id)
        |> scope_project(project_id)
        |> AdminRepo.delete_all()

      {:ok, count}
    end)
    |> Audit.log_in_multi(:audit, fn _changes ->
      audit_attrs(tenant_id, scope, "egress.local_only_cleared", opts, %{local_only: false})
    end)
    |> AdminRepo.transaction()
    |> case do
      {:ok, _changes} ->
        PinCache.invalidate_tenant(tenant_id)
        {:ok, :cleared}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  defp do_enable(%Scope{tenant_id: tenant_id, project_id: project_id} = scope, blocked, opts) do
    now = DateTime.utc_now()

    attrs = %{
      project_id: project_id,
      local_only: true,
      enabled_by_actor_type: Keyword.get(opts, :actor_type, "api_key"),
      enabled_by_actor_id: Keyword.get(opts, :actor_id),
      enabled_at: now,
      acknowledged_blocked_endpoints: Enum.map(blocked, & &1.endpoint)
    }

    changeset =
      (get_marking(tenant_id, project_id) || %ScopeMarking{tenant_id: tenant_id})
      |> ScopeMarking.changeset(attrs)

    Multi.new()
    |> Multi.insert_or_update(:marking, changeset)
    |> Audit.log_in_multi(:audit, fn _changes ->
      audit_attrs(tenant_id, scope, "egress.local_only_enabled", opts, %{
        local_only: true,
        blocked_endpoints: Enum.map(blocked, & &1.endpoint),
        acknowledged: Keyword.get(opts, :acknowledge, false)
      })
    end)
    |> AdminRepo.transaction()
    |> case do
      {:ok, %{marking: marking}} ->
        PinCache.invalidate_tenant(tenant_id)

        :telemetry.execute(
          [:loopctl, :egress, :local_only_enabled],
          %{count: 1, blocked_endpoint_count: length(blocked)},
          %{
            tenant_id: tenant_id,
            scope: Scope.key(scope),
            actor_id: Keyword.get(opts, :actor_id),
            actor_type: Keyword.get(opts, :actor_type, "api_key")
          }
        )

        {:ok, %{marking: marking, blocked_endpoints: blocked}}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  # The pre-flight. Endpoint resolution is TENANT-scoped only, so this classifies
  # the tenant's currently-resolved embedding + chat endpoints for the scope.
  defp preflight_blocked_endpoints(%Scope{} = scope) do
    scope
    |> resolved_endpoints()
    |> Enum.map(fn {kind, url} -> {kind, url, endpoint_verdict(scope, url)} end)
    |> Enum.reject(fn {_kind, _url, verdict} ->
      verdict in [:network_local, :tenant_declared]
    end)
    |> Enum.map(fn {kind, url, verdict} ->
      %{kind: kind, endpoint: url, verdict: to_string(verdict)}
    end)
  end

  @doc """
  The endpoints currently resolved for a scope, as `{kind, url}` pairs.

  Endpoint resolution is TENANT-SCOPED ONLY (AC-41.4.2) — there is no
  project-level endpoint override anywhere in loopctl. Today these are the
  hardcoded vendor defaults / the configured embedding provider; US-41.2 makes
  them configurable and this function is the single place that changes.
  """
  @spec resolved_endpoints(Scope.t()) :: [{atom(), String.t()}]
  def resolved_endpoints(%Scope{}) do
    embedding_base =
      :loopctl
      |> Application.get_env(:embedding_provider, %{})
      |> Map.get(:base_url, "https://api.openai.com/v1")

    chat_base =
      Application.get_env(:loopctl, :anthropic_base_url, "https://api.anthropic.com/v1")

    [{:embedding, embedding_base}, {:chat, chat_base}]
  end

  defp endpoint_verdict(scope, url) do
    host = URI.parse(url).host || url

    case Policy.classify(scope, host, :inference) do
      {:ok, %{verdict: verdict}} -> verdict
      {:error, _} -> :unclassifiable
    end
  end

  # ---------------------------------------------------------------------------
  # Tenant-declared trusted endpoints
  # ---------------------------------------------------------------------------

  @doc "Lists the tenant's declared trusted endpoints."
  @spec list_trusted_endpoints(Ecto.UUID.t()) :: [TrustedEndpoint.t()]
  def list_trusted_endpoints(tenant_id) do
    TrustedEndpoint
    |> where([e], e.tenant_id == ^tenant_id)
    |> order_by([e], asc: e.host)
    |> AdminRepo.all()
  end

  @doc """
  The declared purposes for `host` under `tenant_id`, or `[]` when undeclared.

  Used by `Loopctl.Egress.Policy` on a cache miss only — the hot path reads the
  pin cache, never the database.
  """
  @spec declared_purposes(Ecto.UUID.t(), String.t()) :: [String.t()]
  def declared_purposes(tenant_id, host) when is_binary(host) do
    normalized = String.downcase(host)

    TrustedEndpoint
    |> where([e], e.tenant_id == ^tenant_id and e.host == ^normalized)
    |> select([e], e.purposes)
    |> AdminRepo.one()
    |> List.wrap()
  end

  @doc """
  Declares a host as tenant-trusted for one or more purposes. Role `:user` ONLY.

  The declaration is an UNVERIFIED TENANT ATTESTATION. Write-time validation
  enforces public-addresses-only, purpose scoping and the vendor-host exclusion
  (see `Loopctl.Egress.TrustedEndpoint`); the public-address check runs AGAIN at
  pin time, so DNS that changes after the write cannot smuggle a private target
  through.
  """
  @spec declare_trusted_endpoint(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, TrustedEndpoint.t()} | {:error, Ecto.Changeset.t() | term()}
  def declare_trusted_endpoint(tenant_id, attrs, opts \\ []) do
    changeset =
      %TrustedEndpoint{tenant_id: tenant_id}
      |> TrustedEndpoint.changeset(
        Map.merge(attrs, %{
          "declared_by_actor_type" => Keyword.get(opts, :actor_type, "api_key"),
          "declared_by_actor_id" => Keyword.get(opts, :actor_id)
        })
      )

    Multi.new()
    |> Multi.insert(:endpoint, changeset)
    |> Audit.log_in_multi(:audit, fn %{endpoint: endpoint} ->
      tenant_id
      |> audit_attrs(Scope.new(tenant_id), "egress.trusted_endpoint_declared", opts, %{
        host: endpoint.host,
        purposes: endpoint.purposes,
        label: @tenant_declared_label
      })
      |> Map.put(:entity_id, endpoint.id)
    end)
    |> AdminRepo.transaction()
    |> case do
      {:ok, %{endpoint: endpoint}} ->
        PinCache.invalidate_tenant(tenant_id)
        {:ok, endpoint}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  @doc """
  Revokes a declaration. Invalidation is IMMEDIATE — a revoked declaration must
  not keep working for the remainder of the pin TTL (AC-41.4.12).
  """
  @spec revoke_trusted_endpoint(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, :revoked} | {:error, :not_found}
  def revoke_trusted_endpoint(tenant_id, host, opts \\ []) do
    normalized = String.downcase(host)

    TrustedEndpoint
    |> where([e], e.tenant_id == ^tenant_id and e.host == ^normalized)
    |> AdminRepo.one()
    |> case do
      nil ->
        {:error, :not_found}

      endpoint ->
        {:ok, _} = AdminRepo.delete(endpoint)
        PinCache.invalidate_tenant(tenant_id)

        Audit.create_log_entry(
          tenant_id,
          audit_attrs(tenant_id, Scope.new(tenant_id), "egress.trusted_endpoint_revoked", opts, %{
            host: normalized
          })
        )

        {:ok, :revoked}
    end
  end

  # ---------------------------------------------------------------------------
  # Blocked decisions — aggregated, bounded
  # ---------------------------------------------------------------------------

  @doc """
  Records ONE blocked decision.

  Writes are DEDUPLICATED per `(scope, endpoint, reason, window)` — a single
  upsert bumping `occurrence_count` — so a misconfigured harvest loop produces
  one row per minute per tuple, not thousands. The exact per-call rate lives in
  the `[:loopctl, :egress, :blocked]` telemetry counter emitted here.
  """
  @spec record_blocked(Scope.t(), map()) :: :ok
  def record_blocked(%Scope{} = scope, details) do
    host = Map.get(details, :host) || "unknown"
    reason = details |> Map.get(:verdict, :non_local) |> to_string()
    window = current_window()

    :telemetry.execute(
      [:loopctl, :egress, :blocked],
      %{count: 1},
      %{
        tenant_id: scope.tenant_id,
        scope: Scope.key(scope),
        endpoint_host: host,
        reason: reason
      }
    )

    now = DateTime.utc_now()

    AdminRepo.insert_all(
      BlockedDecision,
      [
        %{
          id: Ecto.UUID.generate(),
          tenant_id: scope.tenant_id,
          project_id: scope.project_id,
          scope_key: Scope.key(scope),
          endpoint_host: host,
          reason: reason,
          window_start: window,
          occurrence_count: 1,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: [inc: [occurrence_count: 1], set: [updated_at: now]],
      conflict_target:
        {:unsafe_fragment, "(tenant_id, scope_key, endpoint_host, reason, window_start)"}
    )

    :ok
  rescue
    # Recording must never fail the refusal itself — the refusal already happened
    # and no data left the boundary.
    e ->
      Logger.error("Loopctl.Egress: blocked-decision recording failed: #{Exception.message(e)}")
      :ok
  end

  @doc "Blocked-decision rows for a tenant (US-41.7 turns these into the custody claim)."
  @spec list_blocked_decisions(Ecto.UUID.t(), keyword()) :: [BlockedDecision.t()]
  def list_blocked_decisions(tenant_id, opts \\ []) do
    BlockedDecision
    |> where([d], d.tenant_id == ^tenant_id)
    |> order_by([d], desc: d.window_start)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> AdminRepo.all()
  end

  defp current_window do
    now = DateTime.utc_now()
    secs = div(DateTime.to_unix(now), @blocked_window_seconds) * @blocked_window_seconds
    # `:utc_datetime_usec` demands {0, 6} precision; `from_unix!/1` yields {0, 0}
    # and `truncate/2` only ever REDUCES precision, so stamp it explicitly.
    %{DateTime.from_unix!(secs) | microsecond: {0, 6}}
  end

  # ---------------------------------------------------------------------------
  # Posture
  # ---------------------------------------------------------------------------

  @doc """
  The machine-readable egress posture for a tenant (AC-41.4.8).

  Endpoints are shown; KEYS NEVER ARE. The deployment allowlist CONTENTS are
  disclosed only at role `:user`+ (`role: :user` / `:superadmin`): at `:agent`
  the payload carries only a BOOLEAN saying whether a verdict came from the
  allowlist. Operator infrastructure is not disclosed to the lowest-privileged
  key of every tenant.

  ## Scope of the guarantee

  This story covers MODEL-PROVIDER egress only. Webhook delivery
  (`Loopctl.Webhooks.ReqDelivery`) bypasses this guard and is handled in US-41.5,
  so the report says so explicitly rather than implying total egress control.
  """
  @spec posture(Ecto.UUID.t(), atom()) :: map()
  def posture(tenant_id, role \\ :agent) do
    scope = Scope.new(tenant_id)

    endpoints =
      scope
      |> resolved_endpoints()
      |> Enum.map(fn {kind, url} -> endpoint_posture(scope, kind, url) end)

    declared =
      tenant_id
      |> list_trusted_endpoints()
      |> Enum.map(
        &%{
          host: &1.host,
          purposes: &1.purposes,
          locality_label: @tenant_declared_label,
          declared_at: &1.inserted_at
        }
      )

    scopes =
      tenant_id
      |> list_markings()
      |> Enum.map(
        &%{
          scope: if(is_nil(&1.project_id), do: "tenant", else: "project:#{&1.project_id}"),
          project_id: &1.project_id,
          local_only: &1.local_only,
          # encrypt_body ships in US-41.6 (which depends on this story); the field
          # is reserved here so the posture contract does not change shape later.
          encrypt_body: false
        }
      )

    base = %{
      tenant_id: tenant_id,
      endpoints: endpoints,
      declared_endpoints: declared,
      scopes: scopes,
      posture_defects: posture_defects(scopes),
      guarantee_scope:
        "Enforced for every outbound HTTP call made by loopctl application code on the " <>
          "MODEL-PROVIDER path. Webhook delivery is NOT yet covered (US-41.5). HTTP " <>
          "performed inside a dependency, and the separate mcp-server/ codebase, are " <>
          "outside the static chokepoint check.",
      tenant_declared_label: @tenant_declared_label
    }

    if role in [:user, :superadmin] do
      Map.put(base, :deployment_allowlist, Allowlist.raw_entries())
    else
      base
    end
  end

  defp endpoint_posture(scope, kind, url) do
    host = URI.parse(url).host || url

    {verdict, from_allowlist} =
      case Policy.classify(scope, host, :inference) do
        {:ok, %{verdict: v, from_allowlist: a}} -> {v, a}
        {:error, _} -> {:unclassifiable, false}
      end

    %{
      kind: kind,
      endpoint: url,
      host: host,
      verdict: verdict_label(verdict),
      # Boolean only at :agent — the allowlist CONTENTS are operator-plane state.
      verdict_from_deployment_allowlist: from_allowlist
    }
  end

  defp verdict_label(:network_local), do: "network-local"
  defp verdict_label(:tenant_declared), do: @tenant_declared_label
  defp verdict_label(:denylisted), do: "non-local (blocked by the SSRF denylist)"
  defp verdict_label(:non_local), do: "non-local"
  defp verdict_label(other), do: to_string(other)

  # Named posture DEFECTS. The first is US-41.6 AC-41.6.13's
  # `encrypted_at_rest_plaintext_in_flight`: encrypt_body enabled on a scope that
  # is NOT local_only. `encrypt_body` ships in US-41.6, so today this never fires
  # — the detector exists so the contract is stable when it does.
  defp posture_defects(scopes) do
    for s <- scopes, s.encrypt_body and not s.local_only do
      %{
        defect: "encrypted_at_rest_plaintext_in_flight",
        scope: s.scope,
        description:
          "encrypt_body is enabled on a scope that is not local_only: bodies are " <>
            "encrypted at rest but still leave the boundary in plaintext."
      }
    end
  end

  # ---------------------------------------------------------------------------

  defp scope_project(query, nil), do: where(query, [m], is_nil(m.project_id))
  defp scope_project(query, project_id), do: where(query, [m], m.project_id == ^project_id)

  defp audit_attrs(tenant_id, scope, action, opts, new_state) do
    %{
      tenant_id: tenant_id,
      entity_type: "egress_scope",
      entity_id: scope.project_id || tenant_id,
      action: action,
      actor_type: Keyword.get(opts, :actor_type, "api_key"),
      actor_id: Keyword.get(opts, :actor_id),
      actor_label: Keyword.get(opts, :actor_label),
      new_state: Map.put(new_state, :scope, Scope.key(scope))
    }
  end
end
