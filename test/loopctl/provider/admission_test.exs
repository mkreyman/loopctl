defmodule Loopctl.Provider.AdmissionTest do
  @moduledoc """
  Per-(tenant, provider) node-local fixed-window admission gate (US-37.1, #352).

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

  test "FAIL-OPEN: a raised limiter exception allows the call and logs a warning (AC-37.1.6)" do
    stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window, _limit ->
      raise "hammer/ets is down"
    end)

    log =
      capture_log(fn ->
        assert :ok = Admission.admit(@tenant_a, :embedding)
      end)

    assert log =~ "failing OPEN"
  end

  test "FAIL-OPEN: a limiter EXIT (e.g. :noproc from a down poolboy pool) allows the call (AC-37.1.6)" do
    # Hammer reaches its backend via :poolboy.transaction/3 -> gen_server:call,
    # which EXITS (does not raise) with :noproc when the pool is down/unstarted
    # and {:timeout, _} on checkout timeout. `rescue` MISSES exits — only the
    # `catch :exit` clause keeps the gate failing open here.
    stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window, _limit ->
      exit(:noproc)
    end)

    log =
      capture_log(fn ->
        assert :ok = Admission.admit(@tenant_a, :embedding)
      end)

    assert log =~ "failing OPEN"
    assert log =~ "limiter exit"
  end

  test "FAIL-OPEN: a limiter checkout-timeout EXIT allows the call (AC-37.1.6)" do
    stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window, _limit ->
      exit({:timeout, {:gen_server, :call, [:hammer_pool, :checkout]}})
    end)

    log =
      capture_log(fn ->
        assert :ok = Admission.admit(@tenant_a, :anthropic)
      end)

    assert log =~ "failing OPEN"
    assert log =~ "limiter exit"
  end

  test "FAIL-OPEN: a limiter THROW allows the call (AC-37.1.6)" do
    stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window, _limit ->
      throw(:boom)
    end)

    log =
      capture_log(fn ->
        assert :ok = Admission.admit(@tenant_a, :embedding)
      end)

    assert log =~ "failing OPEN"
    assert log =~ "limiter throw"
  end

  test "FAIL-OPEN: Hammer's documented {:error, reason} return allows the call via an explicit clause (AC-37.1.6)" do
    # {:error, reason} is a documented Hammer.check_rate/3 return (its ETS
    # count_hit can fail). It must be handled by the explicit case clause — not
    # fall through to a CaseClauseError accidentally caught by `rescue`.
    stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window, _limit ->
      {:error, :ets_table_gone}
    end)

    log =
      capture_log(fn ->
        assert :ok = Admission.admit(@tenant_a, :embedding)
      end)

    assert log =~ "failing OPEN"
    assert log =~ "ets_table_gone"
  end

  test "snooze_seconds/0 returns a jittered, positive duration (single source for all workers)" do
    # Default base is 5s with a 0..5s jitter, so every result is in 5..10.
    results = for _ <- 1..50, do: Admission.snooze_seconds()

    assert Enum.all?(results, &(is_integer(&1) and &1 >= 5 and &1 <= 10))
    # Jitter means we should see more than one distinct value across 50 draws.
    assert results |> Enum.uniq() |> length() > 1
  end

  test "snooze_seconds/0 clamps a misconfigured base of 0 to a positive duration (pos_integer @spec)" do
    # An operator can set the live knob to 0 (or negative). Without the max(1, base)
    # clamp, `base + :rand.uniform(6) - 1` would range 0..5, and a {:snooze, 0} is an
    # immediate re-run against a still-shut gate (a tight snooze/re-check loop). The
    # clamp guarantees >= 1. We set the persistent_term cache directly (the documented
    # SystemConfig key format) rather than SystemConfig.put/2 to avoid a leaked DB row,
    # and erase it on exit; intra-file tests run serially so the default is restored
    # before the next test, and any concurrent cross-file reader is itself protected by
    # the same clamp (>= 1).
    pt_key = {Loopctl.SystemConfig, "provider_admission_snooze_seconds"}
    :persistent_term.put(pt_key, 0)
    on_exit(fn -> :persistent_term.erase(pt_key) end)

    results = for _ <- 1..50, do: Admission.snooze_seconds()

    # max(1, 0) + (0..5) => 1..6, and crucially NEVER 0.
    assert Enum.all?(results, &(is_integer(&1) and &1 >= 1 and &1 <= 6))
    refute Enum.any?(results, &(&1 <= 0))
  end

  test "snooze_seconds/0 clamps a negative base to a positive duration (pos_integer @spec)" do
    pt_key = {Loopctl.SystemConfig, "provider_admission_snooze_seconds"}
    :persistent_term.put(pt_key, -100)
    on_exit(fn -> :persistent_term.erase(pt_key) end)

    results = for _ <- 1..50, do: Admission.snooze_seconds()

    # max(1, -100) + (0..5) => 1..6.
    assert Enum.all?(results, &(is_integer(&1) and &1 >= 1 and &1 <= 6))
  end
end
