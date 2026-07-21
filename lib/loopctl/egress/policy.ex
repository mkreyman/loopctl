defmodule Loopctl.Egress.Policy do
  @moduledoc """
  The ONE egress policy for loopctl (US-41.4, AC-41.4.9).

  Every outbound path consults this module: the provider guard
  (`Loopctl.Provider`), the US-41.2 endpoint probe, ingestion, and — in US-41.5 —
  webhook delivery. It COMPOSES `Loopctl.Net.UrlGuard`'s SSRF denylist with the
  locality decision rather than restating either. A second, divergent URL policy
  anywhere in `lib/` is a review failure.

  ## Carve-out powers are split by plane

    * The **operator** deployment allowlist (`Loopctl.Egress.Allowlist`) is the
      ONLY thing that can carve hosts/CIDRs out of the denylist. It is
      deployment-scoped and unwritable at every role, including `:user`.
    * **Tenant declarations** (`Loopctl.Egress.TrustedEndpoint`) carve NOTHING
      out. They only change the LOCALITY VERDICT for hosts that ALREADY pass the
      denylist (public addresses), and only for their declared purposes.

  GHSA-jh42-wf7g-f5rg therefore stays closed for every tenant-writable input.

  ## Verdicts

    * `:network_local` — loopback/private-range host carved out by the operator
      deployment allowlist. Genuinely on the deployment's own network.
    * `:tenant_declared` — a PUBLIC host the tenant attests is their own, for the
      requested purpose. Labelled everywhere as
      **"tenant-declared (unverified attestation), not network-local"** — loopctl
      does not prove the declaring tenant owns the host, and this verdict must
      NEVER be presented as network-local.
    * `:denylisted` — a private/loopback/CGNAT/link-local/ULA address that is NOT
      in the operator allowlist. Unreachable; only the operator can carve it out.
    * `:non_local` — a public host with no declaration for this purpose.

  ## Failure semantics

  FAIL-CLOSED. If the endpoint cannot be classified, or the classification
  machinery itself raises/exits/throws, the call is REFUSED — never admitted.
  This is deliberately the OPPOSITE of `Loopctl.Provider.Admission`, which is a
  fail-OPEN burst shedder; the two decisions stay separate `with` clauses so a
  limiter hiccup can never silently degrade the privacy guarantee to "allow".

  Fail-closed is SCOPED (AC-41.4.12): a stale or missing pin refuses only for
  `local_only` scopes. A scope that is not `local_only` re-resolves normally and
  pins per request at connect time, preserving the default-off promise for every
  existing tenant on vendor endpoints.

  ## The MARKING lookup is resolved OUTSIDE the fail-closed classifier

  The `local_only` marking is what SELECTS the fail-closed regime, so it can never
  be resolved INSIDE it: a `DBConnection` blip on the 3-connection BYPASSRLS pool
  would otherwise raise inside the classifier rescue and produce
  `:egress_blocked` — a PERMANENT, job-cancelling refusal — for a scope that has
  no marking at all. `check/3` therefore resolves the marking first, with its own
  failure handling, and a marking lookup that fails yields the DISTINCT, TRANSIENT
  `{:error, :egress_unavailable, details}`, which every worker SNOOZES (never
  cancels). Fail-closed still applies: the call is refused, no data leaves — but
  a recoverable infrastructure hiccup can never masquerade as a permanent privacy
  refusal for a tenant that never opted in.
  """

  require Logger

  alias Loopctl.Egress
  alias Loopctl.Egress.Allowlist
  alias Loopctl.Egress.PinCache
  alias Loopctl.Egress.Scope
  alias Loopctl.Net.UrlGuard

  @marking_key :__marking__

  @type verdict :: :network_local | :tenant_declared | :denylisted | :non_local
  @typedoc """
  The purpose-independent part of a classification — the ONLY thing cached.

  The final verdict is DERIVED per read from `(base_verdict, purposes, purpose)`
  so a cached entry can never fix a host's verdict to whichever purpose happened
  to touch it first (AC-41.4.5 constraint 2 / AC-41.4.9).
  """
  @type base_verdict :: :network_local | :denylisted | :public
  @type purpose :: :inference | :webhook | :ingest
  @type details :: %{
          required(:host) => String.t() | nil,
          required(:scope) => String.t(),
          required(:verdict) => verdict() | :unclassifiable | :marking_unavailable,
          optional(:remediation) => String.t()
        }

  @doc """
  The egress decision for `url` on behalf of `scope`, for `purpose`.

  Returns:

    * `{:ok, pinned}` — allowed; connect with
      `UrlGuard.pinned_request_opts(pinned, headers)` so the IP actually
      connected to is the IP that was classified (closes the resolve-then-connect
      / DNS-rebinding TOCTOU). Non-`local_only` scopes ALSO get a per-request pin
      (AC-41.4.12) — the default-off promise is about the REFUSAL, not about
      dropping the pin.
    * `{:ok, :unpinned}` — the scope is not `local_only` AND the per-request pin
      could not be taken (unresolvable/denylisted host). The call proceeds exactly
      as before: a non-`local_only` scope must never acquire a NEW failure mode.
    * `{:error, :egress_blocked, details}` — refused BEFORE any request is built.
      PERMANENT: a configuration state that will not change on its own.
    * `{:error, :pin_stale, details}` — the host's address set changed; the
      remediation is a re-pin (`repin/3`), which needs NO role `:user` write.
      TRANSIENT.
    * `{:error, :egress_unavailable, details}` — the `local_only` MARKING itself
      could not be resolved (a DB/pool hiccup). Fail-closed for this call, but
      TRANSIENT: callers snooze, never cancel.
  """
  @spec check(Scope.t(), String.t(), purpose()) ::
          {:ok, :unpinned}
          | {:ok, UrlGuard.pinned()}
          | {:error, :egress_blocked, details()}
          | {:error, :pin_stale, details()}
          | {:error, :egress_unavailable, details()}
  def check(%Scope{} = scope, url, purpose) when is_binary(url) do
    # The MARKING selects the regime, so it is resolved OUTSIDE the fail-closed
    # classifier rescue: an infrastructure hiccup here is `:egress_unavailable`
    # (transient), never `:egress_blocked` (permanent) — see the moduledoc.
    case marking(scope) do
      {:ok, true} -> guarded_check(scope, url, purpose)
      {:ok, false} -> default_path(scope, url)
      {:error, reason} -> marking_unavailable(scope, url, reason)
    end
  end

  # Fail-CLOSED, and ONLY for `local_only` scopes.
  defp guarded_check(scope, url, purpose) do
    do_check(scope, url, purpose)
  rescue
    e ->
      fail_closed(scope, url, "classifier raised: #{Exception.message(e)}")
  catch
    :exit, reason -> fail_closed(scope, url, "classifier exit: #{inspect(reason)}")
    :throw, value -> fail_closed(scope, url, "classifier throw: #{inspect(value)}")
  end

  # AC-41.4.12: a non-`local_only` scope on a vendor default re-resolves normally
  # and PINS PER REQUEST at connect time. The pin is a TOCTOU control, not a
  # locality decision, so a pin that cannot be taken must NOT become a refusal —
  # that would hand every default tenant a brand-new failure mode. Fall back to
  # the pre-US-41.4 behaviour instead.
  defp default_path(scope, url) do
    case UrlGuard.pin(url) do
      {:ok, pinned} ->
        {:ok, pinned}

      {:error, reason} ->
        Logger.debug(
          "Loopctl.Egress.Policy: per-request pin unavailable for #{Scope.key(scope)} " <>
            "(#{inspect(reason)}); proceeding unpinned (scope is not local_only)"
        )

        {:ok, :unpinned}
    end
  rescue
    _e -> {:ok, :unpinned}
  catch
    :exit, _reason -> {:ok, :unpinned}
    :throw, _value -> {:ok, :unpinned}
  end

  defp marking_unavailable(scope, url, reason) do
    Logger.warning(
      "Loopctl.Egress.Policy: local_only marking unresolvable for #{Scope.key(scope)} " <>
        "(#{inspect(reason)}); refusing this call as TRANSIENT :egress_unavailable"
    )

    host = safe_host(url)

    {:error, :egress_unavailable,
     %{
       host: host,
       scope: Scope.key(scope),
       verdict: :marking_unavailable,
       remediation:
         "The local_only marking for this scope could not be read (transient " <>
           "infrastructure failure). Nothing was sent. Retry shortly — this is NOT a " <>
           "privacy refusal and needs no configuration change."
     }}
  end

  @doc """
  Classifies `host` for `scope`/`purpose` WITHOUT deciding admission — used by
  `Loopctl.Egress.posture/2` and by the `local_only` enable pre-flight.
  """
  @spec classify(Scope.t(), String.t(), purpose()) ::
          {:ok, %{verdict: verdict(), from_allowlist: boolean(), ips: [:inet.ip_address()]}}
          | {:error, term()}
  def classify(%Scope{} = scope, host, purpose) when is_binary(host) do
    case cached_classification(scope, host, purpose) do
      {:ok, entry} -> {:ok, Map.take(entry, [:verdict, :from_allowlist, :ips])}
      {:error, _} = err -> err
    end
  rescue
    e -> {:error, {:classifier_error, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:classifier_error, reason}}
    :throw, value -> {:error, {:classifier_error, value}}
  end

  @doc """
  Drops the cached pin for `(scope, host)` and re-classifies it immediately.

  This is the `:pin_stale` remediation. It is deliberately a CHEAP, non-`:user`
  operation: the target deployments (home Ollama box, tailscale funnel, DHCP VPS)
  change IP routinely, and requiring a human to re-run the role-`:user`
  `set_llm_config` to recover would contradict the epic's agent-native, no-UI
  design principle.
  """
  @spec repin(Scope.t(), String.t(), purpose()) :: {:ok, map()} | {:error, term()}
  def repin(%Scope{} = scope, host, purpose \\ :inference) do
    PinCache.delete(scope.tenant_id, Scope.key(scope), host)
    classify(scope, host, purpose)
  end

  @doc false
  # Called by the supervised refresher. Re-resolves an entry's host with the SAME
  # rules that produced it (allowlisted hosts bypass the denylist; everything else
  # must still be public).
  @spec reresolve(map()) :: {:ok, [:inet.ip_address()]} | {:error, term()}
  def reresolve(%{host: host, from_allowlist: from_allowlist}) when is_binary(host) do
    with {:ok, ips} <- UrlGuard.resolve_host(host) do
      cond do
        from_allowlist and Allowlist.ips_allowed?(ips) -> {:ok, ips}
        from_allowlist -> {:error, :no_longer_allowlisted}
        UrlGuard.public_addresses?(ips) -> {:ok, ips}
        true -> {:error, :blocked_ip}
      end
    end
  end

  def reresolve(_entry), do: {:error, :unclassifiable}

  @doc """
  The effective `local_only` marking for `scope` — the MOST RESTRICTIVE of the
  tenant and project markings (`project OR tenant`). Cached, so the hot path does
  no DB round-trip.
  """
  @spec local_only?(Scope.t()) :: boolean()
  def local_only?(%Scope{} = scope) do
    match?({:ok, true}, marking(scope))
  end

  # --- internals ---

  # The marking lookup, with its OWN failure handling. Never called from inside
  # the fail-closed classifier rescue.
  defp marking(%Scope{} = scope) do
    scope_key = Scope.key(scope)

    case PinCache.fetch(scope.tenant_id, scope_key, @marking_key) do
      {:ok, %{local_only: value}} ->
        {:ok, value}

      _ ->
        value = Egress.effective_local_only?(scope)
        PinCache.put(scope.tenant_id, scope_key, @marking_key, %{local_only: value})
        {:ok, value}
    end
  rescue
    e -> {:error, {:marking_error, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:marking_exit, reason}}
    :throw, value -> {:error, {:marking_throw, value}}
  end

  defp do_check(scope, url, purpose) do
    uri = URI.parse(url)

    case uri.host do
      host when is_binary(host) and host != "" ->
        check_local_only(scope, uri, host, purpose)

      _ ->
        {:error, :egress_blocked, details(scope, nil, :unclassifiable)}
    end
  end

  defp check_local_only(scope, uri, host, purpose) do
    case cached_classification(scope, host, purpose) do
      # `:pin_stale` is reachable ONLY for an entry that would otherwise be
      # ALLOWED. A denylisted/non-local entry that merely failed revalidation is
      # still a REFUSAL, reported with its REAL verdict — reporting the transient
      # `:pin_stale` (with a re-pin remediation that can never help) would both
      # mislabel a permanently unreachable endpoint and silently stop the
      # AC-41.4.6 blocked telemetry/audit trail for a still-blocked tenant.
      {:ok, %{verdict: verdict, pin_stale: true}}
      when verdict in [:network_local, :tenant_declared] ->
        {:error, :pin_stale,
         details(scope, host, verdict)
         |> Map.put(
           :remediation,
           "The pinned address set for #{host} changed. Re-pin it (no role :user write " <>
             "required) via the egress repin operation, then retry."
         )}

      {:ok, %{verdict: verdict, ips: [ip | _]}}
      when verdict in [:network_local, :tenant_declared] ->
        {:ok, %{uri: uri, host: host, ip: ip}}

      {:ok, %{verdict: verdict}} ->
        {:error, :egress_blocked, details(scope, host, verdict)}

      {:error, _reason} ->
        {:error, :egress_blocked, details(scope, host, :unclassifiable)}
    end
  end

  defp cached_classification(scope, host, purpose) do
    scope_key = Scope.key(scope)

    case PinCache.fetch(scope.tenant_id, scope_key, host) do
      {:ok, entry} ->
        {:ok, resolve_verdict(entry, purpose)}

      :miss ->
        # Lazy initial population — no dependency on the US-41.2 probe.
        with {:ok, attrs} <- classify_uncached(scope, host) do
          {:ok, resolve_verdict(PinCache.put(scope.tenant_id, scope_key, host, attrs), purpose)}
        end
    end
  end

  @doc """
  Derives the purpose-SCOPED verdict from a cached entry.

  The cache stores only purpose-INDEPENDENT facts (`base_verdict`, `ips`,
  `from_allowlist`, the host's declared `purposes`). Collapsing the purpose into
  a cached verdict would let the FIRST purpose to touch a host fix its verdict
  for the whole TTL — an inference endpoint declared for `["inference"]` but
  first classified under `:webhook` would then be refused for legitimate
  inference calls. AC-41.4.5 constraint (2) makes purpose scoping a security
  invariant, so it is re-derived on EVERY read.
  """
  @spec resolve_verdict(map(), purpose()) :: map()
  def resolve_verdict(entry, purpose) do
    Map.put(entry, :verdict, verdict_for(entry, purpose))
  end

  defp verdict_for(%{base_verdict: :network_local}, _purpose), do: :network_local
  defp verdict_for(%{base_verdict: :denylisted}, _purpose), do: :denylisted

  defp verdict_for(%{base_verdict: :public, purposes: purposes}, purpose) do
    if to_string(purpose) in purposes, do: :tenant_declared, else: :non_local
  end

  defp verdict_for(_entry, _purpose), do: :non_local

  defp classify_uncached(scope, host) do
    with {:ok, ips} <- UrlGuard.resolve_host(host) do
      cond do
        # (a) OPERATOR carve-out — the only thing that may reach a private range.
        Allowlist.host_allowed?(host) or Allowlist.ips_allowed?(ips) ->
          {:ok, %{base_verdict: :network_local, from_allowlist: true, ips: ips, purposes: []}}

        # Everything else must pass the FULL SSRF denylist first.
        not UrlGuard.public_addresses?(ips) ->
          {:ok, %{base_verdict: :denylisted, from_allowlist: false, ips: ips, purposes: []}}

        true ->
          {:ok,
           %{
             base_verdict: :public,
             from_allowlist: false,
             ips: ips,
             purposes: Egress.declared_purposes(scope.tenant_id, host)
           }}
      end
    end
  end

  defp safe_host(url) do
    URI.parse(url).host
  rescue
    _ -> nil
  end

  defp fail_closed(scope, url, detail) do
    Logger.warning("Loopctl.Egress.Policy: failing CLOSED for #{Scope.key(scope)}: #{detail}")
    host = URI.parse(url).host
    {:error, :egress_blocked, details(scope, host, :unclassifiable)}
  end

  defp details(scope, host, verdict) do
    %{host: host, scope: Scope.key(scope), verdict: verdict}
    |> Map.put(:remediation, remediation_for(verdict, host))
  end

  defp remediation_for(:unclassifiable, host) do
    "The endpoint #{inspect(host)} could not be classified as local, so the call was " <>
      "refused (fail-closed). Verify the endpoint host resolves, then re-check with the " <>
      "egress_posture tool."
  end

  defp remediation_for(:denylisted, host) do
    "#{host} resolves into a private, loopback, CGNAT, link-local or ULA range. Only the " <>
      "OPERATOR deployment allowlist can carve such a host out of the SSRF denylist — a " <>
      "tenant declaration cannot. Ask the operator to allowlist it, or use a public host."
  end

  defp remediation_for(_verdict, host) do
    "#{host} is not local for this scope. Either declare it as a tenant-trusted endpoint " <>
      "for the required purpose (role :user, and note that a declaration is a " <>
      "tenant-declared (unverified attestation), not network-local), configure a local " <>
      "endpoint AT TENANT level (role :user), or clear the local_only marking (role :user)."
  end
end
