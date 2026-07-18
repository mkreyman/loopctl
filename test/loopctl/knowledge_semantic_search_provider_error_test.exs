defmodule Loopctl.KnowledgeSemanticSearchProviderErrorTest do
  @moduledoc """
  US-34.3 (review fix MED #1): `Knowledge.generate_embedding/3` emits the
  `[:loopctl, :llm, :provider_error]` telemetry event ONLY for genuine, countable
  provider incidents (a 5xx `:transient` class) and NEVER for per-tenant config
  faults (4xx credential/quota, `:no_api_key`) or the breaker's own derived
  `:circuit_open` short-circuit.

  ## Why `async: false` (deliberate, not an oversight)

  These tests attach a GLOBAL `:telemetry` handler on the VM-global event
  `[:loopctl, :llm, :provider_error]` and assert on what lands in the test
  process mailbox (`assert_received` / `refute_received`). The emitter in
  `Loopctl.LLM.record_provider_error/2` DELIBERATELY puts NO `tenant_id` (nor any
  high-cardinality id) in the event metadata — see the "NEVER `tenant_id`" note
  in `lib/loopctl/llm.ex`. Because the metadata carries no tenant, the handler
  CANNOT be tenant-scoped: the best it can do is filter on `provider:
  "embedding"` (which it does). Under `async: true` that filter is not enough —
  ANY concurrently-running test whose embedding path emits a `provider_error`
  with `provider: "embedding"` would leak a `{:provider_error_emitted, ...}`
  message into this test's mailbox and trip the `refute_received` assertions
  non-deterministically. A non-async module never runs concurrently with any
  other module (`ExUnit.Case` `:async` docs), so no cross-file embedding emitter
  is running while these listeners are attached. This mirrors how
  `test/loopctl/heavy_read_hnsw_ef_search_test.exs` documents `async: false` for
  shared VM-global state.

  Extracted from `test/loopctl/knowledge_semantic_search_test.exs` (which stays
  `async: true`) precisely so the rest of that file's semantic-search tests keep
  running concurrently.
  """
  use Loopctl.DataCase, async: false

  setup :verify_on_exit!

  alias Loopctl.Knowledge

  defp setup_tenant do
    tenant = fixture(:tenant)
    %{tenant: tenant}
  end

  describe "generate_embedding/3 - provider_error telemetry (US-34.3 review fix MED #1)" do
    defp attach_provider_error_listener(test_pid) do
      handler_id = {:generate_embedding_provider_error_test, System.unique_integer([:positive])}

      :telemetry.attach(
        handler_id,
        [:loopctl, :llm, :provider_error],
        fn
          # Forward ONLY embedding-provider events. `[:loopctl, :llm, :provider_error]`
          # is a VM-GLOBAL telemetry event, so under `async: true` a concurrent
          # Anthropic-path test emitting it with provider="anthropic" would otherwise
          # leak into this test's mailbox — failing the `assert_received`/
          # `refute_received` assertions below non-deterministically. (This module is
          # `async: false` for exactly that reason; see @moduledoc.)
          _event, measurements, %{provider: "embedding"} = metadata, _config ->
            send(test_pid, {:provider_error_emitted, measurements, metadata})

          _event, _measurements, _metadata, _config ->
            :ok
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "a genuine 5xx failure emits provider=embedding class=:transient" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      attach_provider_error_listener(self())

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 500, :provider_error}}
      end)

      assert {:error, {:api_error, 500, _}} = Knowledge.generate_embedding(tenant.id, "q")

      assert_received {:provider_error_emitted, %{count: 1}, metadata}
      assert metadata == %{provider: "embedding", class: :transient}
    end

    test "a per-tenant 4xx (credential/quota) NEVER emits provider_error (gated by breaker_countable?/1, mirrors the circuit breaker exemption)" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      attach_provider_error_listener(self())

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 401, :provider_error}}
      end)

      assert {:error, {:api_error, 401, _}} = Knowledge.generate_embedding(tenant.id, "q")

      refute_received {:provider_error_emitted, _measurements, _metadata}
    end

    test "a keyless tenant's :no_api_key never emits provider_error (a config gap, not a provider incident)" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      attach_provider_error_listener(self())

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :no_api_key}
      end)

      assert {:error, :no_api_key} = Knowledge.generate_embedding(tenant.id, "q")

      refute_received {:provider_error_emitted, _measurements, _metadata}
    end

    test "the circuit breaker's own :circuit_open short-circuit never emits provider_error (a derived, already-counted consequence)" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 500, :provider_error}}
      end)

      # Trip the breaker first (3 failures).
      for _i <- 1..3 do
        Knowledge.generate_embedding(tenant.id, "q")
      end

      attach_provider_error_listener(self())
      assert {:error, :circuit_open} = Knowledge.generate_embedding(tenant.id, "q")

      refute_received {:provider_error_emitted, _measurements, _metadata}
    end
  end
end
