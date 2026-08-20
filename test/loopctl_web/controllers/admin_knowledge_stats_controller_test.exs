defmodule LoopctlWeb.AdminKnowledgeStatsControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.RetrievalMetricSnapshot

  @day ~D[2026-08-18]

  defp auth_conn(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp snapshot_for(tenant_id, attrs) do
    %RetrievalMetricSnapshot{tenant_id: tenant_id}
    |> RetrievalMetricSnapshot.changeset(
      Enum.into(attrs, %{
        day: @day,
        window_seconds: 1800,
        searched: 0,
        followed_through: 0,
        precision: 0.0,
        computed_at: DateTime.utc_now()
      })
    )
    |> AdminRepo.insert!()
  end

  describe "GET /api/v1/admin/knowledge/retrieval-metrics" do
    test "returns one row per tenant with no cross-tenant aggregate", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      big = fixture(:tenant, %{name: "AAA Big Corpus", status: :active})
      small = fixture(:tenant, %{name: "BBB Small Corpus", status: :active})

      snapshot_for(big.id, searched: 1000, followed_through: 40, precision: 0.04)
      snapshot_for(small.id, searched: 10, followed_through: 4, precision: 0.4)

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/knowledge/retrieval-metrics?day=2026-08-18")
        |> json_response(200)

      rows = body["data"]
      by_id = Map.new(rows, &{&1["tenant_id"], &1})

      assert by_id[big.id]["snapshot"]["precision"] == 0.04
      assert by_id[small.id]["snapshot"]["precision"] == 0.4

      assert body["meta"]["aggregation"] == "none"

      refute Map.has_key?(body["meta"], "precision"),
             "blending a 4% rate over a large corpus with 40% over a tiny one is not a " <>
               "fact about either, and it hides the account being looked for"
    end

    test "a tenant with no snapshot appears with a null snapshot", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})
      silent = fixture(:tenant, %{name: "ZZZ Silent", status: :active})

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/knowledge/retrieval-metrics?day=2026-08-18")
        |> json_response(200)

      row = Enum.find(body["data"], &(&1["tenant_id"] == silent.id))

      assert row, "a KB nobody queried is a finding; dropping the row hides it"
      assert row["snapshot"] == nil
    end

    test "403s every role below superadmin", %{conn: conn} do
      tenant = fixture(:tenant)

      for role <- [:agent, :orchestrator, :user] do
        {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: role})

        assert conn
               |> auth_conn(raw_key)
               |> get(~p"/api/v1/admin/knowledge/retrieval-metrics")
               |> json_response(403),
               "cross-tenant reads are a superadmin capability; #{role} must not see " <>
                 "another tenant's KB figures"
      end
    end

    test "400s a malformed day rather than silently returning the default", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      assert conn
             |> auth_conn(raw_key)
             |> get(~p"/api/v1/admin/knowledge/retrieval-metrics?day=last-tuesday")
             |> json_response(400)
    end

    test "400s a malformed window_seconds rather than falling back", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      assert conn
             |> auth_conn(raw_key)
             |> get(~p"/api/v1/admin/knowledge/retrieval-metrics?window_seconds=soon")
             |> json_response(400),
             "a silently-ignored window returns the DEFAULT window's rows under an " <>
               "explicit non-default request"
    end
  end
end
