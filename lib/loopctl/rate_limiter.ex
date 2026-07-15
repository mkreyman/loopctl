defmodule Loopctl.RateLimiter do
  @moduledoc """
  Config-based DI resolver for the rate-limiter implementation (US-38.2).

  EVERY rate-limiter call site — the web RPM plug (`LoopctlWeb.Plugs.RateLimiter`),
  the outbound provider gate (`Loopctl.Provider.Admission`), and the
  signup/enroll/retrieve gates (`LoopctlWeb.SignupLive`, `SignupController`,
  `TenantAuthenticatorController`, `ContextRetrieverController`) — resolves the
  active `Loopctl.RateLimiter.Behaviour` implementation through `impl/0`, so
  selecting a different backend is a single config change with NO call-site edits
  and ONE source of the default constant.

  The DEFAULT (when `:rate_limiter` is unset) is `Loopctl.RateLimiter.Hammer`,
  the node-local ETS backend — today's single-node behaviour. Setting
  `RATE_LIMITER=postgres` (see `config/runtime.exs`) swaps in
  `Loopctl.RateLimiter.Postgres`, the shared cluster-global counter store, and
  BOTH call sites become cluster-global with no code change.

  `default_impl/0` exposes the production default constant so a test can assert
  the default-off safety property (AC-38.2.3) against a real production symbol
  rather than a hardcoded literal — deleting/changing the default here fails that
  test.

  ## Robust gate helpers — `within_limit?/3` (fail-OPEN) and `gate_ok?/3` (fail-CLOSED)

  Callers should route their check through one of these boolean helpers rather
  than calling `impl().check_rate/3` and matching only `{:allow, _}` / `{:deny, _}`.
  The behaviour permits `{:error, term()}` (the default `Hammer` impl can return
  it), so a bare two-clause `case` raises `CaseClauseError` (→ 500) on a limiter
  soft-error. Both helpers normalise EVERY outcome — `{:error, _}`, an unexpected
  shape, or a raised/exited/thrown exception — to a boolean, logging the fault
  through the throttled, PII-safe `Loopctl.RateLimiter.FailOpenLog`.

  Pick by what the gate protects:

    * `within_limit?/3` — **fail-OPEN** (a fault returns `true`/allowed). Use for
      CAPACITY gates where availability wins over strict enforcement, matching the
      RPM plug and `Loopctl.Provider.Admission` (AC-38.2.3 fail-open parity).

    * `gate_ok?/3` — **fail-CLOSED** (a fault returns `false`/denied). Use for
      ANTI-ABUSE / BRUTE-FORCE security gates (signup abuse, WebAuthn-verify
      throttle, enroll). Failing these OPEN would silently unlock the very gate
      meant to stop the attacker — and the protected write path needs the DB
      anyway, so denying at the gate during a store fault costs no real
      availability. `gate_ok?/3` also treats the Postgres impl's `{:allow, 0}`
      fail-open sentinel as denied, so selecting `RATE_LIMITER=postgres` does NOT
      broaden fail-open into these security gates (see `Loopctl.RateLimiter.Postgres`).
  """

  alias Loopctl.RateLimiter.FailOpenLog

  @default_impl Loopctl.RateLimiter.Hammer

  @doc """
  The DI-resolved limiter implementation.

  Reads `Application.get_env(:loopctl, :rate_limiter, default_impl())`, so an
  unset key yields the node-local ETS default and `RATE_LIMITER=postgres` yields
  the shared Postgres impl. Resolved at CALL time (never captured as an opt) so
  `config/test.exs` can swap in `Loopctl.MockRateLimiter`.
  """
  @spec impl() :: module()
  def impl, do: Application.get_env(:loopctl, :rate_limiter, @default_impl)

  @doc """
  The production DEFAULT implementation used when `:rate_limiter` is unset:
  `Loopctl.RateLimiter.Hammer` (node-local ETS). This is the "default-off"
  behaviour AC-38.2.3 pins.
  """
  @spec default_impl() :: module()
  def default_impl, do: @default_impl

  @doc """
  FAIL-OPEN limiter check for CAPACITY gates.

  Returns `true` when the request is within the limit OR the limiter faulted
  (parity with the RPM plug / `Loopctl.Provider.Admission`). Never raises.
  """
  @spec within_limit?(String.t(), non_neg_integer(), non_neg_integer()) :: boolean()
  def within_limit?(bucket, window_ms, limit) do
    case safe_check(:capacity, bucket, window_ms, limit) do
      {:allow, _count} -> true
      {:deny, _limit} -> false
      :error -> true
    end
  end

  @doc """
  FAIL-CLOSED limiter check for ANTI-ABUSE / BRUTE-FORCE security gates.

  Returns `true` ONLY on a genuine allow with a positive post-increment count.
  A deny, a limiter fault, or the Postgres impl's `{:allow, 0}` fail-open
  sentinel all return `false` (denied), so a store fault cannot silently unlock
  the gate. Never raises.
  """
  @spec gate_ok?(String.t(), non_neg_integer(), non_neg_integer()) :: boolean()
  def gate_ok?(bucket, window_ms, limit) do
    case safe_check(:security, bucket, window_ms, limit) do
      # count > 0 excludes the {:allow, 0} fail-open sentinel (real allows are
      # post-increment counts >= 1), so a Postgres DB-fault fail-open denies here.
      {:allow, count} when count > 0 -> true
      _ -> false
    end
  end

  # Resolve the DI impl, normalise every outcome to {:allow, count} | {:deny, limit}
  # | :error, and log any fault through the throttled, PII-safe FailOpenLog.
  defp safe_check(source, bucket, window_ms, limit) do
    case impl().check_rate(bucket, window_ms, limit) do
      {:allow, count} when is_integer(count) -> {:allow, count}
      {:deny, denied_limit} when is_integer(denied_limit) -> {:deny, denied_limit}
      other -> fault(source, bucket, "limiter returned #{inspect(other)}")
    end
  rescue
    e -> fault(source, bucket, Exception.message(e))
  catch
    :exit, reason -> fault(source, bucket, "exit: #{inspect(reason)}")
    :throw, value -> fault(source, bucket, "throw: #{inspect(value)}")
  end

  defp fault(source, bucket, detail) do
    FailOpenLog.warn(source, bucket, detail)
    :error
  end
end
