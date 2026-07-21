defmodule Loopctl.Webhooks.DeliveryBehaviour do
  @moduledoc """
  Behaviour for webhook HTTP delivery.

  Implementations must accept a URL, JSON body, headers and the EGRESS SCOPE the
  delivery is made on behalf of, then return success, a delivery failure, or an
  EGRESS REFUSAL.

  ## Why the scope is a callback argument (US-41.5, AC-41.5.1)

  Webhook delivery is content-carrying egress: the payload is tenant state. It
  therefore consults the SAME single egress policy (`Loopctl.Egress.Policy`) as
  the model-provider path, and that decision is scope-dependent
  (most-restrictive-wins, `project OR tenant`). A behaviour without a scope
  argument would force the implementation to re-derive the scope from the URL —
  which is impossible — or to keep a private copy of the locality rules, which
  AC-41.4.9 calls a review failure.

  `scope: nil` marks OPERATOR-PLANE delivery (the scale-alert webhook, whose URL
  is operator configuration and which carries no tenant content). There is no
  tenant marking to apply, so nil-scope delivery is guarded by the SSRF denylist
  alone — the same `Loopctl.Net.UrlGuard` denylist the policy composes, not a
  second policy. See the triage table in `docs/egress-guard.md`.

  ## `{:refused, refusal}` is NOT `{:error, reason}`

  A refusal is a CONFIGURATION CONFLICT, not a delivery failure (AC-41.5.2). The
  caller must be able to tell them apart: a failure retries and eventually
  exhausts, whereas `:egress_blocked` is TERMINAL (no retry, no attempts burned)
  and `:pin_stale` / `:egress_unavailable` are TRANSIENT (snooze, never
  terminal). `Loopctl.Egress.oban_result/1` is the ONE mapping.
  """

  alias Loopctl.Egress.Scope

  @type headers :: [{String.t(), String.t()}]
  @type refusal :: {atom(), map()}
  @type delivery_result ::
          {:ok, %{status: integer(), body: String.t()}}
          | {:error, String.t()}
          | {:refused, refusal()}

  @callback deliver(
              url :: String.t(),
              body :: String.t(),
              headers :: headers(),
              scope :: Scope.t() | nil
            ) :: delivery_result()
end
