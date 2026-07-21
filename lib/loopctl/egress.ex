defmodule Loopctl.Egress do
  @moduledoc """
  Context for the fail-closed no-egress guard (US-41.4).

  Owns three pieces of tenant state (AC-41.4.11):

    * `local_only` **scope markings** at tenant and project scope (AC-41.4.1/.2);
    * **tenant-declared trusted endpoints** (AC-41.4.5) — an UNVERIFIED TENANT
      ATTESTATION, never network-local;
    * **aggregated blocked-decision records** (AC-41.4.6), deduplicated per
      `(scope, endpoint, reason, window)` with an occurrence count.

  The operator deployment allowlist is deliberately NOT here: it is
  deployment-scoped, unwritable at every role, and lives outside RLS
  (`Loopctl.Egress.Allowlist`).

  ## Isolation mechanism: EXPLICIT tenant scoping on `AdminRepo`, not RLS

  Every read and write in this context goes through `Loopctl.AdminRepo`
  (BYPASSRLS), so the RLS policies the migration installs on the three tables are
  DEFENCE IN DEPTH for any future `Loopctl.Repo`-routed access — they are NOT the
  runtime enforcement mechanism here. Say so plainly rather than labelling the
  isolation tests "RLS": what actually isolates tenants in this context is the
  mandatory `where tenant_id == ^tenant_id` on every query below, and the tests
  named `tenant isolation` prove exactly that.

  `AdminRepo` is deliberate, not an oversight. `effective_local_only?/1` is on the
  egress HOT PATH and is called from Oban workers and background tasks that own no
  `Loopctl.Repo.with_tenant/2` transaction; routing it through RLS would require
  opening a tenant-scoped transaction per provider call. The invariant that
  replaces the policy is therefore mechanical and local: EVERY function here takes
  `tenant_id` (or a `Scope`) as its first argument and filters on it, and
  `tenant_id` is never cast from user input (see `ScopeMarking` / `TrustedEndpoint`).

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
  alias Loopctl.Egress.BlockedBuffer
  alias Loopctl.Egress.BlockedDecision
  alias Loopctl.Egress.PinCache
  alias Loopctl.Egress.Policy
  alias Loopctl.Egress.Scope
  alias Loopctl.Egress.ScopeMarking
  alias Loopctl.Egress.TrustedEndpoint
  alias Loopctl.Knowledge.EmbeddingClient
  alias Loopctl.Llm.Anthropic

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

  Both URLs are read from the CLIENT that resolves them (`EmbeddingClient.base_url/0`
  and `Anthropic.base_url/0`) — never re-derived here. Re-deriving them would make
  the posture report and the pre-flight vet a DUPLICATED CONSTANT that agrees with
  the guard only by coincidence: exactly the "second, divergent URL policy"
  AC-41.4.9 calls a review failure.
  """
  @spec resolved_endpoints(Scope.t()) :: [{atom(), String.t()}]
  def resolved_endpoints(%Scope{}) do
    [{:embedding, EmbeddingClient.base_url()}, {:chat, Anthropic.base_url()}]
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
  # Refusal terms — the ONE mapping from an egress refusal to an Oban outcome
  # ---------------------------------------------------------------------------

  @refusal_tags [:egress_blocked, :pin_stale, :egress_unavailable]

  @doc """
  True for a refusal term in its tagged `{tag, details}` form.

  A GUARD (not a plain function) so call sites can pattern-match the refusal in a
  function head — matching a bare 2-tuple without it would also swallow
  `{:api_error, status}` and friends.
  """
  defguard is_egress_refusal(term)
           when is_tuple(term) and tuple_size(term) == 2 and
                  elem(term, 0) in [:egress_blocked, :pin_stale, :egress_unavailable]

  @doc """
  The three refusal tags `Loopctl.Provider` can return, in the tagged form
  `{tag, details}`. Only `:egress_blocked` is PERMANENT.
  """
  @spec refusal_tags() :: [atom()]
  def refusal_tags, do: @refusal_tags

  @doc """
  Normalizes any refusal term to `{tag, details}`, or `nil` when it is not a
  refusal. Accepts the bare atom form for robustness.
  """
  @spec refusal(term()) :: {atom(), map()} | nil
  def refusal({tag, details}) when tag in @refusal_tags and is_map(details), do: {tag, details}
  def refusal(tag) when tag in @refusal_tags, do: {tag, %{}}
  def refusal(_other), do: nil

  @doc """
  An AGENT-READABLE reason naming the scope and the offending endpoint
  (AC-41.4.6).

  This is what a worker puts in its `{:cancel, reason}` / snooze log, so the Oban
  `cancelled_at` / `errors` record an operator reads names WHICH endpoint was
  refused for WHICH scope — a bare `:egress_blocked` atom names neither.
  """
  @spec refusal_reason({atom(), map()} | atom()) :: String.t()
  def refusal_reason(term) do
    case refusal(term) do
      nil ->
        inspect(term)

      {tag, details} ->
        scope = Map.get(details, :scope, "unknown scope")
        host = Map.get(details, :host) || "unknown endpoint"
        verdict = details |> Map.get(:verdict, :unclassifiable) |> to_string()

        "#{tag}: scope=#{scope} endpoint=#{host} verdict=#{verdict}" <>
          case Map.get(details, :remediation) do
            nil -> ""
            remediation -> " remediation=#{remediation}"
          end
    end
  end

  @doc """
  The ONE mapping from an egress refusal to an Oban worker result (AC-41.4.3).

    * `:egress_blocked` → `{:cancel, reason}`. A PERMANENT configuration state
      that will not change on its own; retrying burns `max_attempts` and
      repopulates the queue on every subsequent write, and no data was sent.
    * `:pin_stale` → `{:snooze, _}`. The tenant's box got a new DHCP lease; the
      supervised refresher re-pins on its own and recovery needs no role `:user`
      write. Cancelling here would permanently drop every in-flight
      embedding/extraction job over an IP change, and nothing re-enqueues a
      cancelled job after the re-pin — the articles would stay un-embedded
      SILENTLY. AC-41.4.3 makes only `:egress_blocked` terminal.
    * `:egress_unavailable` → `{:snooze, _}`. A transient infrastructure failure
      reading the marking, not a privacy refusal at all.
  """
  @spec oban_result({atom(), map()} | atom()) ::
          {:cancel, String.t()} | {:snooze, pos_integer()}
  def oban_result(term) do
    case refusal(term) do
      {:egress_blocked, _details} = refusal ->
        {:cancel, refusal_reason(refusal)}

      {tag, _details} = refusal when tag in [:pin_stale, :egress_unavailable] ->
        Logger.info("Loopctl.Egress: snoozing transient refusal — #{refusal_reason(refusal)}")
        {:snooze, transient_snooze_seconds()}

      nil ->
        {:cancel, inspect(term)}
    end
  end

  @doc """
  The bounded `fallback_reason` tags that mean "the semantic path was refused by
  the EGRESS guard" (AC-41.4.7). Shared by the knowledge and memory halves so the
  degraded contract cannot drift between them.
  """
  @spec egress_fallback_reasons() :: [String.t()]
  def egress_fallback_reasons, do: ~w(egress_blocked pin_stale egress_unavailable)

  @doc """
  The endpoint an EGRESS refusal was about, or `nil` for any other reason.

  AC-41.4.7 asks the degraded meta to name "the offending endpoint" — i.e. the
  endpoint the refusal was ABOUT. For a non-egress reason (`no_embedding_key`,
  `rate_limited_local`, budget shedding, a semantic-index problem) there is no
  offending endpoint, and naming one anyway would send an agent chasing an
  endpoint that had nothing to do with the failure. Callers drop `nil`.
  """
  @spec offending_endpoint(Ecto.UUID.t(), String.t() | atom() | nil) :: String.t() | nil
  def offending_endpoint(tenant_id, reason) do
    if to_string(reason) in egress_fallback_reasons() do
      tenant_id
      |> Scope.new()
      |> resolved_endpoints()
      |> Enum.find_value(fn
        {:embedding, url} -> url
        _ -> nil
      end)
    end
  end

  @doc """
  The AC-41.4.7 degraded-response contract fragment: `degraded`, the reserved
  `excluded_tiers`, and (for an egress refusal only) `offending_endpoint`.

  Shared by `Loopctl.Knowledge` search and `Loopctl.Memory` recall — this story
  threaded the scope through BOTH paths, so both must name the reason and the
  offending endpoint the same way.
  """
  @spec degraded_contract_meta(Ecto.UUID.t(), String.t() | atom() | nil) :: map()
  def degraded_contract_meta(tenant_id, fallback_reason) do
    base = %{degraded: true, excluded_tiers: []}

    case offending_endpoint(tenant_id, fallback_reason) do
      nil -> base
      endpoint -> Map.put(base, :offending_endpoint, endpoint)
    end
  end

  @doc "Seconds a worker snoozes on a TRANSIENT egress refusal (`:pin_stale`, `:egress_unavailable`)."
  @spec transient_snooze_seconds() :: pos_integer()
  def transient_snooze_seconds do
    Application.get_env(:loopctl, :egress_transient_snooze_seconds, 60)
  end

  # ---------------------------------------------------------------------------
  # Blocked decisions — aggregated, bounded
  # ---------------------------------------------------------------------------

  @doc """
  Records ONE blocked decision.

  Rows are DEDUPLICATED per `(scope, endpoint, reason, window)` — a single upsert
  bumping `occurrence_count` — AND the WRITE itself is buffered in ETS by
  `Loopctl.Egress.BlockedBuffer`, so a misconfigured harvest loop produces one
  round-trip per flush interval per tuple rather than one per blocked call.

  Bounding rows alone is not enough: every blocked call would still take a
  row-level lock on the SAME conflict-target row against the 3-connection
  BYPASSRLS pool — the very pool the guard's own marking lookup needs — turning a
  hot loop into pool pressure on the privacy control itself. The EXACT per-call
  rate lives in the `[:loopctl, :egress, :blocked]` telemetry counter emitted
  here, which is unbuffered and never lossy.
  """
  @spec record_blocked(Scope.t(), map()) :: :ok
  def record_blocked(%Scope{} = scope, details) do
    host = Map.get(details, :host) || "unknown"
    reason = details |> Map.get(:verdict, :non_local) |> to_string()

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

    BlockedBuffer.record(scope, host, reason, current_window())
  end

  @doc """
  Flushes this node's buffered blocked-decision counters for `tenant_id` to the
  database NOW. Tenant-scoped so an `async: true` test never drains (and then
  fails to insert) another test's buffered rows.
  """
  @spec flush_blocked_decisions(Ecto.UUID.t()) :: :ok
  def flush_blocked_decisions(tenant_id), do: BlockedBuffer.flush_tenant(tenant_id)

  @doc false
  # The actual upsert, called by the buffer's flush. `count` is the number of
  # blocked calls accumulated for the tuple since the last flush.
  @spec upsert_blocked_decision(map(), pos_integer()) :: :ok
  def upsert_blocked_decision(
        %{
          tenant_id: tenant_id,
          project_id: project_id,
          scope_key: scope_key,
          endpoint_host: host,
          reason: reason,
          window_start: window
        },
        count
      ) do
    now = DateTime.utc_now()

    AdminRepo.insert_all(
      BlockedDecision,
      [
        %{
          id: Ecto.UUID.generate(),
          tenant_id: tenant_id,
          project_id: project_id,
          scope_key: scope_key,
          endpoint_host: host,
          reason: reason,
          window_start: window,
          occurrence_count: count,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: [inc: [occurrence_count: count], set: [updated_at: now]],
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

    scopes = posture_scopes(tenant_id)

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

  # A CLEAR deletes the marking row, and a tenant that never enabled local_only has
  # none at all — so mapping over `list_markings/1` alone would report `scopes: []`
  # for the DEFAULT posture AC-41.4.1 protects, and an agent doing verify-before-
  # harvest could not tell "not marked" from "field not populated". The TENANT-scope
  # entry is therefore ALWAYS present (AC-41.4.8: per-scope local_only and
  # encrypt_body status), explicitly `false` when unmarked.
  defp posture_scopes(tenant_id) do
    rows = list_markings(tenant_id)

    entries = Enum.map(rows, &scope_posture_entry(&1.project_id, &1.local_only))

    if Enum.any?(rows, &is_nil(&1.project_id)) do
      entries
    else
      [scope_posture_entry(nil, false) | entries]
    end
  end

  defp scope_posture_entry(project_id, local_only) do
    %{
      scope: if(is_nil(project_id), do: "tenant", else: "project:#{project_id}"),
      project_id: project_id,
      local_only: local_only,
      # encrypt_body ships in US-41.6 (which depends on this story); the field
      # is reserved here so the posture contract does not change shape later.
      encrypt_body: false
    }
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
