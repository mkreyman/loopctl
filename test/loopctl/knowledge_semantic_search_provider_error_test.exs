defmodule Loopctl.KnowledgeSemanticSearchProviderErrorTest do
  @moduledoc """
  US-34.3 (review fix MED #1): `Knowledge.generate_embedding/3` emits the
  `[:loopctl, :llm, :provider_error]` telemetry event ONLY for genuine, countable
  provider incidents (a 5xx `:transient` class) and NEVER for per-tenant config
  faults (4xx credential/quota, `:no_api_key`) or the breaker's own derived
  `:circuit_open` short-circuit.

  The listener is `Loopctl.TelemetryHelpers.attach_own/1`. The emitter in
  `Loopctl.Llm.record_provider_error/2` deliberately carries no `tenant_id` (see the
  "NEVER `tenant_id`" note in `lib/loopctl/llm.ex`), so the handler cannot filter on the
  tenant; it filters on the EMITTING process instead — this test's own, or a task it started —
  so a concurrent test's `provider_error` never reaches this mailbox.

  Extracted from `test/loopctl/knowledge_semantic_search_test.exs` (which stays
  `async: true`) precisely so the rest of that file's semantic-search tests keep
  running concurrently.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge

  defp setup_tenant do
    tenant = fixture(:tenant)
    %{tenant: tenant}
  end

  describe "generate_embedding/3 - provider_error telemetry (US-34.3 review fix MED #1)" do
    @event [:loopctl, :llm, :provider_error]

    defp attach_provider_error_listener do
      Loopctl.TelemetryHelpers.attach_own([@event])
    end

    test "a genuine 5xx failure emits provider=embedding class=:transient" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      ref = attach_provider_error_listener()

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 500, :provider_error}}
      end)

      assert {:error, {:api_error, 500, _}} = Knowledge.generate_embedding(tenant.id, "q")

      assert_received {@event, ^ref, %{count: 1}, metadata}
      assert metadata == %{provider: "embedding", class: :transient}
    end

    test "a per-tenant 4xx (credential/quota) NEVER emits provider_error (gated by breaker_countable?/1, mirrors the circuit breaker exemption)" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      ref = attach_provider_error_listener()

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 401, :provider_error}}
      end)

      assert {:error, {:api_error, 401, _}} = Knowledge.generate_embedding(tenant.id, "q")

      refute_received {@event, ^ref, _measurements, _metadata}
    end

    test "a keyless tenant's :no_api_key never emits provider_error (a config gap, not a provider incident)" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      ref = attach_provider_error_listener()

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :no_api_key}
      end)

      assert {:error, :no_api_key} = Knowledge.generate_embedding(tenant.id, "q")

      refute_received {@event, ^ref, _measurements, _metadata}
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

      ref = attach_provider_error_listener()
      assert {:error, :circuit_open} = Knowledge.generate_embedding(tenant.id, "q")

      refute_received {@event, ^ref, _measurements, _metadata}
    end
  end
end
