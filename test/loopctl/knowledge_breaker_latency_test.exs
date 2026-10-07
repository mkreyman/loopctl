defmodule Loopctl.KnowledgeBreakerLatencyTest do
  @moduledoc """
  US-37.3 (TC-37.3.4): the latency-based breaker trip (slow-but-alive protection).

  The latency threshold / count / base cooldown are `SystemConfig` knobs. Each test seeds
  them in its OWN `SystemConfig` namespace and hands that namespace to
  `Knowledge.generate_embedding/3` as `:system_config`, so the node-wide knobs every other
  test reads (threshold 0 = latency trip DISABLED) never move.
  """
  use Loopctl.DataCase, async: true

  import Mox

  setup :verify_on_exit!

  alias Loopctl.Knowledge

  @threshold_key "embedding_breaker_latency_threshold_ms"
  @count_key "embedding_breaker_latency_count"
  @cooldown_key "embedding_breaker_cooldown_seconds"

  setup do
    # A SystemConfig namespace of this test's own: an ETS table this test process owns,
    # gone when it exits.
    cache = :ets.new(:breaker_latency_config, [:set, :public])

    # Enable a low latency threshold, trip after 2 slow calls, recover after 1s.
    :ets.insert(cache, [{@threshold_key, 40}, {@count_key, 2}, {@cooldown_key, 1}])

    {:ok, opts: [system_config: cache], cache: cache}
  end

  test "slow-but-successful calls trip the breaker on latency, then recover after cooldown",
       %{opts: opts} do
    tenant = fixture(:tenant)
    Knowledge.reset_circuit_breaker(tenant.id)

    # A SUCCESSFUL but SLOW embed (over the 40ms threshold). The call still returns
    # {:ok, _}; the breaker trips as a side effect of the slow-window count.
    Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
      Process.sleep(60)
      {:ok, List.duplicate(0.1, 1536)}
    end)

    # Two slow successes reach the latency count (2) and trip the breaker.
    assert {:ok, _} = Knowledge.generate_embedding(tenant.id, "x", opts)
    assert {:ok, _} = Knowledge.generate_embedding(tenant.id, "x", opts)

    # Breaker now OPEN: short-circuits to :circuit_open WITHOUT calling the (slow)
    # client — the fail-safe against a slow-but-alive provider.
    assert {:error, :circuit_open} = Knowledge.generate_embedding(tenant.id, "x", opts)

    # Recover: after the 1s cooldown the breaker clears on the next probe and the
    # call proceeds again (a single slow success is below the count-2 trip).
    Process.sleep(1_100)
    assert {:ok, _} = Knowledge.generate_embedding(tenant.id, "x", opts)
  end

  test "disabled-safe: threshold 0 means a slow success never trips (just clears state)",
       %{opts: opts, cache: cache} do
    tenant = fixture(:tenant)
    Knowledge.reset_circuit_breaker(tenant.id)
    :ets.insert(cache, {@threshold_key, 0})

    Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
      Process.sleep(60)
      {:ok, List.duplicate(0.1, 1536)}
    end)

    # Many slow successes — with the trip disabled the breaker NEVER opens.
    results = for _ <- 1..5, do: Knowledge.generate_embedding(tenant.id, "x", opts)
    assert Enum.all?(results, &match?({:ok, _}, &1))
  end
end
