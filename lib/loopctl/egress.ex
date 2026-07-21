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
  classifies the scope's currently-resolved embedding and chat endpoints FIRST —
  and, since US-41.5 (AC-41.5.4), every WEBHOOK SUBSCRIPTION the marking would
  cover (`blocked_webhook_subscriptions/1`). Subscriptions are never silently
  disabled: they are either the reason for the refusal, or reported back.
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
  alias Loopctl.Llm
  # Webhook rows are read through the OWNING context's narrow reader
  # (`Webhooks.list_for_egress/3`), never queried here: the tenant-scoping
  # predicate for webhooks must live in exactly one place (US-41.5 review).
  alias Loopctl.Webhooks

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
    do_enable(Scope.new(tenant_id, project_id), opts)
  end

  # `pg_advisory_xact_lock` takes two int4s. The NAMESPACE isolates this lock
  # class from every other advisory lock in the app (the memory quota, the
  # Context Retriever entity cap) so hashing a tenant here can never collide with
  # an unrelated lock keyed on the same integer.
  @scope_marking_lock_ns 0x4105_0001

  @doc """
  Serializes everything that reads-then-writes a tenant's egress configuration
  (review fix), inside the caller's transaction.

  `enable_local_only/3` decides on a SNAPSHOT of the tenant's webhook
  subscriptions (the pre-flight) and then writes the marking. Concurrently,
  `Loopctl.Webhooks.create_webhook/3` decides on a snapshot of the MARKINGS (the
  AC-41.5.3 config-time check) and then writes a subscription. Interleaved
  without a lock, a subscription created after the pre-flight snapshot lands
  under the new marking: it is absent from the `{:would_block, endpoints}` list,
  absent from `acknowledged_blocked_endpoints`, and silently blocked at delivery
  — the "silent state change" AC-41.5.4 rules out.

  Both writers take THIS lock as the FIRST step of their transaction and both run
  their check INSIDE it, so one of the two always observes the other's committed
  state. It is transaction-scoped, so it releases on commit/rollback with no
  unlock path to forget.

  The key is derived from the tenant UUID's first four bytes rather than
  `:erlang.phash2/1`, whose hashing is not guaranteed stable across OTP releases
  — during a rolling deploy two nodes must agree on the key or they do not
  serialize at all.
  """
  @spec lock_scope_config!(Ecto.Repo.t(), Ecto.UUID.t()) :: :ok
  def lock_scope_config!(repo, tenant_id) do
    repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
      @scope_marking_lock_ns,
      tenant_lock_key(tenant_id)
    ])

    :ok
  end

  @doc """
  The STABLE signed int4 advisory-lock key for a tenant. Public so a test can
  prove two real DB sessions derive the same key.
  """
  @spec tenant_lock_key(Ecto.UUID.t()) :: integer()
  def tenant_lock_key(tenant_id) do
    {:ok, <<key::signed-integer-32, _rest::binary>>} = Ecto.UUID.dump(tenant_id)
    key
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

  # The pre-flight runs INSIDE the transaction, under `lock_scope_config!/2` —
  # see that function for the race it closes. The cost is that a webhook
  # classification (worst case a DNS resolve) happens while an `AdminRepo`
  # connection is held; `classify_within_budget/3`'s deadline is what keeps that
  # hold bounded, and enabling `local_only` is a rare operator write.
  defp do_enable(%Scope{tenant_id: tenant_id, project_id: project_id} = scope, opts) do
    acknowledge = Keyword.get(opts, :acknowledge, false)
    now = DateTime.utc_now()

    Multi.new()
    |> Multi.run(:lock, fn repo, _changes ->
      {:ok, lock_scope_config!(repo, tenant_id)}
    end)
    |> Multi.run(:preflight, fn _repo, _changes ->
      blocked = preflight_blocked_endpoints(scope)

      if blocked != [] and not acknowledge do
        {:error, {:would_block, blocked}}
      else
        {:ok, blocked}
      end
    end)
    |> Multi.insert_or_update(:marking, fn %{preflight: blocked} ->
      attrs = %{
        project_id: project_id,
        local_only: true,
        enabled_by_actor_type: Keyword.get(opts, :actor_type, "api_key"),
        enabled_by_actor_id: Keyword.get(opts, :actor_id),
        enabled_at: now,
        acknowledged_blocked_endpoints: Enum.map(blocked, & &1.endpoint)
      }

      (get_marking(tenant_id, project_id) || %ScopeMarking{tenant_id: tenant_id})
      |> ScopeMarking.changeset(attrs)
    end)
    |> Audit.log_in_multi(:audit, fn %{preflight: blocked} ->
      audit_attrs(tenant_id, scope, "egress.local_only_enabled", opts, %{
        local_only: true,
        blocked_endpoints: Enum.map(blocked, & &1.endpoint),
        acknowledged: acknowledge
      })
    end)
    |> AdminRepo.transaction()
    |> case do
      {:ok, %{marking: marking, preflight: blocked}} ->
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

      # The pre-flight now REFUSES from inside the transaction, so its verdict
      # arrives as a Multi failure. Unwrap it to the same `{:error,
      # {:would_block, endpoints}}` the caller contract already documents —
      # nothing was written, because the whole Multi rolled back.
      {:error, :preflight, {:would_block, blocked}, _} ->
        {:error, {:would_block, blocked}}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  # The pre-flight. Endpoint resolution is TENANT-scoped only, so this classifies
  # the tenant's currently-resolved embedding + chat endpoints for the scope, PLUS
  # (US-41.5, AC-41.5.4) every webhook subscription the marking would cover.
  defp preflight_blocked_endpoints(%Scope{} = scope) do
    provider =
      scope
      |> resolved_endpoints()
      |> Enum.map(fn {kind, url} -> {kind, url, endpoint_verdict(scope, url, :inference)} end)
      |> Enum.reject(fn {_kind, _url, verdict} -> local_verdict?(verdict) end)
      |> Enum.map(fn {kind, url, verdict} ->
        %{kind: kind, endpoint: url, verdict: to_string(verdict)}
      end)

    provider ++ blocked_webhook_subscriptions(scope)
  end

  @doc """
  The webhook subscriptions a `local_only` marking on `scope` would REFUSE
  (US-41.5, AC-41.5.4).

  Feeds `enable_local_only/3`'s pre-flight, so enabling `local_only` while an
  incompatible subscription exists is REFUSED with `{:error, {:would_block,
  endpoints}}` naming each one — never a silent state change. Passing
  `acknowledge: true` completes the enable and REPORTS them. That is the
  DOCUMENTED choice (see `docs/egress-guard.md`): refuse by default, proceed only
  on an explicit acknowledgement.

  Coverage follows the marking, not the delivery scope: a TENANT-scope marking
  (`project_id: nil`) covers every subscription, while a PROJECT-scope marking
  covers only that project's subscriptions — a project marking cannot block a
  tenant-wide (project-less) subscription, whose delivery scope it does not
  narrow (AC-41.4.2, most-restrictive-wins).

  INACTIVE subscriptions are included deliberately. They are not broken today,
  but re-activating one under an unchanged marking would silently produce a
  blocked destination, and "surfaced explicitly" is the whole point of the
  pre-flight. Each entry carries `active` so a caller can weight them.
  """
  @spec blocked_webhook_subscriptions(Scope.t()) :: [map()]
  def blocked_webhook_subscriptions(%Scope{tenant_id: tenant_id, project_id: project_id}) do
    tenant_id
    |> Webhooks.list_for_egress(project_id || :all, limit: max_classified_webhooks())
    |> classify_within_budget(fn webhook ->
      delivery_scope = Scope.new(tenant_id, webhook.project_id)
      endpoint_verdict(delivery_scope, webhook.url, :webhook)
    end)
    |> Enum.reject(fn {_webhook, verdict} -> local_verdict?(verdict) end)
    |> Enum.map(fn {webhook, verdict} ->
      %{
        kind: :webhook,
        endpoint: webhook.url,
        verdict: to_string(verdict),
        webhook_id: webhook.id,
        project_id: webhook.project_id,
        active: webhook.active
      }
    end)
  end

  @doc """
  Redacts the pre-flight's blocked-endpoint list for `role` (review fix).

  `blocked_webhook_subscriptions/1` carries the FULL destination URL because
  `enable_local_only/3` records it in the marking's
  `acknowledged_blocked_endpoints` and in the audit event — server-side state a
  `:user` reads back. But the pre-flight's list is also echoed to the CALLER, and
  `POST /api/v1/egress/local-only` is `role: :orchestrator`, one level below the
  `role: :user` gate on `LoopctlWeb.WebhookController`. Echoing it verbatim would
  disclose webhook destination URLs — frequently capability URLs whose path IS the
  credential (Slack, Discord, Teams, Zapier, n8n) — a role below the one that can
  read them anywhere else.

  So below `:user` a `:webhook` entry's `endpoint` is reduced to its HOST, which
  is all an orchestrator needs to act on the conflict (it also carries
  `webhook_id`). PROVIDER endpoints are left intact: they are operator/tenant
  configuration already disclosed at `:agent` by `posture/2`.
  """
  @spec redact_blocked_endpoints([map()], atom()) :: [map()]
  def redact_blocked_endpoints(blocked, role) when is_list(blocked) do
    if role in [:user, :superadmin] do
      blocked
    else
      Enum.map(blocked, &redact_blocked_endpoint/1)
    end
  end

  defp redact_blocked_endpoint(%{kind: :webhook, endpoint: url} = entry) when is_binary(url) do
    %{entry | endpoint: URI.parse(url).host || url}
  end

  defp redact_blocked_endpoint(entry), do: entry

  @doc """
  Rows an egress caller will classify for one tenant, and the wall-clock budget
  it will spend doing so (US-41.5 review).

  Both the posture report (role `:agent`) and the `local_only` enable pre-flight
  classify TENANT-SUPPLIED webhook hosts, and a classification that misses the
  `PinCache` pays a real DNS resolve (`UrlGuard`'s 3s timeout). Unbounded, a
  tenant could make the endpoint agents are told to call BEFORE EVERY HARVEST
  take `max_webhooks x 3s` — with `max_webhooks` itself tenant-settable.

  So the work is bounded twice: at most `max_classified_webhooks/0` rows, and
  once the budget is spent the remaining rows are reported `unclassified`
  (cache-only, no resolve) rather than blocking the request. `unclassified` is
  NOT a local verdict, so a budget-exhausted destination is reported as blocked
  by the pre-flight — bounded the FAIL-CLOSED way.

  Deliberately serial rather than `Task.async_stream/3`: the classifier reads the
  DB (declared purposes) inside the caller's `Ecto` sandbox/RLS context, and this
  bound must hold identically in a request, a worker and a test.
  """
  @spec classification_budget_ms() :: pos_integer()
  def classification_budget_ms do
    Application.get_env(:loopctl, :egress_classification_budget_ms, 2_000)
  end

  @doc "Maximum webhook rows one egress classification pass will look at."
  @spec max_classified_webhooks() :: pos_integer()
  def max_classified_webhooks do
    Application.get_env(:loopctl, :egress_max_classified_webhooks, 50)
  end

  # Classifies `items` in order until the budget is spent; the rest get `skipped`.
  # The FIRST item is always classified, so a single destination behaves exactly
  # as it did before the bound.
  defp classify_within_budget(items, classify_fun, skipped \\ :unclassified) do
    deadline = System.monotonic_time(:millisecond) + classification_budget_ms()

    items
    |> Enum.with_index()
    |> Enum.map(fn {item, index} ->
      if index == 0 or System.monotonic_time(:millisecond) < deadline do
        {item, classify_fun.(item)}
      else
        {item, skipped}
      end
    end)
  end

  @doc """
  True when `verdict` means "local for this scope" — the ONE definition of
  deliverable/admissible locality, shared by the guard, the pre-flight, the
  config-time check and the posture report so they cannot drift.
  """
  @spec local_verdict?(atom()) :: boolean()
  def local_verdict?(verdict), do: verdict in [:network_local, :tenant_declared]

  @doc """
  The locality verdict for a destination `url` under `scope` and `purpose`.

  Purpose scoping is a SECURITY INVARIANT (AC-41.4.5 constraint 2): a host
  declared for an Ollama inference box does NOT authorize POSTing tenant content
  to it, so webhook callers must pass `:webhook`.
  """
  @spec endpoint_verdict(Scope.t(), String.t(), Policy.purpose()) :: atom()
  def endpoint_verdict(%Scope{} = scope, url, purpose) do
    host = URI.parse(url).host || url

    case Policy.classify(scope, host, purpose) do
      {:ok, %{verdict: verdict}} -> verdict
      {:error, _} -> :unclassifiable
    end
  end

  @doc """
  The CONFIG-TIME verdict for a webhook destination (US-41.5, AC-41.5.3).

  Returns `:ok` when the subscription may be created/updated, or
  `{:error, {verdict, message}}` with a legible remediation naming the conflict.

  TWO refusals, in the same order the delivery path applies them:

    1. `:denylisted` — the destination resolves into a private/loopback/CGNAT/
      link-local/ULA range and the OPERATOR deployment allowlist does not carve
      it out. Refused for EVERY scope, marked or not (ie-02 /
      GHSA-jh42-wf7g-f5rg). This decision moved here from
      `Loopctl.Webhooks.Webhook.validate_url/1`, which could not see the tenant
      and therefore refused every allowlisted destination too.
    2. `:unclassifiable` — the host does not resolve. Reported DISTINCTLY from a
      private address: "does not exist" and "exists but is forbidden" are
      different problems with different fixes.
    3. locality — the scope is `local_only` and the destination is not local for
      the `webhook` purpose.

  This is the ONLY DNS resolution performed for a webhook write: the changeset
  above it validates SHAPE only.
  """
  @spec webhook_destination_check(Scope.t(), String.t()) ::
          :ok | {:error, {atom(), String.t()}}
  def webhook_destination_check(%Scope{} = scope, url) when is_binary(url) do
    case endpoint_verdict(scope, url, :webhook) do
      :denylisted ->
        {:error, {:denylisted, denylisted_message(url)}}

      :unclassifiable ->
        {:error, {:unclassifiable, "host could not be resolved"}}

      verdict ->
        cond do
          local_verdict?(verdict) ->
            :ok

          effective_local_only?(scope) ->
            {:error, {verdict, webhook_remediation(scope, url, verdict)}}

          true ->
            :ok
        end
    end
  end

  # The legacy phrase is preserved as the PREFIX so existing API consumers that
  # string-match it keep working; the remediation names WHO can change it, which
  # a bare "must not target a private or loopback address" never did.
  defp denylisted_message(url) do
    host = URI.parse(url).host || url

    "must not target a private or loopback address — #{host} resolves into a private, " <>
      "loopback, CGNAT, link-local or ULA range. Only the OPERATOR deployment allowlist " <>
      "can carve such a host out of the SSRF denylist; a tenant declaration cannot."
  end

  defp webhook_remediation(scope, url, verdict) do
    host = URI.parse(url).host || url

    "#{host} is #{verdict_label(verdict)} for #{Scope.key(scope)}, which is marked " <>
      "local_only. A subscription to it would be refused at delivery time, so it is " <>
      "rejected here instead. Either declare #{host} as a tenant-trusted endpoint FOR " <>
      "THE 'webhook' PURPOSE (role :user — note a declaration is #{@tenant_declared_label}), " <>
      "ask the operator to add it to the deployment allowlist if it is genuinely on the " <>
      "deployment network, use a destination that is already local, or clear the " <>
      "local_only marking on this scope (role :user)."
  end

  @doc """
  The endpoints currently resolved for a scope, as `{kind, url}` pairs.

  Endpoint resolution is TENANT-SCOPED ONLY (AC-41.4.2) — there is no
  project-level endpoint override anywhere in loopctl. Today these are the
  hardcoded vendor defaults / the configured embedding provider; US-41.2 makes
  them configurable and this function is the single place that changes.

  Both URLs are read from the module that RESOLVES them — `EmbeddingClient.base_url/0`
  and, since US-41.3, `Loopctl.Llm.chat_base_url/1` (which returns the tenant's
  configured OpenAI-compatible endpoint, or `Anthropic.base_url/0` when the tenant
  configured nothing) — never re-derived here. Re-deriving them would make the
  posture report and the pre-flight vet a DUPLICATED CONSTANT that agrees with the
  guard only by coincidence: exactly the "second, divergent URL policy" AC-41.4.9
  calls a review failure.
  """
  @spec resolved_endpoints(Scope.t()) :: [{atom(), String.t()}]
  def resolved_endpoints(%Scope{tenant_id: tenant_id}) do
    [{:embedding, EmbeddingClient.base_url()}, {:chat, Llm.chat_base_url(tenant_id)}]
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
    # Route the lookup through the SAME normalization the declaration was stored
    # with (trim + downcase + scheme/port/trailing-slash strip). A plain downcase
    # here would 404 on every declaration written as "https://ollama.example.com/"
    # or "ollama.example.com:11434" while the row kept changing the locality
    # verdict — and AC-41.4.12 makes immediate revocation the invalidation guarantee.
    normalized = TrustedEndpoint.normalize_host(host)

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
  WHICH of the two block causes a PERMANENT refusal is (US-41.5).

    * `:ssrf_denied` — the destination resolves into a private/loopback/CGNAT/
      link-local/ULA range and the OPERATOR deployment allowlist does not carve it
      out. Unreachable for EVERY tenant, marked or not; a tenant declaration
      cannot change it.
    * `:locality_denied` — the destination is reachable, but the scope is
      `local_only` and the destination is not classified local for the requested
      purpose. A configuration conflict the TENANT can resolve.
    * `:transient` — `:pin_stale` / `:egress_unavailable`, AND an
      `:egress_blocked` whose verdict is `:unclassifiable` for a real host
      (review fix, below); not a block at all.
    * `:unrecognized` — the term is not an egress refusal at all. TERMINAL, and
      deliberately so: this module's whole purpose is fail-closed classification,
      so an unknown term must not be silently routed onto the retry path. A
      malformed `{:refused, term}` from a future delivery-client change, a Mox
      stub, or a third-party `DeliveryBehaviour` implementation therefore stops
      loudly (a recorded, agent-readable block) instead of producing a job that
      snoozes forever. This matches `oban_result/1`, which already cancels an
      unrecognised term rather than snoozing it.

  An operator reading a blocked delivery needs the distinction: one is "ask the
  operator", the other is "declare the endpoint or clear the marking".

  ## `:unclassifiable` is TRANSIENT, not `:locality_denied` (review fix)

  `Policy.check_local_only/4` maps EVERY classification error — including a plain
  NXDOMAIN or a 3s resolver timeout — to `{:egress_blocked, %{verdict:
  :unclassifiable}}`. Fail-closed is right; calling it PERMANENT was not. It made
  the same resolver hiccup asymmetric by marking: on an UNMARKED scope the
  identical failure is `:egress_unavailable` and retried, while on a `local_only`
  scope it terminally dropped the delivery — and labelled it `locality_denied`,
  whose documented remediation ("declare the endpoint, or clear the marking")
  cannot fix a DNS outage on an already-declared endpoint. `enable_local_only/3`
  and `clear_local_only/3` both call `PinCache.invalidate_tenant/1`, so a cold
  cache right after a marking change is the EXPECTED state, not an edge case.

  It is transient only for a REAL host: `{:egress_blocked, %{verdict:
  :unclassifiable, host: nil}}` is a URL with no host at all (a malformed
  destination), which no amount of retrying fixes, so that stays permanent. The
  retry it enables is bounded by
  `Loopctl.Workers.WebhookDeliveryWorker.max_transient_snoozes/0`, after which the
  ordinary failure ladder still exhausts and still auto-disables.
  """
  @spec block_kind({atom(), map()} | atom()) ::
          :ssrf_denied | :locality_denied | :transient | :unrecognized
  def block_kind(term) do
    case refusal(term) do
      {:egress_blocked, %{verdict: :denylisted}} ->
        :ssrf_denied

      {:egress_blocked, %{verdict: :unclassifiable, host: host}} when is_binary(host) ->
        :transient

      {:egress_blocked, _details} ->
        :locality_denied

      {tag, _details} when tag in [:pin_stale, :egress_unavailable] ->
        :transient

      nil ->
        :unrecognized
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

  ## Deliberately COARSER than `block_kind/1`

  `block_kind/1` treats an `:egress_blocked` carrying `verdict: :unclassifiable`
  for a real host as TRANSIENT (a resolver failure is not a locality decision).
  This function does NOT, and the divergence is intentional rather than an
  oversight: `oban_result/1`'s callers hand the result straight to Oban with no
  snooze budget of their own, so snoozing an `:unclassifiable` would recreate
  exactly the immortal-job defect the webhook worker's
  `max_transient_snoozes/0` bound exists to prevent. `WebhookDeliveryWorker` uses
  `block_kind/1` precisely BECAUSE it carries that bound.

  A caller that wants the finer distinction must adopt a bound first.
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

  @doc false
  # The start of the current aggregation window. Public so
  # `Loopctl.Egress.BlockedBuffer` prunes its per-window cardinality bookkeeping on
  # exactly the same boundary the rows are keyed by.
  @spec current_window() :: DateTime.t()
  def current_window do
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

  The same split applies to WEBHOOK DESTINATIONS: `host`, `verdict` and
  `blocked_by_local_only` at every role; the FULL `endpoint` URL (path and query
  included — often a capability credential) only at `:user`+, matching the
  `role: :user` gate on `LoopctlWeb.WebhookController`.

  ## Scope of the guarantee

  Every CONTENT-CARRYING outbound path made by loopctl application code is
  covered: the model-provider path (US-41.4), the ingestion fetch, and — since
  US-41.5 — webhook delivery, reported per destination in `webhook_destinations`.
  What is still NOT covered is stated rather than implied: HTTP performed inside
  a dependency and the separate `mcp-server/` codebase are outside the static
  chokepoint scan, and the remaining non-content outbound paths are triaged in
  `docs/egress-guard.md`.
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
      webhook_destinations: webhook_destinations(tenant_id, role),
      declared_endpoints: declared,
      scopes: scopes,
      posture_defects: posture_defects(scopes),
      guarantee_scope:
        "Enforced for every outbound HTTP call made by loopctl application code on the " <>
          "content-carrying paths: MODEL-PROVIDER calls, the ingestion fetch, and WEBHOOK " <>
          "DELIVERY (per-destination classification in webhook_destinations). HTTP " <>
          "performed inside a dependency, and the separate mcp-server/ codebase, are " <>
          "outside the static chokepoint check; the remaining non-content outbound paths " <>
          "are triaged in docs/egress-guard.md.",
      tenant_declared_label: @tenant_declared_label
    }

    if role in [:user, :superadmin] do
      base
      |> Map.put(:deployment_allowlist, Allowlist.raw_entries())
      # Entries the operator believes are carve-outs and that parse as neither a
      # host nor a CIDR grant NOTHING. Operator-plane detail, so `:user`+ only.
      |> Map.put(:deployment_allowlist_defects, Allowlist.defects())
    else
      base
    end
  end

  @doc """
  The RESOLVED posture for ONE content-touching operation, as recorded by
  US-41.7's custody claim (AC-41.7.1).

  Deliberately derived from the SAME functions the guard itself uses —
  `resolved_endpoints/1` for the endpoints, `Policy.classify/3` for the verdict,
  `effective_local_only?/1` for the marking — so the recorded fact and the
  enforced decision cannot drift. Re-deriving any of them here would be the
  "second, divergent URL policy" AC-41.4.9 calls a review failure.

  This is a POINT-IN-TIME capture: the caller persists it immutably, and a later
  settings change must not alter what it says (AC-41.7.3).
  """
  @spec operation_posture(Scope.t()) :: map()
  def operation_posture(%Scope{} = scope) do
    endpoints =
      scope
      |> resolved_endpoints()
      |> Enum.map(fn {kind, url} ->
        {verdict, from_allowlist} = classify_endpoint(scope, url, :inference)

        %{
          kind: to_string(kind),
          endpoint: url,
          host: URI.parse(url).host || url,
          verdict: verdict_label(verdict),
          local: local_verdict?(verdict),
          verdict_from_deployment_allowlist: from_allowlist
        }
      end)

    %{
      scope: Scope.key(scope),
      local_only: effective_local_only?(scope),
      # `encrypt_body` ships in US-41.6 (which depends on this story); recorded
      # here from the start so the claim's shape does not change later.
      encrypt_body: false,
      endpoints: endpoints,
      local_endpoints_only: endpoints != [] and Enum.all?(endpoints, & &1.local)
    }
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
    {verdict, from_allowlist} = classify_endpoint(scope, url, :inference)
    host = URI.parse(url).host || url

    %{
      kind: kind,
      endpoint: url,
      host: host,
      verdict: verdict_label(verdict),
      # Boolean only at :agent — the allowlist CONTENTS are operator-plane state.
      verdict_from_deployment_allowlist: from_allowlist
    }
  end

  # AC-41.5.5: the posture report covers EVERY content-carrying egress path, so a
  # webhook destination is classified here exactly the way delivery classifies it
  # — same policy module, same `:webhook` purpose, same DELIVERY scope
  # (`tenant_id, webhook.project_id`). Anything else would let the report and the
  # guard disagree, which is the failure mode the whole report exists to prevent.
  #
  # DISCLOSURE (review fix): the full destination URL is `:user`+ only.
  #
  # A webhook destination is frequently a CAPABILITY URL whose PATH is the
  # credential (Slack `hooks.slack.com/services/T.../B.../<token>`, Discord,
  # Teams, Zapier, n8n). `LoopctlWeb.WebhookController` is `role: :user` at module
  # level, so an `:agent` key cannot read those URLs anywhere else — emitting them
  # here would be a role DOWNGRADE of existing data. AC-41.5.5 asks for "webhook
  # destinations and their local classification", which `host` + `verdict` +
  # `blocked_by_local_only` satisfies; `endpoint` is added at `:user`+, the same
  # boolean-vs-contents split the deployment allowlist already uses.
  defp webhook_destinations(tenant_id, role) do
    tenant_id
    |> Webhooks.list_for_egress(:all, limit: max_classified_webhooks())
    |> classify_within_budget(
      fn webhook ->
        classify_endpoint(Scope.new(tenant_id, webhook.project_id), webhook.url, :webhook)
      end,
      {:unclassified, false}
    )
    |> Enum.map(fn {webhook, {verdict, from_allowlist}} ->
      scope = Scope.new(tenant_id, webhook.project_id)
      host = URI.parse(webhook.url).host || webhook.url

      base = %{
        webhook_id: webhook.id,
        project_id: webhook.project_id,
        scope: Scope.key(scope),
        host: host,
        active: webhook.active,
        verdict: verdict_label(verdict),
        verdict_from_deployment_allowlist: from_allowlist,
        blocked_by_local_only: Policy.local_only?(scope) and not local_verdict?(verdict)
      }

      if role in [:user, :superadmin] do
        Map.put(base, :endpoint, webhook.url)
      else
        base
      end
    end)
  end

  defp classify_endpoint(scope, url, purpose) do
    host = URI.parse(url).host || url

    case Policy.classify(scope, host, purpose) do
      {:ok, %{verdict: v, from_allowlist: a}} -> {v, a}
      {:error, _} -> {:unclassifiable, false}
    end
  end

  @doc """
  The human-readable label for a locality verdict.

  Public because US-41.7's custody claim records the SAME label the posture
  report shows — re-deriving it there would be a second, drifting vocabulary for
  the one policy's decisions.
  """
  @spec verdict_label(atom()) :: String.t()
  def verdict_label(:network_local), do: "network-local"
  def verdict_label(:tenant_declared), do: @tenant_declared_label
  def verdict_label(:denylisted), do: "non-local (blocked by the SSRF denylist)"
  def verdict_label(:non_local), do: "non-local"
  def verdict_label(other), do: to_string(other)

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
