defmodule LoopctlWeb.KnowledgeConsolidationControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Consolidation

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp published(tenant_id, attrs) do
    attrs =
      Map.merge(%{body: "Body #{System.unique_integer([:positive])}.", category: :pattern}, attrs)

    fixture(:article, Map.put(attrs, :tenant_id, tenant_id))
    |> Ecto.Changeset.change(%{status: :published})
    |> AdminRepo.update!()
  end

  describe "GET /api/v1/knowledge/consolidation" do
    test "returns the persisted report with numbered, evidence-carrying proposals",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      published(tenant.id, %{title: "Untitled Document", body: "Needs a real title."})
      {:ok, _} = Consolidation.run(tenant.id)

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/consolidation")
        |> json_response(200)

      assert body["data"]["corpus_size"] == 1
      assert body["data"]["proposal_count"] == 1
      assert body["data"]["persisted_count"] == 1
      assert body["data"]["proposals_by_class"]["generic_title"] == 1
      assert body["meta"]["total_count"] == 1
      # Stage 1 applies nothing.
      assert body["meta"]["applied"] == false

      assert [proposal] = body["data"]["proposals"]
      assert proposal["number"] == 1
      assert proposal["class"] == "generic_title"
      assert proposal["review_status"] == "pending"
      assert [evidence] = proposal["evidence"]
      assert evidence["excerpt"] =~ "Needs a real title"
    end

    test "returns an empty payload when the tenant has no report yet", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/consolidation")
        |> json_response(200)

      assert body["data"] == nil
      assert body["meta"]["report_available"] == false
      assert body["meta"]["total_count"] == 0
    end

    test "filters proposals by class", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      published(tenant.id, %{title: "Untitled Document"})
      published(tenant.id, %{title: "Retry Policy"})
      published(tenant.id, %{title: "retry policy"})
      {:ok, _} = Consolidation.run(tenant.id)

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/consolidation?class=generic_title")
        |> json_response(200)

      assert body["meta"]["total_count"] == 1
      assert [%{"class" => "generic_title"}] = body["data"]["proposals"]
    end

    test "400s on an unknown class", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn
      |> auth_conn(raw_key)
      |> get(~p"/api/v1/knowledge/consolidation?class=not_a_class")
      |> json_response(400)
    end

    test "400s on a malformed day", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn
      |> auth_conn(raw_key)
      |> get(~p"/api/v1/knowledge/consolidation?day=yesterday")
      |> json_response(400)
    end

    test "403s an agent key (reads on this surface are orchestrator+)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn
      |> auth_conn(raw_key)
      |> get(~p"/api/v1/knowledge/consolidation")
      |> json_response(403)
    end

    test "never exposes another tenant's report", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :orchestrator})

      published(tenant_b.id, %{title: "Untitled Document", body: "B only."})
      {:ok, _} = Consolidation.run(tenant_b.id)

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/consolidation")
        |> json_response(200)

      assert body["data"] == nil
      assert body["meta"]["report_available"] == false
    end

    # The endpoint documents offset as clamped, never rejected; unclamped it reached
    # Postgrex as an out-of-bigint-range integer and 500'd.
    test "clamps an absurd offset instead of 500ing", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      published(tenant.id, %{title: "Untitled Document", body: "Needs a real title."})
      {:ok, _} = Consolidation.run(tenant.id)

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/consolidation?offset=99999999999999999999")
        |> json_response(200)

      assert body["data"]["proposals"] == []
      assert body["meta"]["total_count"] == 1
    end

    test "redacts the evidence of an article deleted after the report was written",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      article = published(tenant.id, %{title: "Untitled Document", body: "SECRET material."})
      {:ok, _} = Consolidation.run(tenant.id)

      AdminRepo.delete!(article)

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/consolidation")
        |> json_response(200)

      assert [proposal] = body["data"]["proposals"]
      assert [evidence] = proposal["evidence"]
      assert evidence["redacted"] == true
      assert evidence["excerpt"] == ""
      refute body |> Jason.encode!() |> String.contains?("SECRET material")
    end
  end
end
