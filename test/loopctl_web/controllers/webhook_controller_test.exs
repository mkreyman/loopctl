defmodule LoopctlWeb.WebhookControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  # --- Create tests ---

  describe "POST /api/v1/webhooks" do
    test "creates a webhook with valid data", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/webhooks", %{
          "url" => "https://example.com/hooks",
          "events" => ["story.status_changed", "story.verified"]
        })

      body = json_response(conn, 201)
      webhook = body["webhook"]

      assert webhook["url"] == "https://example.com/hooks"
      assert webhook["events"] == ["story.status_changed", "story.verified"]
      assert webhook["active"] == true
      assert is_binary(webhook["signing_secret"])
      assert String.length(webhook["signing_secret"]) == 64
      assert is_binary(webhook["id"])
    end

    test "rejects invalid event types with 422", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/webhooks", %{
          "url" => "https://example.com/hooks",
          "events" => ["invalid.event"]
        })

      assert json_response(conn, 422)
    end

    test "enforces max webhook limit", %{conn: conn} do
      tenant = fixture(:tenant, %{settings: %{"max_webhooks" => 1}})
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      fixture(:webhook, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/webhooks", %{
          "url" => "https://example.com/hooks",
          "events" => ["story.status_changed"]
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "limit"
    end

    test "agent role cannot create webhooks", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/webhooks", %{
          "url" => "https://example.com/hooks",
          "events" => ["story.status_changed"]
        })

      assert json_response(conn, 403)
    end

    test "orchestrator role cannot create webhooks", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/webhooks", %{
          "url" => "https://example.com/hooks",
          "events" => ["story.status_changed"]
        })

      assert json_response(conn, 403)
    end
  end

  # --- List tests ---

  describe "GET /api/v1/webhooks" do
    test "lists webhooks for the tenant", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      fixture(:webhook, %{tenant_id: tenant.id})
      fixture(:webhook, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/webhooks")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert body["meta"]["total_count"] == 2

      # Ensure signing_secret is NOT returned
      webhook = List.first(body["data"])
      refute Map.has_key?(webhook, "signing_secret")
      refute Map.has_key?(webhook, "signing_secret_encrypted")
    end

    test "returns empty list for tenant with no webhooks", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/webhooks")

      body = json_response(conn, 200)
      assert body["data"] == []
      assert body["meta"]["total_count"] == 0
    end

    test "does not return other tenant's webhooks", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})
      fixture(:webhook, %{tenant_id: tenant_b.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/webhooks")

      body = json_response(conn, 200)
      assert body["data"] == []
    end
  end

  # --- Update tests ---

  describe "PATCH /api/v1/webhooks/:id" do
    test "updates webhook fields", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      webhook = fixture(:webhook, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/webhooks/#{webhook.id}", %{
          "url" => "https://new.example.com/hooks",
          "events" => ["story.verified", "story.rejected"],
          "active" => false
        })

      body = json_response(conn, 200)
      updated = body["webhook"]

      assert updated["url"] == "https://new.example.com/hooks"
      assert updated["events"] == ["story.verified", "story.rejected"]
      assert updated["active"] == false
      refute Map.has_key?(updated, "signing_secret")
    end

    test "reactivation resets consecutive_failures", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      webhook =
        fixture(:webhook, %{
          tenant_id: tenant.id,
          active: false,
          consecutive_failures: 10
        })

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/webhooks/#{webhook.id}", %{"active" => true})

      body = json_response(conn, 200)
      assert body["webhook"]["active"] == true
      assert body["webhook"]["consecutive_failures"] == 0
    end

    test "returns 404 for other tenant's webhook", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})
      webhook = fixture(:webhook, %{tenant_id: tenant_b.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/webhooks/#{webhook.id}", %{"active" => false})

      assert json_response(conn, 404)
    end
  end

  # --- Delete tests ---

  describe "DELETE /api/v1/webhooks/:id" do
    test "deletes a webhook", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      webhook = fixture(:webhook, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> delete(~p"/api/v1/webhooks/#{webhook.id}")

      assert response(conn, 204)
    end

    test "returns 404 for other tenant's webhook", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})
      webhook = fixture(:webhook, %{tenant_id: tenant_b.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> delete(~p"/api/v1/webhooks/#{webhook.id}")

      assert json_response(conn, 404)
    end
  end

  # --- Test endpoint tests ---

  describe "POST /api/v1/webhooks/:id/test" do
    test "creates and enqueues a test event", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      webhook = fixture(:webhook, %{tenant_id: tenant.id})

      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn_req ->
        Req.Test.json(conn_req, %{"ok" => true})
      end)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/webhooks/#{webhook.id}/test")

      body = json_response(conn, 200)
      assert is_binary(body["webhook_event_id"])
      assert body["status"] == "pending"
    end

    test "works on inactive webhook", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      webhook = fixture(:webhook, %{tenant_id: tenant.id, active: false})

      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn_req ->
        Req.Test.json(conn_req, %{"ok" => true})
      end)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/webhooks/#{webhook.id}/test")

      assert json_response(conn, 200)
    end

    test "returns 404 for other tenant's webhook", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})
      webhook = fixture(:webhook, %{tenant_id: tenant_b.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/webhooks/#{webhook.id}/test")

      assert json_response(conn, 404)
    end
  end

  # --- Deliveries endpoint tests ---

  describe "GET /api/v1/webhooks/:id/deliveries" do
    test "lists delivery attempts for a webhook", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      webhook = fixture(:webhook, %{tenant_id: tenant.id})

      fixture(:webhook_event, %{
        tenant_id: tenant.id,
        webhook_id: webhook.id,
        status: :delivered
      })

      fixture(:webhook_event, %{
        tenant_id: tenant.id,
        webhook_id: webhook.id,
        status: :failed
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/webhooks/#{webhook.id}/deliveries")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert body["meta"]["total_count"] == 2

      # Verify payload is NOT included in response
      delivery = List.first(body["data"])
      refute Map.has_key?(delivery, "payload")
      assert Map.has_key?(delivery, "id")
      assert Map.has_key?(delivery, "event_type")
      assert Map.has_key?(delivery, "status")
      assert Map.has_key?(delivery, "attempts")
    end

    test "returns 404 for other tenant's webhook", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})
      webhook = fixture(:webhook, %{tenant_id: tenant_b.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/webhooks/#{webhook.id}/deliveries")

      assert json_response(conn, 404)
    end
  end
end
