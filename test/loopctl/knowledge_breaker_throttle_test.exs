defmodule Loopctl.KnowledgeBreakerThrottleTest do
  @moduledoc """
  US-37.3 (TC-37.3.1 / TC-37.3.5): the throttle-aware embedding circuit breaker.

  Drives the PUBLIC `Knowledge.generate_embedding/3` (routed to
  `Loopctl.MockEmbeddingClient`) and observes the breaker via its short-circuit
  return: once the breaker is open, `generate_embedding/3` returns
  `{:error, :circuit_open}` WITHOUT calling the client. So a class that COUNTS
  yields `:circuit_open` after `@failure_threshold` (3) failures; an EXEMPT class
  never does.
  """
  use Loopctl.DataCase, async: true

  import Mox

  setup :verify_on_exit!

  alias Loopctl.Knowledge

  @breaker_table :loopctl_embedding_circuit_breaker

  defp always_return(term) do
    Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text -> term end)
  end

  # Trip attempt: call the threshold count, then probe once more.
  defp probe_after_threshold(tenant_id) do
    for _ <- 1..3, do: Knowledge.generate_embedding(tenant_id, "x")
    Knowledge.generate_embedding(tenant_id, "x")
  end

  describe "breaker COUNTS throttle + systemic failures (AC-37.3.1)" do
    for {label, term} <- [
          {"429 (throttle)", {:error, {:api_error, 429, :provider_error}}},
          {"408 (throttle)", {:error, {:api_error, 408, :provider_error}}},
          {"429 + Retry-After 4-tuple", {:error, {:api_error, 429, :provider_error, 30}}},
          {"500 (systemic)", {:error, {:api_error, 500, :provider_error}}},
          {"request_failed (transport)", {:error, {:request_failed, :econnrefused}}},
          {"embedding_crash", {:error, {:embedding_crash, :exception}}},
          {"timeout", {:error, :timeout}}
        ] do
      test "#{label} counts → breaker opens after threshold" do
        tenant = fixture(:tenant)
        Knowledge.reset_circuit_breaker(tenant.id)
        always_return(unquote(Macro.escape(term)))

        assert {:error, :circuit_open} = probe_after_threshold(tenant.id)
      end
    end
  end

  describe "breaker EXEMPTS credential + self-imposed reasons (AC-37.3.1 / AC-37.3.5)" do
    for {label, term} <- [
          {"401 (credential)", {:error, {:api_error, 401, :provider_error}}},
          {"403 (credential)", {:error, {:api_error, 403, :provider_error}}},
          {"rate_limited_local (US-37.1)", {:error, :rate_limited_local}}
        ] do
      test "#{label} is exempt → breaker stays closed (client still consulted)" do
        tenant = fixture(:tenant)
        Knowledge.reset_circuit_breaker(tenant.id)
        always_return(unquote(Macro.escape(term)))

        # Far beyond the threshold: the breaker must NEVER open, so every call keeps
        # returning the underlying error, never :circuit_open.
        results = for _ <- 1..6, do: Knowledge.generate_embedding(tenant.id, "x")

        refute Enum.any?(results, &match?({:error, :circuit_open}, &1))
        assert Enum.all?(results, &match?(unquote(Macro.escape(term)), &1))
      end
    end

    # AC-37.3.1: a non-throttle, non-credential 4xx (400/404/422) is a per-request
    # client error, NOT a systemic provider incident — it must stay EXEMPT ("other
    # 4xx keep today's behavior"). Guards the catch-all `breaker_countable?/1`
    # is_integer(status) -> false clause against a future refactor silently making a
    # generic 4xx trip the breaker.
    for {label, term} <- [
          {"400 (bad request)", {:error, {:api_error, 400, :provider_error}}},
          {"404 (not found)", {:error, {:api_error, 404, :provider_error}}},
          {"422 (unprocessable)", {:error, {:api_error, 422, :provider_error}}}
        ] do
      test "#{label} is exempt → breaker stays closed" do
        tenant = fixture(:tenant)
        Knowledge.reset_circuit_breaker(tenant.id)
        always_return(unquote(Macro.escape(term)))

        results = for _ <- 1..6, do: Knowledge.generate_embedding(tenant.id, "x")

        refute Enum.any?(results, &match?({:error, :circuit_open}, &1))
        assert Enum.all?(results, &match?(unquote(Macro.escape(term)), &1))
      end
    end

    test "no_api_key never reaches the breaker and surfaces cleanly" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      always_return({:error, :no_api_key})

      results = for _ <- 1..6, do: Knowledge.generate_embedding(tenant.id, "x")

      assert Enum.all?(results, &(&1 == {:error, :no_api_key}))
    end
  end

  describe "Retry-After raises the breaker cooldown (AC-37.3.3)" do
    test "a throttle 4-tuple with a large Retry-After sets a cooldown ~that interval" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      # 200s is above the base cooldown (30s) and below the clamp max (300s).
      always_return({:error, {:api_error, 429, :provider_error, 200}})

      # Trip the breaker.
      for _ <- 1..3, do: Knowledge.generate_embedding(tenant.id, "x")
      assert {:error, :circuit_open} = Knowledge.generate_embedding(tenant.id, "x")

      # Read the open_until back out (monotonic seconds) — class assertion: the
      # cooldown honors the Retry-After (>= ~200), never below base, never above max.
      now = System.monotonic_time(:second)
      [{_key, open_until}] = :ets.lookup(@breaker_table, {tenant.id, :open_until})
      remaining = open_until - now

      assert remaining >= 195, "expected cooldown to honor Retry-After (~200s), got #{remaining}"
      assert remaining <= 300, "expected cooldown clamped to max (300s), got #{remaining}"
    end

    test "a throttle WITHOUT a Retry-After uses the base cooldown (~30s), not longer" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      always_return({:error, {:api_error, 429, :provider_error}})

      for _ <- 1..3, do: Knowledge.generate_embedding(tenant.id, "x")
      assert {:error, :circuit_open} = Knowledge.generate_embedding(tenant.id, "x")

      now = System.monotonic_time(:second)
      [{_key, open_until}] = :ets.lookup(@breaker_table, {tenant.id, :open_until})
      remaining = open_until - now

      # Base cooldown class: ~30s, well under the honored-Retry-After case above.
      assert remaining > 0 and remaining <= 30
    end
  end

  describe "tenant isolation" do
    test "one tenant's throttle storm does not open another tenant's breaker" do
      a = fixture(:tenant)
      b = fixture(:tenant)
      Knowledge.reset_circuit_breaker(a.id)
      Knowledge.reset_circuit_breaker(b.id)
      always_return({:error, {:api_error, 429, :provider_error}})

      # Trip tenant A only.
      for _ <- 1..4, do: Knowledge.generate_embedding(a.id, "x")
      assert {:error, :circuit_open} = Knowledge.generate_embedding(a.id, "x")

      # Tenant B's breaker is untouched — the client is still consulted for B.
      assert {:error, {:api_error, 429, :provider_error}} =
               Knowledge.generate_embedding(b.id, "x")
    end
  end
end
