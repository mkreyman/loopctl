defmodule LoopctlWeb.LlmUsageControllerTest do
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.Llm

  defp auth_conn(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp record(tenant_id, attrs) do
    {:ok, _} =
      Llm.record_usage(
        tenant_id,
        Map.merge(
          %{operation: :extraction, model: "haiku", input_tokens: 10, output_tokens: 5},
          attrs
        )
      )
  end

  describe "GET /api/v1/knowledge/llm-usage" do
    test "returns the tenant's usage summary (role orchestrator)", %{conn: conn} do
      tenant = fixture(:tenant)
      record(tenant.id, %{model: "haiku", input_tokens: 100, output_tokens: 40})
      record(tenant.id, %{model: "haiku", input_tokens: 50, output_tokens: 10})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/llm-usage")
        |> json_response(200)

      assert [row] = body["data"]
      assert row["operation"] == "extraction"
      assert row["model"] == "haiku"
      assert row["input_tokens"] == 150
      assert row["output_tokens"] == 50
      assert row["event_count"] == 2
      assert body["meta"]["total_count"] == 1
    end

    test "an agent role is rejected with 403", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/llm-usage")

      assert json_response(conn, 403)
    end

    test "paginates via limit/offset with meta", %{conn: conn} do
      tenant = fixture(:tenant)
      for model <- ["m-a", "m-b", "m-c"], do: record(tenant.id, %{model: model})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      page1 =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/llm-usage?limit=2&offset=0")
        |> json_response(200)

      assert length(page1["data"]) == 2
      assert page1["meta"]["total_count"] == 3
      assert page1["meta"]["limit"] == 2
    end

    test "is tenant-isolated (A never sees B's usage)", %{conn: conn} do
      a = fixture(:tenant)
      b = fixture(:tenant)
      record(b.id, %{model: "b-only", input_tokens: 999, output_tokens: 999})
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: a.id, role: :orchestrator})

      body =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/knowledge/llm-usage")
        |> json_response(200)

      assert body["data"] == []
      refute inspect(body) =~ "b-only"
    end
  end
end
