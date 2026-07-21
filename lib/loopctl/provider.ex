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
          optional(:purpose) => Policy.purpose()
        }

  @doc """
  POSTs to `url` for `ctx.scope`, refusing BEFORE the request is built when the
  scope is `local_only` and the resolved endpoint is not classified local.

  Returns `Req`'s own `{:ok, response} | {:error, exception}` when allowed, or:

    * `{:error, :egress_blocked}` — a PERMANENT configuration refusal. No data
      was sent. Oban workers map this to `{:cancel, :egress_blocked}` — never
      `{:error, _}` (which Oban retries) and never `{:snooze, _}`.
    * `{:error, :pin_stale}` — the pinned address set changed; remediation is a
      re-pin, which needs no role `:user` write. DISTINCT from `:egress_blocked`
      and never conflated with it.
  """
  @spec post(String.t(), keyword(), ctx()) :: {:ok, term()} | {:error, term()}
  def post(url, req_opts, %{scope: %Scope{} = scope} = ctx) do
    purpose = Map.get(ctx, :purpose, :inference)

    case Policy.check(scope, url, purpose) do
      {:ok, :unpinned} ->
        Req.post(url, req_opts)

      {:ok, pinned} ->
        Req.post(pinned_opts(pinned, req_opts))

      {:error, :egress_blocked, details} ->
        Egress.record_blocked(scope, details)
        {:error, :egress_blocked}

      {:error, :pin_stale, _details} ->
        {:error, :pin_stale}
    end
  end

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
