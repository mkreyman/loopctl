defmodule Loopctl.Provider do
  @moduledoc """
  The SINGLE MANDATORY CHOKEPOINT for model-provider egress (US-41.4, AC-41.4.4).

  ## Why a wrapper and not a convention

  `Loopctl.Provider.Admission` was added site-by-site and is consequently MISSED
  at `webhooks/req_delivery.ex`, `verification/github_actions.ex` and
  `secrets/fly_adapter.ex`. A guarantee enforced by per-call-site convention
  regresses the first time someone adds a `Req` call. So every tenant-content
  provider call routes through `post/3` here, and the static chokepoint check
  (`Loopctl.Egress.ChokepointScan`, wired into `mix credo --strict` via
  `.credo/checks/direct_outbound_http.ex`) fails CI on any direct outbound HTTP
  call in the scanned paths outside this wrapper's explicit allowlist.

  ## Two decisions, never one code path

  `Admission.admit/2` (fail-OPEN burst shedding) stays at the call sites as its
  own `with` clause. The egress guard (fail-CLOSED) lives here. Fusing them would
  mean a Hammer or `SystemConfig` hiccup silently degrades the privacy guarantee
  to "allow" — turning a guarantee into a hope. A test asserts that with the
  admission backend fully unavailable (fail-open triggered), a `local_only` scope
  with a non-local endpoint is STILL blocked.

  ## Residual gap, documented rather than papered over

  The static check cannot see HTTP performed INSIDE a dependency, and it does not
  cover the separate `mcp-server/` codebase. The guarantee wording everywhere
  narrows to exactly what is proven: **every outbound HTTP call made by loopctl
  application code**.
  """

  alias Loopctl.Egress
  alias Loopctl.Egress.Policy
  alias Loopctl.Egress.Scope
  alias Loopctl.Net.UrlGuard

  @type ctx :: %{
          required(:scope) => Scope.t(),
          optional(:purpose) => Policy.purpose(),
          optional(:pinned_by_caller) => boolean()
        }

  @doc """
  POSTs to `url` for `ctx.scope`, refusing BEFORE the request is built when the
  scope is `local_only` and the resolved endpoint is not classified local.

  Returns `Req`'s own `{:ok, response} | {:error, exception}` when allowed, or one
  of the three refusal terms below. Each carries the DETAILS map (`host`, `scope`,
  `verdict`, `remediation`) so the failure that reaches an Oban `cancelled_at` /
  `errors` record NAMES the scope and the offending endpoint (AC-41.4.6) instead
  of a bare atom an operator cannot act on:

    * `{:error, {:egress_blocked, details}}` — a PERMANENT configuration refusal.
      No data was sent. Oban workers map this to `{:cancel, _}` — never
      `{:error, _}` (which Oban retries) and never `{:snooze, _}`.
    * `{:error, {:pin_stale, details}}` — the pinned address set changed;
      remediation is a re-pin, which needs no role `:user` write. DISTINCT from
      `:egress_blocked`, never conflated with it, and TRANSIENT: workers SNOOZE
      it (the supervised refresher re-pins on its own, and cancelling would
      permanently drop every in-flight job over a DHCP lease change).
    * `{:error, {:egress_unavailable, details}}` — the `local_only` marking could
      not be read (infrastructure hiccup). Fail-closed for this call, TRANSIENT,
      snoozed by workers.
  """
  @spec post(String.t(), keyword(), ctx()) :: {:ok, term()} | {:error, term()}
  def post(url, req_opts, ctx), do: request(:post, url, req_opts, ctx)

  @doc """
  GETs `url` for `ctx.scope` under the same guard as `post/3`.

  Used by the content-ingestion FETCH path (AC-41.4.9: ingestion consults the ONE
  policy module too), whose purpose is `:ingest` — a tenant declaration for
  `inference` does NOT authorize loopctl to fetch tenant-supplied URLs, and vice
  versa.

  That caller has ALREADY applied `UrlGuard.pin/1` + `pinned_request_opts/1` (its
  own SSRF gate, GHSA-j7m9-ffmr-pwhm, which must refuse a private-range URL for
  EVERY tenant, marked or not), so it passes `pinned_by_caller: true` and this
  wrapper leaves the connection options alone. Re-pinning them here would rewrite
  `:url` and PREPEND a SECOND `Host` header onto opts that already carry one.
  """
  @spec get(String.t(), keyword(), ctx()) :: {:ok, term()} | {:error, term()}
  def get(url, req_opts, ctx), do: request(:get, url, req_opts, ctx)

  defp request(method, url, req_opts, %{scope: %Scope{} = scope} = ctx) do
    purpose = Map.get(ctx, :purpose, :inference)
    caller_pinned? = Map.get(ctx, :pinned_by_caller, false)

    case Policy.check(scope, url, purpose) do
      # `put_new`, never `put`: a caller that already pinned has `:url` rewritten
      # to its validated IP, and overwriting it with the original hostname would
      # silently DROP that SSRF pin and reopen the DNS-rebinding window.
      {:ok, :unpinned} ->
        req(method, Keyword.put_new(req_opts, :url, url))

      {:ok, _pinned} when caller_pinned? ->
        req(method, req_opts)

      {:ok, pinned} ->
        req(method, pinned_opts(pinned, req_opts))

      {:error, :egress_blocked, details} ->
        Egress.record_blocked(scope, details)
        {:error, {:egress_blocked, details}}

      {:error, transient, details} when transient in [:pin_stale, :egress_unavailable] ->
        {:error, {transient, details}}
    end
  end

  defp req(:post, opts), do: Req.post(opts)
  defp req(:get, opts), do: Req.get(opts)

  # Connect to exactly the IP the guard vetted (closing the resolve-then-connect
  # TOCTOU) while preserving the original host for Host/SNI/cert verification, and
  # never follow a redirect back out to an unvalidated URL.
  defp pinned_opts(pinned, req_opts) do
    headers = Keyword.get(req_opts, :headers, [])

    req_opts
    |> Keyword.merge(UrlGuard.pinned_request_opts(pinned, headers))
    |> Keyword.put(:redirect, false)
  end
end
