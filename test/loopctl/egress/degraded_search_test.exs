defmodule Loopctl.Egress.DegradedSearchTest do
  @moduledoc """
  US-41.4 — the INTERACTIVE degradation path, end to end (TC-41.4.10, TC-41.4.11).

  Everything here drives the REAL `Loopctl.Knowledge.EmbeddingClient` (the mock is
  stubbed to delegate to it) so the refusal comes from the actual
  `Loopctl.Provider` chokepoint rather than from a hand-written
  `{:error, :egress_blocked}`. That distinction is the whole point: the unit tests
  already cover the fallback wiring; what has to be proven here is that a
  `local_only` tenant's search still returns a legible HTTP 200 instead of a 500 or
  a bare empty list, that the breaker stays CLOSED, and that no provider-error
  storm signal is emitted for what is a local configuration decision.

  `async: false`: the provider-error assertion below is a `refute_received` on
  `[:loopctl, :llm, :provider_error]`, a VM-GLOBAL telemetry event whose metadata
  carries no tenant — a concurrent embedding test emitting it is indistinguishable
  from a leak here. Same reasoning (and same remedy) as `Loopctl.ProviderTest` and
  `Loopctl.Llm.AnthropicTest`.
  """

  use LoopctlWeb.ConnCase, async: false

  import Mox

  alias Loopctl.Egress
  alias Loopctl.Egress.PinCache
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.EmbeddingClient
  alias Loopctl.Llm

  setup :verify_on_exit!

  setup %{conn: conn} do
    tenant = fixture(:tenant)
    {raw, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

    # A key MUST be configured: mandatory BYO short-circuits with :no_api_key BEFORE
    # the egress guard, which would make this test pass for the wrong reason.
    {:ok, _} =
      Llm.upsert_settings(tenant.id, %{
        "embedding_api_key" => "test-openai-key-EGRESS",
        "embedding_model" => "text-embedding-3-small"
      })

    Knowledge.reset_circuit_breaker(tenant.id)
    on_exit(fn -> PinCache.invalidate_tenant(tenant.id) end)

    # Delegate the injected mock to the REAL client so the refusal is produced by the
    # chokepoint, not by the stub.
    stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn scope, text ->
      EmbeddingClient.generate_embedding(scope, text)
    end)

    # If the guard leaked, this Req.Test stub would fire and the assertion below
    # (`refute_received :unexpected_http_call`) would fail — proof that NO data left
    # the process.
    test_pid = self()

    Req.Test.stub(EmbeddingClient, fn conn ->
      send(test_pid, :unexpected_http_call)
      Req.Test.json(conn, %{"data" => [%{"index" => 0, "embedding" => [0.0]}]})
    end)

    {:ok, _} = Egress.enable_local_only(tenant.id, nil, acknowledge: true)
    PinCache.invalidate_tenant(tenant.id)

    {:ok, conn: put_req_header(conn, "authorization", "Bearer #{raw}"), tenant: tenant}
  end

  defp seed_article(tenant) do
    fixture(:article, %{
      tenant_id: tenant.id,
      title: "Postgres advisory locks",
      body: "Advisory locks coordinate concurrent workers across nodes.",
      status: "published"
    })
  end

  describe "interactive search degrades legibly on an egress_blocked scope (TC-41.4.10)" do
    test "HTTP 200 with keyword results, never a 500 and never a bare empty list",
         %{conn: conn, tenant: tenant} do
      seed_article(tenant)

      body =
        conn
        |> get(~p"/api/v1/knowledge/search", %{"q" => "advisory locks"})
        |> json_response(200)

      assert body["meta"]["fallback"] == true
      assert body["meta"]["search_mode"] == "keyword_only"
      assert body["meta"]["fallback_reason"] == "egress_blocked"
      # The keyword tier still answered — the degradation is a NARROWING, not an outage.
      refute body["data"] == []
      refute_received :unexpected_http_call
    end

    test "no [:loopctl, :llm, :provider_error] telemetry is emitted, and the breaker stays CLOSED",
         %{conn: conn, tenant: tenant} do
      seed_article(tenant)

      ref = :telemetry_test.attach_event_handlers(self(), [[:loopctl, :llm, :provider_error]])
      on_exit(fn -> :telemetry.detach(ref) end)

      # Well past the breaker's failure threshold: if an egress refusal counted, the
      # breaker would open and the reason would flip to "embedding_circuit_open".
      for _i <- 1..6 do
        assert conn
               |> get(~p"/api/v1/knowledge/search", %{"q" => "advisory locks"})
               |> json_response(200)
      end

      refute_received {[:loopctl, :llm, :provider_error], ^ref, _measurements, _metadata}

      # Breaker closed: the reason is STILL the egress refusal, not circuit_open.
      assert {:error, {:egress_blocked, _}} =
               Knowledge.generate_embedding(tenant.id, "advisory locks")

      refute_received :unexpected_http_call
    end
  end

  describe "the degraded meta contract (AC-41.4.7, TC-41.4.11)" do
    test "meta names the reason AND the offending endpoint, and carries an EMPTY excluded_tiers",
         %{conn: conn, tenant: tenant} do
      seed_article(tenant)

      meta =
        conn
        |> get(~p"/api/v1/knowledge/search", %{"q" => "advisory locks"})
        |> json_response(200)
        |> Map.fetch!("meta")

      assert meta["degraded"] == true
      assert meta["fallback_reason"] == "egress_blocked"

      # An agent cannot act on the bare reason — the endpoint has to be NAMED.
      assert meta["offending_endpoint"] =~ "api.openai.com"

      # Reserved and extensible: present, and EMPTY until US-41.6 populates it.
      assert meta["excluded_tiers"] == []
    end

    # REGRESSION (review): `Knowledge` got the degraded contract but `Memory.recall/2`
    # did not — its own `fallback_reason_tag/1` had no `:egress_blocked` clause, so
    # `ProviderError.sanitize/1`'s catch-all passed the term through to the generic
    # "embedding_error". A memory recall against a blocked scope therefore reported
    # NO egress reason, NO offending endpoint, NO degraded flag and NO excluded_tiers
    # — the agent-illegible outcome AC-41.4.7 exists to prevent. This story is the one
    # that threaded the scope through the memory path, so the memory half is in scope.
    test "the MEMORY half carries the identical degraded contract (AC-41.4.7)",
         %{tenant: tenant} do
      scope = %Loopctl.Memory.Scope{
        tenant_id: tenant.id,
        subject_id: Ecto.UUID.generate()
      }

      %{meta: meta} = Loopctl.Memory.recall(scope, query: "advisory locks", limit: 5)

      assert meta.fallback == true
      assert meta.reason == "egress_blocked"
      assert meta.degraded == true
      assert meta.offending_endpoint =~ "api.openai.com"
      assert meta.excluded_tiers == []

      refute_received :unexpected_http_call
    end

    test "the remediation is agent-actionable and names the role-:agent posture tool",
         %{conn: conn, tenant: tenant} do
      seed_article(tenant)

      meta =
        conn
        |> get(~p"/api/v1/knowledge/search", %{"q" => "advisory locks"})
        |> json_response(200)
        |> Map.fetch!("meta")

      assert meta["remediation"]["action"] == "egress_posture"
      assert meta["remediation"]["title"] =~ "local_only"
      # The wording is a contract, not prose: a declaration is never sold as local.
      assert meta["remediation"]["detail"] =~ "unverified attestation"
      # Never leak key material into a remediation string.
      refute meta["remediation"]["detail"] =~ "test-openai-key"
    end
  end
end
