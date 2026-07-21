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
  """

  require Logger

  alias Loopctl.Egress
  alias Loopctl.Egress.Allowlist
  alias Loopctl.Egress.PinCache
  alias Loopctl.Egress.Scope
  alias Loopctl.Net.UrlGuard

  @marking_key :__marking__

  @type verdict :: :network_local | :tenant_declared | :denylisted | :non_local
  @type purpose :: :inference | :webhook
  @type details :: %{
          required(:host) => String.t() | nil,
          required(:scope) => String.t(),
          required(:verdict) => verdict() | :unclassifiable,
          optional(:remediation) => String.t()
        }

  @doc """
  The egress decision for `url` on behalf of `scope`, for `purpose`.

  Returns:

    * `{:ok, :unpinned}` — the scope is not `local_only`; proceed exactly as
      before (no pin, no behaviour change — default-off preserved).
    * `{:ok, pinned}` — allowed; connect with
      `UrlGuard.pinned_request_opts(pinned, headers)` so the IP actually
      connected to is the IP that was classified (closes the resolve-then-connect
      / DNS-rebinding TOCTOU).
    * `{:error, :egress_blocked, details}` — refused BEFORE any request is built.
    * `{:error, :pin_stale, details}` — the host's address set changed; the
      remediation is a re-pin (`repin/3`), which needs NO role `:user` write.
  """
  @spec check(Scope.t(), String.t(), purpose()) ::
          {:ok, :unpinned}
          | {:ok, UrlGuard.pinned()}
          | {:error, :egress_blocked, details()}
          | {:error, :pin_stale, details()}
  def check(%Scope{} = scope, url, purpose) when is_binary(url) do
    do_check(scope, url, purpose)
  rescue
    e ->
      fail_closed(scope, url, "classifier raised: #{Exception.message(e)}")
  catch
    :exit, reason -> fail_closed(scope, url, "classifier exit: #{inspect(reason)}")
    :throw, value -> fail_closed(scope, url, "classifier throw: #{inspect(value)}")
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
    scope_key = Scope.key(scope)

    case PinCache.fetch(scope.tenant_id, scope_key, @marking_key) do
      {:ok, %{local_only: value}} ->
        value

      _ ->
        value = Egress.effective_local_only?(scope)
        PinCache.put(scope.tenant_id, scope_key, @marking_key, %{local_only: value})
        value
    end
  end

  # --- internals ---

  defp do_check(scope, url, purpose) do
    uri = URI.parse(url)

    case uri.host do
      host when is_binary(host) and host != "" ->
        check_host(scope, uri, host, purpose)

      _ ->
        {:error, :egress_blocked, details(scope, nil, :unclassifiable)}
    end
  end

  defp check_host(scope, uri, host, purpose) do
    if local_only?(scope) do
      check_local_only(scope, uri, host, purpose)
    else
      # Default-off: a scope that has not opted in behaves EXACTLY as before —
      # no pin, no classification cost, no new failure mode. AC-41.4.12.
      {:ok, :unpinned}
    end
  end

  defp check_local_only(scope, uri, host, purpose) do
    case cached_classification(scope, host, purpose) do
      {:ok, %{pin_stale: true}} ->
        {:error, :pin_stale,
         details(scope, host, :tenant_declared)
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
        # A declaration is honoured ONLY for its declared purposes. The cached
        # entry carries the declared purpose set, so the purpose check costs
        # nothing extra and can never become ambient across subsystems.
        {:ok, apply_purpose(entry, purpose)}

      :miss ->
        # Lazy initial population — no dependency on the US-41.2 probe.
        with {:ok, attrs} <- classify_uncached(scope, host, purpose) do
          {:ok, PinCache.put(scope.tenant_id, scope_key, host, attrs)}
        end
    end
  end

  defp apply_purpose(%{verdict: :tenant_declared, purposes: purposes} = entry, purpose) do
    if to_string(purpose) in purposes do
      entry
    else
      Map.put(entry, :verdict, :non_local)
    end
  end

  defp apply_purpose(entry, _purpose), do: entry

  defp classify_uncached(scope, host, purpose) do
    with {:ok, ips} <- UrlGuard.resolve_host(host) do
      cond do
        # (a) OPERATOR carve-out — the only thing that may reach a private range.
        Allowlist.host_allowed?(host) or Allowlist.ips_allowed?(ips) ->
          {:ok, %{verdict: :network_local, from_allowlist: true, ips: ips, purposes: []}}

        # Everything else must pass the FULL SSRF denylist first.
        not UrlGuard.public_addresses?(ips) ->
          {:ok, %{verdict: :denylisted, from_allowlist: false, ips: ips, purposes: []}}

        true ->
          {:ok, declared_verdict(scope, host, purpose, ips)}
      end
    end
  end

  defp declared_verdict(scope, host, purpose, ips) do
    case Egress.declared_purposes(scope.tenant_id, host) do
      [] ->
        %{verdict: :non_local, from_allowlist: false, ips: ips, purposes: []}

      purposes ->
        verdict = if to_string(purpose) in purposes, do: :tenant_declared, else: :non_local
        %{verdict: verdict, from_allowlist: false, ips: ips, purposes: purposes}
    end
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
