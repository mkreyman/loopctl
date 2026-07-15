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
  """

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
end
