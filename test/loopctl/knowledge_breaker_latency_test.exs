defmodule Loopctl.KnowledgeBreakerLatencyTest do
  @moduledoc """
  US-37.3 (TC-37.3.4): the latency-based breaker trip (slow-but-alive protection).

  `async: false` ON PURPOSE. The latency threshold / count / base cooldown are
  NODE-GLOBAL SystemConfig knobs read from `:persistent_term`; this test seeds them
  directly (the documented key format, NO leaked DB row — mirrors
  `Loopctl.Provider.AdmissionTest`) and erases them on exit. A sync test never runs
  concurrently with any other test, so the global seed can't leak into async peers,
  and the default (threshold 0 = latency trip DISABLED) is restored afterward.
  """
  use Loopctl.DataCase, async: false

  import Mox

  setup :verify_on_exit!

  alias Loopctl.Knowledge

  @threshold_key {Loopctl.SystemConfig, "embedding_breaker_latency_threshold_ms"}
  @count_key {Loopctl.SystemConfig, "embedding_breaker_latency_count"}
  @cooldown_key {Loopctl.SystemConfig, "embedding_breaker_cooldown_seconds"}

  setup do
    # Enable a low latency threshold, trip after 2 slow calls, recover after 1s.
    :persistent_term.put(@threshold_key, 40)
    :persistent_term.put(@count_key, 2)
    :persistent_term.put(@cooldown_key, 1)

    on_exit(fn ->
      :persistent_term.erase(@threshold_key)
      :persistent_term.erase(@count_key)
      :persistent_term.erase(@cooldown_key)
    end)

    :ok
  end

  test "slow-but-successful calls trip the breaker on latency, then recover after cooldown" do
    tenant = fixture(:tenant)
    Knowledge.reset_circuit_breaker(tenant.id)

    # A SUCCESSFUL but SLOW embed (over the 40ms threshold). The call still returns
    # {:ok, _}; the breaker trips as a side effect of the slow-window count.
    Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
      Process.sleep(60)
      {:ok, List.duplicate(0.1, 1536)}
    end)

    # Two slow successes reach the latency count (2) and trip the breaker.
    assert {:ok, _} = Knowledge.generate_embedding(tenant.id, "x")
    assert {:ok, _} = Knowledge.generate_embedding(tenant.id, "x")

    # Breaker now OPEN: short-circuits to :circuit_open WITHOUT calling the (slow)
    # client — the fail-safe against a slow-but-alive provider.
    assert {:error, :circuit_open} = Knowledge.generate_embedding(tenant.id, "x")

    # Recover: after the 1s cooldown the breaker clears on the next probe and the
    # call proceeds again (a single slow success is below the count-2 trip).
    Process.sleep(1_100)
    assert {:ok, _} = Knowledge.generate_embedding(tenant.id, "x")
  end

  test "disabled-safe: threshold 0 means a slow success never trips (just clears state)" do
    tenant = fixture(:tenant)
    Knowledge.reset_circuit_breaker(tenant.id)
    :persistent_term.put(@threshold_key, 0)

    Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
      Process.sleep(60)
      {:ok, List.duplicate(0.1, 1536)}
    end)

    # Many slow successes — with the trip disabled the breaker NEVER opens.
    results = for _ <- 1..5, do: Knowledge.generate_embedding(tenant.id, "x")
    assert Enum.all?(results, &match?({:ok, _}, &1))
  end
end
