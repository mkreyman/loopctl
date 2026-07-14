defmodule Loopctl.Provider.Admission do
  @moduledoc """
  Per-`(tenant_id, provider)` fixed-window admission gate that sits IMMEDIATELY
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

  ## Algorithm — Hammer FIXED-WINDOW counter (not a leaky/token bucket)

  This gate is backed by Hammer's `check_rate/3`, which is a FIXED-WINDOW
  counter: a fresh 60s window opens on the first request for a bucket and the
  count resets to zero when it rolls over. It is NOT a token/leaky bucket and
  NOT a sliding window. The practical consequence operators must size for: a
  fixed window admits up to ~2x the limit across a boundary (up to `limit`
  requests just before a window rolls at t≈59s, then up to `limit` more just
  after at t≈61s). That is a weaker burst guarantee than a true bucket, but the
  gate's job is to shed a runaway burst below the provider's hard ceiling, and
  the generous defaults absorb the 2x boundary overshoot — so reusing
  `check_rate/3` is a deliberate, accepted tradeoff (technical-notes sanctioned).

  ## Capacity (env-driven, live-tunable, no deploy)

  A fixed 60s window with a per-provider request limit (RPM). Limits are read via
  `Loopctl.SystemConfig.get_int/2` (DB-backed, hot-path-safe, returns the in-code
  default on a cache miss), so an operator can retune per environment with no
  deploy (AC-37.1.2). The limit is a SINGLE global value per provider — there is
  currently no per-tenant / per-tier dimension (the `SystemConfig` store is
  global, keyed only by the config name), so every tenant on a node shares the
  same ceiling; the per-tenant BUCKET KEY still isolates each tenant's *count*.
  Per-tenant-tier limits are explicitly optional in AC-37.1.2 and deferred. Keys
  and per-node defaults:

    * `"provider_admission_embedding_rpm"` — default 600 req/node/min
    * `"provider_admission_anthropic_rpm"` — default 300 req/node/min

  Defaults are deliberately generous: the gate is a defensive ceiling against a
  runaway burst, NOT a business quota. TPM is intentionally out of scope — the AC
  is satisfied by RPM alone ("RPM and/or TPM").

  ## Snooze duration for loss-free backpressure (AC-37.1.4)

  When a background worker receives `{:error, :rate_limited_local}` it should
  yield loss-free rather than consume an Oban attempt. `snooze_seconds/0` is the
  single source of that jittered snooze duration for ALL admission-backed workers
  (both embedding workers and the Anthropic-backed ingestion/review/promotion
  workers) so every `provider_admission_*` knob and default lives in one place.
  Live-tunable via `"provider_admission_snooze_seconds"` (default 5s); the jitter
  avoids a thundering-herd of snoozed jobs re-checking in lockstep.

  ## Node-local by design (AC-37.1.6)

  Hammer's default backend is node-local ETS, so each node keeps its own bucket.
  A cluster-wide shared bucket is explicitly OUT OF SCOPE (deferred to Epic 38);
  the effective fleet ceiling is `rpm * node_count`.

  ## Fail-OPEN (AC-37.1.6)

  The `check_rate/3` call is wrapped in `try/rescue/catch`: on ANY limiter error
  the gate LOGS a warning and returns `:ok` (allows the call). "ANY" is
  deliberate and covers every failure mode Hammer can surface:

    * a raised exception (Hammer/ETS fault) — caught by `rescue`;
    * Hammer's documented `{:error, reason}` soft-error return — matched by an
      explicit `case` clause;
    * an `exit` — Hammer reaches its backend via `:poolboy.transaction/3`, a
      `gen_server:call` that EXITS (does not raise) with `:noproc` when the pool
      is down/unstarted and `{:timeout, _}` on checkout timeout; caught by
      `catch :exit`. `rescue` alone would MISS this and let the exit crash the
      calling worker (and, on the embedding path, the linked `Task.async`
      caller), defeating fail-open.
    * a `throw` — caught by `catch :throw` for completeness.

  A monitoring fault must never block ALL provider traffic — the gate degrades to
  "no gate", never to "deny everything".
  """

  require Logger

  alias Loopctl.SystemConfig

  @providers [:embedding, :anthropic]

  # Fixed 60s window; the limit is the requests-per-minute ceiling per node.
  @window_ms 60_000

  # Generous per-node defaults — a defensive ceiling against a runaway burst, not
  # a business quota. Tunable live via SystemConfig with no deploy.
  @default_embedding_rpm 600
  @default_anthropic_rpm 300

  # Base snooze (seconds) a worker waits after {:error, :rate_limited_local}
  # before Oban re-runs it loss-free. Live-tunable; jitter added in snooze_seconds/0.
  @default_snooze_seconds 5

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
      # Hammer's documented soft-error shape ({:error, reason}, e.g. its ETS
      # count_hit failing). Handle it deliberately rather than letting it fall
      # through to a CaseClauseError caught by `rescue`. AC-37.1.6: fail open.
      {:error, reason} -> fail_open(provider, "limiter returned {:error, #{inspect(reason)}}")
    end
  rescue
    # A raised exception (Hammer/ETS fault, or the CaseClauseError from an
    # undocumented return shape). AC-37.1.6: fail open.
    e -> fail_open(provider, Exception.message(e))
  catch
    # A raised exception is NOT the only failure mode. Hammer reaches its backend
    # via :poolboy.transaction/3 -> gen_server:call, which EXITS (not raises) with
    # :noproc when the pool is down/unstarted or {:timeout, _} on checkout timeout.
    # `rescue` only catches exceptions, so without this the exit would propagate
    # out and crash the calling worker (and, in the embedding path, the linked
    # Task.async caller) — defeating fail-open. Catch exits (and throws) too.
    :exit, reason -> fail_open(provider, "limiter exit: #{inspect(reason)}")
    :throw, value -> fail_open(provider, "limiter throw: #{inspect(value)}")
  end

  @doc """
  Jittered snooze duration (seconds) for a background worker that received
  `{:error, :rate_limited_local}` from this gate (AC-37.1.4).

  Single source of truth for the admission snooze across ALL admission-backed
  workers. The base is live-tunable via the `"provider_admission_snooze_seconds"`
  `SystemConfig` key (default #{@default_snooze_seconds}s); a small `0..5s` jitter
  is added so a burst of snoozed jobs does not re-check the gate in lockstep.
  """
  @spec snooze_seconds() :: pos_integer()
  def snooze_seconds do
    base = SystemConfig.get_int("provider_admission_snooze_seconds", @default_snooze_seconds)
    # Clamp the (live-tunable, possibly misconfigured) base to >= 1 BEFORE adding
    # jitter. `:rand.uniform(6) - 1` is 0..5, so an unclamped base of 0 (or a
    # negative knob) could yield 0/negative — a {:snooze, 0} is an immediate
    # re-run against a still-shut gate (a tight snooze/re-check loop) and violates
    # the pos_integer() @spec. max(1, base) guarantees a result of >= 1.
    max(1, base) + :rand.uniform(6) - 1
  end

  # AC-37.1.6: a limiter fault (raised exception, {:error, reason}, exit, or
  # throw) must ALLOW the call, never block all provider traffic. Log and fail
  # open. Single sink so every failure mode logs and degrades identically.
  defp fail_open(provider, detail) do
    Logger.warning(
      "Loopctl.Provider.Admission: limiter error for provider=#{provider}; " <>
        "failing OPEN (allowing call): #{detail}"
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
