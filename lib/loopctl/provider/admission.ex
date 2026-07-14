defmodule Loopctl.Provider.Admission do
  @moduledoc """
  Per-`(tenant_id, provider)` token-bucket admission gate that sits IMMEDIATELY
  before every outbound provider `Req.post` (US-37.1, GH #352).

  ## Why

  Nothing used to sit between agent demand and the provider socket. A burst fired
  unbounded outbound provider calls (`Req.post`) and triggered a provider-side
  429 / `:transport_error` storm. This gate makes a cheap node-local admission
  decision BEFORE the HTTP request is built: on an empty bucket it fast-fails
  locally with `{:error, :rate_limited_local}` WITHOUT issuing the request, so
  callers degrade cheaply (interactive search → keyword fallback; background
  embedding jobs → snooze/retry).

  ## Scope key

  The Hammer bucket key is scoped by `{tenant_id, provider}`:

      "provider_admission:embedding:<tenant_id>"
      "provider_admission:anthropic:<tenant_id>"

  so one `(tenant, provider)` pair can never consume another's allowance
  (AC-37.1.1). `provider` is a fixed atom (`:embedding` | `:anthropic`) — never a
  user-supplied value — so the key is bounded and no `String.to_atom/1` on input
  is involved.

  ## Capacity / refill (env-driven, live-tunable, no deploy)

  A Hammer sliding window: a fixed 60s window with a per-provider request limit
  (RPM). Limits are read via `Loopctl.SystemConfig.get_int/2` (DB-backed,
  hot-path-safe, returns the in-code default on a cache miss), so an operator can
  retune per environment — and per tenant tier, by seeding a different row — with
  no deploy (AC-37.1.2). Keys and per-node defaults:

    * `"provider_admission_embedding_rpm"` — default 600 req/node/min
    * `"provider_admission_anthropic_rpm"` — default 300 req/node/min

  Defaults are deliberately generous: the gate is a defensive ceiling against a
  runaway burst, NOT a business quota. TPM is intentionally out of scope — the AC
  is satisfied by RPM alone ("RPM and/or TPM").

  ## Node-local by design (AC-37.1.6)

  Hammer's default backend is node-local ETS, so each node keeps its own bucket.
  A cluster-wide shared bucket is explicitly OUT OF SCOPE (deferred to Epic 38);
  the effective fleet ceiling is `rpm * node_count`.

  ## Fail-OPEN (AC-37.1.6)

  The `check_rate/3` call is wrapped in `try/rescue`: on ANY limiter error (a
  Hammer/ETS fault) the gate LOGS a warning and returns `:ok` (allows the call).
  A monitoring fault must never block ALL provider traffic — the gate degrades to
  "no gate", never to "deny everything".
  """

  require Logger

  alias Loopctl.SystemConfig

  @providers [:embedding, :anthropic]

  # 60s sliding window; the limit is the requests-per-minute ceiling per node.
  @window_ms 60_000

  # Generous per-node defaults — a defensive ceiling against a runaway burst, not
  # a business quota. Tunable live via SystemConfig with no deploy.
  @default_embedding_rpm 600
  @default_anthropic_rpm 300

  @type provider :: :embedding | :anthropic

  @doc """
  Admit (or reject) one outbound call for `{tenant_id, provider}`.

  Returns:

    * `:ok` — a token was taken; the caller proceeds to `Req.post`.
    * `{:error, :rate_limited_local}` — the node-local bucket for this
      `(tenant, provider)` is empty; the caller must NOT issue the HTTP request.

  FAILS OPEN: any limiter error is logged and returns `:ok`.
  """
  @spec admit(String.t(), provider()) :: :ok | {:error, :rate_limited_local}
  def admit(tenant_id, provider)
      when is_binary(tenant_id) and provider in @providers do
    bucket = bucket_key(tenant_id, provider)
    limit = limit_for(provider)

    case rate_limiter().check_rate(bucket, @window_ms, limit) do
      {:allow, _count} -> :ok
      {:deny, _limit} -> {:error, :rate_limited_local}
    end
  rescue
    e ->
      # AC-37.1.6: a Hammer/ETS fault must ALLOW the call, never block all
      # provider traffic. Log and fail open.
      Logger.warning(
        "Loopctl.Provider.Admission: limiter error for provider=#{provider}; " <>
          "failing OPEN (allowing call): #{Exception.message(e)}"
      )

      :ok
  end

  defp bucket_key(tenant_id, provider), do: "provider_admission:#{provider}:#{tenant_id}"

  defp limit_for(:embedding),
    do: SystemConfig.get_int("provider_admission_embedding_rpm", @default_embedding_rpm)

  defp limit_for(:anthropic),
    do: SystemConfig.get_int("provider_admission_anthropic_rpm", @default_anthropic_rpm)

  # Config-based DI (project convention): resolve the limiter at call time so
  # config/test.exs can swap in Loopctl.MockRateLimiter. NEVER passed as an opt.
  defp rate_limiter,
    do: Application.get_env(:loopctl, :rate_limiter, Loopctl.RateLimiter.Hammer)
end
