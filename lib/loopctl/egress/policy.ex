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

  BOTH carve-out mechanisms are PURPOSE-SCOPED, and neither may be read as a
  blanket grant. A carve-out earned for one purpose does not answer for another:
  `inference` reaches an endpoint the DEPLOYMENT resolves, while `webhook` and
  `ingest` reach a destination a TENANT writes, so an inference carve-out that
  also authorized webhook POSTs would extend the operator's private network to
  tenant-chosen destinations. `verdict_for/3` therefore re-derives BOTH the
  allowlist grant and the tenant declaration against the requested purpose (and,
  for the allowlist, the requested PORT) on every read — see
  `Loopctl.Egress.Allowlist` for the entry grammar that expresses them.

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

  # Schemes a connection can be pinned for. Mirrors `UrlGuard`'s default scheme
  # allowlist — anything else proceeds unpinned on the default path.
  @pinnable_schemes ~w(http https)

  # A marking read that loses the invalidation race is retried at most this many
  # times before the (uncached) freshly-computed value is used for THIS call.
  @marking_attempts 2

  @type verdict :: :network_local | :tenant_declared | :denylisted | :non_local
  @typedoc """
  The purpose-independent part of a classification — the ONLY thing cached.

  The final verdict is DERIVED per read from `(base_verdict, purposes, purpose)`
  so a cached entry can never fix a host's verdict to whichever purpose happened
  to touch it first (AC-41.4.5 constraint 2 / AC-41.4.9).
  """
  @type base_verdict :: :network_local | :denylisted | :public
  @type purpose :: :inference | :webhook | :ingest
  @typedoc """
  The destination port a decision is about, or `:any` when the caller has only a
  HOST (a report, never an admission). `:any` is not a wildcard — see
  `Loopctl.Egress.Allowlist.allowed?/4`.
  """
  @type port_context :: :any | 1..65_535
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
      NEVER returned for a `tenant_supplied: true` url — that path fails CLOSED
      instead of issuing an unpinned, redirect-following request to a host an
      attacker influences.
    * `{:error, :egress_blocked, details}` — refused BEFORE any request is built.
      PERMANENT: a configuration state that will not change on its own.
    * `{:error, :pin_stale, details}` — the host's address set changed; the
      remediation is a re-pin (`repin/3`), which needs NO role `:user` write.
      TRANSIENT.
    * `{:error, :egress_unavailable, details}` — the `local_only` MARKING itself
      could not be resolved (a DB/pool hiccup). Fail-closed for this call, but
      TRANSIENT: callers snooze, never cancel.
  """
  @spec check(Scope.t(), String.t(), purpose(), keyword()) ::
          {:ok, :unpinned}
          | {:ok, UrlGuard.pinned()}
          | {:error, :egress_blocked, details()}
          | {:error, :pin_stale, details()}
          | {:error, :egress_unavailable, details()}
  def check(%Scope{} = scope, url, purpose, opts \\ []) when is_binary(url) do
    # The MARKING selects the regime, so it is resolved OUTSIDE the fail-closed
    # classifier rescue: an infrastructure hiccup here is `:egress_unavailable`
    # (transient), never `:egress_blocked` (permanent) — see the moduledoc.
    case marking(scope) do
      {:ok, true} -> guarded_check(scope, url, purpose)
      {:ok, false} -> default_path(scope, url, purpose, tenant_supplied?(opts))
      {:error, reason} -> marking_unavailable(scope, url, reason)
    end
  end

  defp tenant_supplied?(opts), do: Keyword.get(opts, :tenant_supplied, false) == true

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

  # AC-41.4.12: a non-`local_only` scope on a vendor default PINS at connect time.
  # The pin is a TOCTOU control, not a locality decision, so a pin that cannot be
  # taken must NOT become a refusal — that would hand every default tenant a brand-
  # new failure mode. Fall back to the pre-US-41.4 behaviour instead.
  #
  # The pin is served from the SAME cached, refresher-maintained entry the
  # `local_only` path uses. This is 100% of existing traffic: resolving per request
  # would put two uncached, synchronous `:inet.getaddrs/3` lookups (3s timeout each)
  # in front of EVERY provider call, and — because the pinned IP is what the Finch
  # pool keys on — would collapse connection reuse to a fresh TLS handshake every
  # time a CDN-fronted vendor host rotated its answer. AC-41.4.12 bounds the hot
  # path at one cheap classification with NO network or DB round-trip.
  #
  # `tenant_supplied?` is how a caller that owns a TENANT-WRITABLE url opts into
  # the SSRF denylist on this path (US-41.3 review). The default path was written
  # when every url on it was a hardcoded vendor host, so a `:denylisted` verdict
  # proceeded UNPINNED and the denylist was left "to the callers that own it" —
  # which was true of ingestion (`UrlGuard.pin/1`) but became a hole the moment
  # `chat_base_url` made this url tenant-writable. Rather than a second, divergent
  # URL policy at the chat client (an AC-41.4.9 review failure), the ONE policy
  # module refuses here. On a VENDOR (non-tenant-supplied) url nothing else changes:
  # an unresolvable or unpinnable host still proceeds unpinned, so those scopes
  # acquire no NEW failure mode. On a TENANT-SUPPLIED url the refusal is total — a
  # `:denylisted` verdict is the PERMANENT `:egress_blocked`, and a
  # classification/pin failure is the TRANSIENT `:egress_unavailable` (see
  # `unpinned_or_refuse/4`); it never degrades to an unpinned, redirect-following
  # request.
  defp default_path(scope, url, purpose, tenant_supplied?) do
    uri = URI.parse(url)

    with true <- uri.scheme in @pinnable_schemes,
         host when is_binary(host) and host != "" <- uri.host,
         {:ok, %{ips: [ip | _], verdict: verdict}} <-
           cached_classification(scope, host, purpose, uri_port(uri)),
         :ok <- denylist_gate(scope, host, verdict, tenant_supplied?),
         # A denylisted host is otherwise left UNPINNED exactly as `UrlGuard.pin/2`
         # used to leave it (`{:error, :blocked_ip}`).
         true <- verdict != :denylisted do
      {:ok, %{uri: uri, host: host, ip: ip}}
    else
      {:error, :egress_blocked, _details} = refusal ->
        refusal

      other ->
        unpinned_or_refuse(scope, url, other, tenant_supplied?)
    end
  rescue
    e ->
      unpinned_or_refuse(scope, url, {:classifier_raised, Exception.message(e)}, tenant_supplied?)
  catch
    :exit, reason -> unpinned_or_refuse(scope, url, {:classifier_exit, reason}, tenant_supplied?)
    :throw, value -> unpinned_or_refuse(scope, url, {:classifier_throw, value}, tenant_supplied?)
  end

  # The fall-through when the per-request pin could NOT be taken.
  #
  # For a HARDCODED VENDOR host this must degrade to the pre-US-41.4 behaviour: the
  # pin is a TOCTOU control, not a locality decision, and turning a DNS blip into a
  # refusal would hand every default tenant a brand-new failure mode.
  #
  # For a TENANT-SUPPLIED host it must NOT (US-41.3 review). `default_path/4` reaches
  # here on a `cached_classification/3` miss + `classify_uncached/2` error (e.g. a DNS
  # answer slower than the 3s resolve timeout), a classifier raise/exit/throw — all
  # attacker-INFLUENCED conditions when the host is tenant-controlled. Degrading there
  # would mean an unpinned request with Req's default redirect-FOLLOWING: make the
  # first resolution fail, and the connect-time resolution can land on 127.0.0.1 /
  # 169.254.169.254 / a Fly 6PN peer, with redirects followed on top. So we fail
  # CLOSED — as `:egress_unavailable`, which is TRANSIENT (workers snooze, the probe
  # reports a retryable refusal), because a resolve timeout is a blip, not a
  # configuration state. A genuinely denylisted host is still the PERMANENT
  # `:egress_blocked` from `denylist_gate/4`.
  defp unpinned_or_refuse(scope, _url, other, false) do
    Logger.debug(
      "Loopctl.Egress.Policy: per-request pin unavailable for #{Scope.key(scope)} " <>
        "(#{inspect(other)}); proceeding unpinned (scope is not local_only)"
    )

    {:ok, :unpinned}
  end

  defp unpinned_or_refuse(scope, url, other, true) do
    host = safe_host(url)

    Logger.warning(
      "Loopctl.Egress.Policy: refusing a TENANT-SUPPLIED endpoint for " <>
        "#{Scope.key(scope)}: #{inspect(host)} could not be classified/pinned " <>
        "(#{inspect(other)}); failing CLOSED rather than issuing an unpinned, " <>
        "redirect-following request"
    )

    {:error, :egress_unavailable,
     scope
     |> details(host, :unclassifiable)
     |> Map.put(
       :remediation,
       "The tenant-supplied endpoint #{inspect(host)} could not be resolved or " <>
         "classified, so the call was refused BEFORE any request was built (nothing " <>
         "was sent). This is TRANSIENT — retry shortly. If it persists, verify the " <>
         "host resolves from loopctl and re-check with the egress_posture tool."
     )}
  end

  # The SSRF refusal for a tenant-writable url whose host resolves into a private,
  # loopback, CGNAT, link-local or ULA range and is NOT carved out by the OPERATOR
  # deployment allowlist. PERMANENT — a configuration state, not a blip — so the
  # existing `:egress_blocked` handling (cancel, never retry) is exactly right, and
  # the details map already carries the operator-allowlist remediation.
  defp denylist_gate(scope, host, :denylisted, true) do
    Logger.warning(
      "Loopctl.Egress.Policy: refusing a TENANT-SUPPLIED endpoint for " <>
        "#{Scope.key(scope)}: #{host} is denylisted (SSRF guard)"
    )

    {:error, :egress_blocked, details(scope, host, :denylisted)}
  end

  defp denylist_gate(_scope, _host, _verdict, _tenant_supplied?), do: :ok

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
  Classifies `host` for `scope`/`purpose`/`port` WITHOUT deciding admission —
  used by `Loopctl.Egress.posture/2` and by the `local_only` enable pre-flight.

  PASS THE PORT whenever the caller has a URL. An operator carve-out may be bound
  to a specific port (see `Loopctl.Egress.Allowlist`), and the `:any` default —
  which means "no port in hand", not "every port" — does not match such an entry.
  A host-granular caller therefore gets the CONSERVATIVE answer; an admission
  decision made without the port would otherwise have to guess.
  """
  @spec classify(Scope.t(), String.t(), purpose(), port_context()) ::
          {:ok, %{verdict: verdict(), from_allowlist: boolean(), ips: [:inet.ip_address()]}}
          | {:error, term()}
  def classify(%Scope{} = scope, host, purpose, port \\ :any) when is_binary(host) do
    case cached_classification(scope, host, purpose, port) do
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
        # Re-check BOTH carve-out forms, exactly as `classify_uncached/2` grants
        # them. Checking only the address form would fail revalidation for every
        # host allowlisted BY NAME (the documented form, e.g. `ollama.internal`)
        # whose addresses are not separately covered by a literal/CIDR — the entry
        # would be re-put `pin_stale` with a fresh TTL every cycle and the tenant
        # would flap between working and `{:error, :pin_stale}` forever.
        from_allowlist and (Allowlist.host_allowed?(host) or Allowlist.ips_allowed?(ips)) ->
          {:ok, ips}

        from_allowlist ->
          {:error, :no_longer_allowlisted}

        UrlGuard.public_addresses?(ips) ->
          {:ok, ips}

        true ->
          {:error, :blocked_ip}
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
      {:ok, %{local_only: value}} -> {:ok, value}
      _ -> resolve_marking(scope, scope_key, @marking_attempts)
    end
  rescue
    e -> {:error, {:marking_error, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:marking_exit, reason}}
    :throw, value -> {:error, {:marking_throw, value}}
  end

  # The read-through half of the marking lookup. The tenant's invalidation
  # GENERATION is captured BEFORE the DB read, so an `enable_local_only/3` that
  # commits and invalidates while this read is in flight can never be masked by a
  # stale `local_only: false` cached for the remaining TTL: the put is dropped and
  # the read is retried once against the post-enable state.
  defp resolve_marking(scope, scope_key, attempts_left) do
    generation = PinCache.generation(scope.tenant_id)
    value = Egress.effective_local_only?(scope)

    PinCache.put(scope.tenant_id, scope_key, @marking_key, %{local_only: value},
      generation: generation
    )

    cond do
      not PinCache.stale_generation?(scope.tenant_id, generation) ->
        {:ok, value}

      attempts_left > 1 ->
        resolve_marking(scope, scope_key, attempts_left - 1)

      true ->
        # Nothing was cached (the put was dropped), so only THIS call uses the
        # possibly-superseded value; the next one reads the database again.
        {:ok, value}
    end
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
    case cached_classification(scope, host, purpose, uri_port(uri)) do
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

  @doc """
  How long a FAILED classification is remembered (review fix).

  Only SUCCESSFUL classifications used to be cached, so every caller paid the full
  resolve cost for an unresolvable host on every call, forever. That is the cost
  `Loopctl.Egress.posture/2` pays — a role `:agent`, parameterless endpoint agents
  are told to call before every harvest — over TENANT-SUPPLIED hostnames, and
  `UrlGuard`'s resolver spends up to 6s (`:inet` then `:inet6`) per dead host.

  Short on purpose: long enough to collapse a burst of lookups over the same dead
  host, short enough that a resolver blip clears promptly. A negative entry is a
  REFUSAL (`{:error, reason}`, fail-closed), never a permit, so caching one can
  never widen egress — the worst it can do is refuse a recovered host for the
  remainder of the window.
  """
  @spec negative_ttl_ms() :: pos_integer()
  def negative_ttl_ms do
    Application.get_env(:loopctl, :egress_negative_classification_ttl_ms, 30_000)
  end

  defp cached_classification(scope, host, purpose, port) do
    scope_key = Scope.key(scope)

    case PinCache.fetch(scope.tenant_id, scope_key, host) do
      # NEGATIVE cache hit. Short-circuited BEFORE `resolve_verdict/3`, which has
      # no meaning for an entry that never resolved (its catch-all would report
      # `:non_local` — a verdict, and on an unmarked scope a permissive one).
      {:ok, %{base_verdict: :unresolvable} = entry} ->
        {:error, Map.get(entry, :resolve_error, :unresolvable)}

      {:ok, entry} ->
        {:ok, resolve_verdict(entry, purpose, port)}

      :miss ->
        # Lazy initial population — no dependency on the US-41.2 probe. The
        # generation is captured BEFORE the (blocking) resolve + declaration read
        # so a revocation landing in that window is not resurrected by this put.
        generation = PinCache.generation(scope.tenant_id)

        case classify_uncached(scope, host) do
          {:ok, attrs} ->
            entry =
              PinCache.put(scope.tenant_id, scope_key, host, attrs, generation: generation)

            {:ok, resolve_verdict(entry, purpose, port)}

          {:error, reason} = error ->
            cache_unresolvable(scope, scope_key, host, reason, generation)
            error
        end
    end
  end

  defp cache_unresolvable(scope, scope_key, host, reason, generation) do
    PinCache.put(
      scope.tenant_id,
      scope_key,
      host,
      %{base_verdict: :unresolvable, resolve_error: reason, ips: [], purposes: []},
      generation: generation,
      ttl_ms: negative_ttl_ms()
    )

    :ok
  end

  @doc """
  Derives the purpose- and port-SCOPED verdict from a cached entry.

  The cache stores only purpose-INDEPENDENT facts (`base_verdict`, `ips`,
  `from_allowlist`, the host's declared `purposes`, and the verdict the host
  would carry WITHOUT its operator carve-out). Collapsing the purpose into a
  cached verdict would let the FIRST purpose to touch a host fix its verdict for
  the whole TTL — an inference endpoint declared for `["inference"]` but first
  classified under `:webhook` would then be refused for legitimate inference
  calls. AC-41.4.5 constraint (2) makes purpose scoping a security invariant, so
  it is re-derived on EVERY read.

  The OPERATOR carve-out is re-derived here too, for the same reason and one
  more: a carve-out that is REMOVED from the deployment configuration stops
  granting immediately instead of surviving to the end of the entry's TTL. The
  allowlist is a parsed in-memory config list, so this costs no network or DB
  round-trip and the AC-41.4.12 hot-path bound still holds.

  When the carve-out does NOT cover this `(purpose, port)`, the host falls back to
  what it is WITHOUT the carve-out — for a private address that is `:denylisted`,
  not `:non_local`. That distinction is load-bearing: `:non_local` passes
  `denylist_gate/4` and would be pinned and connected to on an unmarked scope,
  which is the whole refusal this module exists to make.
  """
  @spec resolve_verdict(map(), purpose(), port_context()) :: map()
  def resolve_verdict(entry, purpose, port \\ :any) do
    verdict = verdict_for(entry, purpose, port)

    entry
    |> Map.put(:verdict, verdict)
    # Never claim allowlist provenance for a verdict the allowlist did not grant.
    |> Map.put(
      :from_allowlist,
      verdict == :network_local and Map.get(entry, :from_allowlist, false)
    )
  end

  defp verdict_for(%{base_verdict: :network_local} = entry, purpose, port) do
    if allowlist_grants?(entry, purpose, port) do
      :network_local
    else
      entry
      |> Map.put(:base_verdict, Map.get(entry, :ungranted_base, :denylisted))
      |> verdict_for(purpose, port)
    end
  end

  defp verdict_for(%{base_verdict: :denylisted}, _purpose, _port), do: :denylisted

  defp verdict_for(%{base_verdict: :public, purposes: purposes}, purpose, _port) do
    if to_string(purpose) in purposes, do: :tenant_declared, else: :non_local
  end

  defp verdict_for(_entry, _purpose, _port), do: :non_local

  # A cached entry with no `:host` cannot be re-checked against the allowlist, so
  # it does not get the carve-out — the fallback below is the address's own
  # verdict, which for a private address is `:denylisted`. Fail closed.
  defp allowlist_grants?(%{host: host, ips: ips}, purpose, port) when is_binary(host) do
    Allowlist.allowed?(host, ips, purpose, port)
  end

  defp allowlist_grants?(_entry, _purpose, _port), do: false

  defp classify_uncached(scope, host) do
    with {:ok, ips} <- UrlGuard.resolve_host(host) do
      cond do
        # (a) OPERATOR carve-out — the only thing that may reach a private range.
        # WHICH purposes and ports it actually grants is re-derived per read by
        # `verdict_for/3`; what is cached here is only "a carve-out exists", plus
        # `ungranted_base`: what this host is when the carve-out does not apply.
        Allowlist.host_allowed?(host) or Allowlist.ips_allowed?(ips) ->
          {:ok,
           %{
             base_verdict: :network_local,
             ungranted_base: ungranted_base(ips),
             from_allowlist: true,
             ips: ips,
             purposes: Egress.declared_purposes(scope.tenant_id, host)
           }}

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

  # What an allowlisted host is WITHOUT its carve-out. Usually `:denylisted` (a
  # private address is exactly why a carve-out was needed), but an operator may
  # allowlist a PUBLIC host too, and that host must still be able to earn
  # `:tenant_declared` from the tenant's own declaration for purposes the
  # carve-out does not name.
  defp ungranted_base(ips) do
    if UrlGuard.public_addresses?(ips), do: :public, else: :denylisted
  end

  defp safe_host(url) do
    URI.parse(url).host
  rescue
    _ -> nil
  end

  @doc """
  The destination port a URI addresses, for the allowlist's port constraint.

  `URI.parse/1` fills the scheme's default port, so an `https://host/x` decision
  is made about port 443 rather than about "no port" — which is what an operator
  writing a portless carve-out expects, and what makes `host:443` a meaningful
  entry. A URI carrying no port and no known scheme default yields `:any`.
  """
  @spec uri_port(URI.t()) :: port_context()
  def uri_port(%URI{port: port}) when is_integer(port) and port in 1..65_535, do: port
  def uri_port(_uri), do: :any

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
