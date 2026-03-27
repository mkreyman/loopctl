defmodule LoopctlWeb.SkillControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "POST /api/v1/skills" do
    test "creates a skill with initial version", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/skills", %{
          "name" => "loopctl:review",
          "description" => "Enhanced review",
          "prompt_text" => "Review all code carefully..."
        })

      body = json_response(conn, 201)
      assert body["skill"]["name"] == "loopctl:review"
      assert body["version"]["version"] == 1
      assert body["version"]["prompt_text"] == "Review all code carefully..."
    end

    test "agent cannot create skills", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/skills", %{
          "name" => "test-skill",
          "prompt_text" => "test"
        })

      assert json_response(conn, 403)
    end
  end

  describe "GET /api/v1/skills" do
    test "lists skills for tenant", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      fixture(:skill, %{tenant_id: tenant.id, name: "skill-a"})
      fixture(:skill, %{tenant_id: tenant.id, name: "skill-b"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/skills")

      body = json_response(conn, 200)
      assert body["meta"]["total_count"] == 2
      assert length(body["data"]) == 2
    end
  end

  describe "GET /api/v1/skills/:id" do
    test "returns skill with current prompt", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      skill = fixture(:skill, %{tenant_id: tenant.id, prompt_text: "My prompt"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/skills/#{skill.id}")

      body = json_response(conn, 200)
      assert body["skill"]["name"] == skill.name
      assert body["current_prompt"] == "My prompt"
    end

    test "returns 404 for wrong tenant", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :user})
      skill = fixture(:skill, %{tenant_id: tenant_a.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/skills/#{skill.id}")

      assert json_response(conn, 404)
    end
  end

  describe "PATCH /api/v1/skills/:id" do
    test "updates skill metadata", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      skill = fixture(:skill, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/skills/#{skill.id}", %{
          "description" => "Updated description"
        })

      body = json_response(conn, 200)
      assert body["skill"]["description"] == "Updated description"
    end
  end

  describe "DELETE /api/v1/skills/:id" do
    test "archives a skill", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      skill = fixture(:skill, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> delete(~p"/api/v1/skills/#{skill.id}")

      body = json_response(conn, 200)
      assert body["skill"]["status"] == "archived"
    end
  end

  describe "POST /api/v1/skills/:id/versions" do
    test "creates a new version", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      skill = fixture(:skill, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/skills/#{skill.id}/versions", %{
          "prompt_text" => "Updated prompt v2",
          "changelog" => "Improved instructions"
        })

      body = json_response(conn, 201)
      assert body["skill"]["current_version"] == 2
      assert body["version"]["version"] == 2
      assert body["version"]["prompt_text"] == "Updated prompt v2"
    end
  end

  describe "GET /api/v1/skills/:id/versions" do
    test "lists all versions", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      skill = fixture(:skill, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/skills/#{skill.id}/versions")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert hd(body["data"])["version"] == 1
    end
  end

  describe "GET /api/v1/skills/:id/versions/:version" do
    test "returns specific version with prompt_text", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      skill = fixture(:skill, %{tenant_id: tenant.id, prompt_text: "V1 prompt"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/skills/#{skill.id}/versions/1")

      body = json_response(conn, 200)
      assert body["version"]["version"] == 1
      assert body["version"]["prompt_text"] == "V1 prompt"
    end
  end
end
