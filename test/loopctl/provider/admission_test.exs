defmodule Loopctl.Provider.AdmissionTest do
  @moduledoc """
  Per-(tenant, provider) node-local token-bucket admission gate (US-37.1, #352).

  The limiter is swapped for `Loopctl.MockRateLimiter` via config/test.exs; the
  permissive default stub (`{:allow, 1}`) is overridden per-test to simulate an
  empty bucket, a limiter fault (fail-open), and per-(tenant, provider) isolation.
  """
  use Loopctl.DataCase, async: true

  import ExUnit.CaptureLog
  import Mox

  alias Loopctl.Provider.Admission

  @tenant_a Ecto.UUID.generate()
  @tenant_b Ecto.UUID.generate()

  test "allow bucket → :ok (a token is taken)" do
    stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window, _limit -> {:allow, 3} end)
    assert :ok = Admission.admit(@tenant_a, :embedding)
    assert :ok = Admission.admit(@tenant_a, :anthropic)
  end

  test "empty bucket → {:error, :rate_limited_local}" do
    stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window, _limit -> {:deny, 0} end)
    assert {:error, :rate_limited_local} = Admission.admit(@tenant_a, :embedding)
    assert {:error, :rate_limited_local} = Admission.admit(@tenant_a, :anthropic)
  end

  test "bucket key is scoped by tenant_id AND provider" do
    test_pid = self()

    stub(Loopctl.MockRateLimiter, :check_rate, fn bucket, _window, _limit ->
      send(test_pid, {:bucket, bucket})
      {:allow, 1}
    end)

    assert :ok = Admission.admit(@tenant_a, :embedding)
    assert :ok = Admission.admit(@tenant_a, :anthropic)
    assert :ok = Admission.admit(@tenant_b, :embedding)

    assert_received {:bucket, "provider_admission:embedding:" <> a_emb}
    assert_received {:bucket, "provider_admission:anthropic:" <> a_anth}
    assert_received {:bucket, "provider_admission:embedding:" <> b_emb}

    assert a_emb == @tenant_a
    assert a_anth == @tenant_a
    assert b_emb == @tenant_b
  end

  test "per-(tenant, provider) isolation: A empty + B full → A denied, B allowed" do
    stub(Loopctl.MockRateLimiter, :check_rate, fn
      "provider_admission:embedding:" <> tenant, _window, _limit ->
        if tenant == @tenant_a, do: {:deny, 0}, else: {:allow, 1}
    end)

    assert {:error, :rate_limited_local} = Admission.admit(@tenant_a, :embedding)
    assert :ok = Admission.admit(@tenant_b, :embedding)
  end

  test "embedding vs anthropic buckets are independent for the SAME tenant" do
    stub(Loopctl.MockRateLimiter, :check_rate, fn
      "provider_admission:embedding:" <> _tenant, _window, _limit -> {:deny, 0}
      "provider_admission:anthropic:" <> _tenant, _window, _limit -> {:allow, 1}
    end)

    assert {:error, :rate_limited_local} = Admission.admit(@tenant_a, :embedding)
    assert :ok = Admission.admit(@tenant_a, :anthropic)
  end

  test "FAIL-OPEN: a limiter error allows the call and logs a warning (AC-37.1.6)" do
    stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window, _limit ->
      raise "hammer/ets is down"
    end)

    log =
      capture_log(fn ->
        assert :ok = Admission.admit(@tenant_a, :embedding)
      end)

    assert log =~ "failing OPEN"
  end
end
