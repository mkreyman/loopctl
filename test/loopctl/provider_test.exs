defmodule Loopctl.ProviderTest do
  @moduledoc """
  US-41.4 — the single egress chokepoint: refusal happens BEFORE any request
  (AC-41.4.3, TC-41.4.1), the guard survives admission fail-open (TC-41.4.3),
  blocked calls emit the replacement metric and never a provider-error signal
  (AC-41.4.6, TC-41.4.10/.15), and the pinned path is used when allowed
  (AC-41.4.12).

  `async: false` (flake fix): the "emits NO provider-error storm signal" test does a
  `refute_receive` on `[:loopctl, :llm, :provider_error]`, which is a VM-GLOBAL
  telemetry event with no tenant in its metadata — a concurrent embedding-path test
  emitting it with `provider: "embedding"` is indistinguishable from a leak here and
  fails this assertion intermittently. Filtering at the handler cannot separate them
  (this test's own path would carry the same provider tag), so the only sound fix is
  the same one `Loopctl.Llm.AnthropicTest` already uses: no concurrent emitter at
  all. ExUnit runs sync files alone, after the async ones.
  """

  use Loopctl.DataCase, async: false

  import Mox

  alias Loopctl.Egress
  alias Loopctl.Egress.PinCache
  alias Loopctl.Egress.Scope
  alias Loopctl.Provider
  alias Loopctl.Provider.Admission
  alias Loopctl.Test.AllowlistSource

  import Loopctl.TelemetryHelpers, only: [receive_matching: 3]

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant)
    on_exit(fn -> PinCache.invalidate_tenant(tenant.id) end)
    {:ok, tenant: tenant, scope: Scope.new(tenant.id)}
  end

  # A Req plug that FAILS the test if it is ever reached. This is how "nothing was
  # sent" is proven: a blocked call must never build, let alone issue, a request.
  defp never_called_plug do
    test_pid = self()

    fn conn ->
      send(test_pid, :request_was_sent)
      Req.Test.json(conn, %{"data" => []})
    end
  end

  describe "refusal happens BEFORE the request (AC-41.4.3)" do
    test "a local_only scope on a vendor endpoint is refused and NOTHING is sent",
         %{tenant: t, scope: scope} do
      {:ok, _} = Egress.enable_local_only(t.id, nil, acknowledge: true)
      PinCache.invalidate_tenant(t.id)

      assert {:error, {:egress_blocked, _details}} =
               Provider.post(
                 "https://api.openai.com/v1/embeddings",
                 [plug: never_called_plug()],
                 %{
                   scope: scope,
                   purpose: :inference
                 }
               )

      refute_received :request_was_sent
    end

    test "an unmarked scope is completely unaffected (default-off)", %{scope: scope} do
      assert {:ok, %{status: 200}} =
               Provider.post(
                 "https://api.openai.com/v1/embeddings",
                 [plug: fn conn -> Req.Test.json(conn, %{"ok" => true}) end],
                 %{scope: scope}
               )
    end

    test "an allowlisted local endpoint is allowed and PINNED", %{tenant: t, scope: scope} do
      {:ok, _} = Egress.enable_local_only(t.id, nil, acknowledge: true)
      PinCache.invalidate_tenant(t.id)
      AllowlistSource.put(["127.0.0.1"])
      on_exit(&AllowlistSource.clear/0)

      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:host_header, Plug.Conn.get_req_header(conn, "host")})
        Req.Test.json(conn, %{"ok" => true})
      end

      assert {:ok, %{status: 200}} =
               Provider.post("http://127.0.0.1:11434/v1/embeddings", [plug: plug], %{scope: scope})

      assert_received {:host_header, _}
    end
  end

  describe "the guard survives admission fail-open (AC-41.4.4, TC-41.4.3)" do
    test "an admission gate that fails OPEN still cannot leak past the egress guard",
         %{tenant: t, scope: scope} do
      {:ok, _} = Egress.enable_local_only(t.id, nil, acknowledge: true)
      PinCache.invalidate_tenant(t.id)

      # Admission's limiter is unavailable — it EXITS, which `fail_open/2` catches
      # and turns into `:ok` (allow). That must not touch the privacy decision.
      stub(Loopctl.MockRateLimiter, :check_rate, fn _, _, _ -> exit(:noproc) end)
      assert :ok = Admission.admit(t.id, :embedding)

      assert {:error, {:egress_blocked, _details}} =
               Provider.post(
                 "https://api.openai.com/v1/embeddings",
                 [plug: never_called_plug()],
                 %{
                   scope: scope
                 }
               )

      refute_received :request_was_sent
    end
  end

  describe "observability of a refusal (AC-41.4.6)" do
    setup %{tenant: t} do
      {:ok, _} = Egress.enable_local_only(t.id, nil, acknowledge: true)
      PinCache.invalidate_tenant(t.id)
      :ok
    end

    test "emits [:loopctl, :egress, :blocked] with the endpoint host and reason",
         %{tenant: t, scope: scope} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:loopctl, :egress, :blocked]])

      assert {:error, {:egress_blocked, _details}} =
               Provider.post("https://api.openai.com/v1/embeddings", [], %{scope: scope})

      # RECEIVE-UNTIL-MATCH: the telemetry handler is GLOBAL, so a concurrent test's
      # blocked event under the same ref must be skipped, not asserted on.
      {measurements, metadata} =
        receive_matching([:loopctl, :egress, :blocked], ref, &(&1.tenant_id == t.id))

      assert measurements.count == 1
      assert metadata.endpoint_host == "api.openai.com"
      assert metadata.reason == "non_local"
    end

    test "emits NO provider-error storm signal", %{scope: scope} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:loopctl, :llm, :provider_error]])

      assert {:error, {:egress_blocked, _details}} =
               Provider.post("https://api.openai.com/v1/embeddings", [], %{scope: scope})

      refute_receive {[:loopctl, :llm, :provider_error], ^ref, _, _}
    end

    test "N refusals in one window write a BOUNDED, aggregated audit trail",
         %{tenant: t, scope: scope} do
      for _ <- 1..30 do
        assert {:error, {:egress_blocked, _details}} =
                 Provider.post("https://api.openai.com/v1/embeddings", [], %{scope: scope})
      end

      # AC-41.4.6: the WRITE is buffered too, not just the row count — 30 refusals
      # produce ONE upsert carrying the accumulated delta, not 30 row-lock
      # round-trips on the 3-connection AdminRepo pool.
      :ok = Egress.flush_blocked_decisions(t.id)

      rows = Egress.list_blocked_decisions(t.id)
      assert length(rows) == 1
      assert hd(rows).occurrence_count == 30
    end
  end
end
