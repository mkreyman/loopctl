defmodule LoopctlWeb.WellKnownCapabilitiesTest do
  @moduledoc "TC-41.4.12 — instance capabilities are discoverable PRE-AUTH."

  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.Egress
  alias Loopctl.Egress.PinCache

  test "GET /.well-known/loopctl publishes capabilities with NO credentials", %{conn: conn} do
    # Deliberately no authorization header — an agent discovering loopctl cold
    # must be able to learn the instance's constraints BEFORE authenticating.
    body =
      conn
      |> delete_req_header("authorization")
      |> get(~p"/.well-known/loopctl")
      |> json_response(200)

    caps = body["capabilities"]

    assert caps["supported_embedding_dimensions"] == [1536]
    assert caps["tenant_supplied_endpoints_permitted"] == true
    assert "local_only" in caps["tiers"]
    assert caps["egress_posture_endpoint"] =~ "/api/v1/egress/posture"
    # Guarantee wording is narrowed to exactly what the chokepoint check proves.
    assert caps["egress_guarantee"] =~ "loopctl application code"
  end

  test "no tenant-specific data leaks into the discovery document", %{conn: conn} do
    tenant = fixture(:tenant)
    {:ok, _} = Egress.enable_local_only(tenant.id, nil, acknowledge: true)
    on_exit(fn -> PinCache.invalidate_tenant(tenant.id) end)

    {:ok, _} =
      Egress.declare_trusted_endpoint(tenant.id, %{
        "host" => "ollama.example.com",
        "purposes" => ["inference"]
      })

    raw = conn |> get(~p"/.well-known/loopctl") |> response(200)

    refute raw =~ tenant.id
    refute raw =~ "ollama.example.com"
    refute raw =~ "declared_endpoints"
    refute raw =~ "deployment_allowlist"
  end

  test "the published JSON Schema documents the capabilities object", %{conn: conn} do
    schema = conn |> get(~p"/.well-known/loopctl/schema.json") |> json_response(200)
    caps = schema["properties"]["capabilities"]

    assert caps["type"] == "object"
    assert "supported_embedding_dimensions" in caps["required"]
    assert "tenant_supplied_endpoints_permitted" in caps["required"]
    assert "tiers" in caps["required"]
  end
end
