defmodule LoopctlWeb.StoryByProjectControllerTest do
  @moduledoc """
  Tests for GET /api/v1/stories?project_id=X (Issue 1 — project-scoped story listing).
  """
  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "GET /api/v1/stories?project_id=X" do
    test "returns stories for the given project", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.1"})
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.2"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories?project_id=#{project.id}")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert body["meta"]["total_count"] == 2
      assert body["meta"]["limit"] == 100
      assert body["meta"]["offset"] == 0
    end

    test "returns 400 when project_id is missing", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/stories")

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "project_id"
    end

    test "filters by agent_status", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.1",
        agent_status: :pending
      })

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.2",
        agent_status: :implementing
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories?project_id=#{project.id}&agent_status=pending")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert hd(body["data"])["agent_status"] == "pending"
    end

    test "filters by verified_status", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.1",
        verified_status: :unverified
      })

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.2",
        verified_status: :verified
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories?project_id=#{project.id}&verified_status=verified")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert hd(body["data"])["verified_status"] == "verified"
    end

    test "filters by epic_id", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic1 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      epic2 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      fixture(:story, %{tenant_id: tenant.id, epic_id: epic1.id, number: "1.1"})
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic2.id, number: "2.1"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories?project_id=#{project.id}&epic_id=#{epic1.id}")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert hd(body["data"])["epic_id"] == epic1.id
    end

    test "respects limit and offset pagination", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      for i <- 1..5 do
        fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.#{i}"})
      end

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories?project_id=#{project.id}&limit=2&offset=0")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert body["meta"]["total_count"] == 5
      assert body["meta"]["limit"] == 2
      assert body["meta"]["offset"] == 0
    end

    test "offset skips records", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      for i <- 1..4 do
        fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.#{i}"})
      end

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories?project_id=#{project.id}&limit=2&offset=2")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert body["meta"]["total_count"] == 4
      assert body["meta"]["offset"] == 2
    end

    test "returns empty list for project with no stories", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories?project_id=#{project.id}")

      body = json_response(conn, 200)
      assert body["data"] == []
      assert body["meta"]["total_count"] == 0
    end

    test "does not return stories from another tenant's project", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})

      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      epic_b = fixture(:epic, %{tenant_id: tenant_b.id, project_id: project_b.id})
      fixture(:story, %{tenant_id: tenant_b.id, epic_id: epic_b.id})

      conn =
        conn
        |> auth_conn(key_a)
        |> get(~p"/api/v1/stories?project_id=#{project_b.id}")

      body = json_response(conn, 200)
      assert body["data"] == []
      assert body["meta"]["total_count"] == 0
    end

    test "requires agent or higher role", %{conn: conn} do
      # User role should be allowed (role: :agent is >= :agent)
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories?project_id=#{project.id}")

      # user role has :agent capability, should succeed
      assert json_response(conn, 200)
    end
  end

  # TC-52.9.1 (US-52.9): the e2e harness finds the story its issue produced.
  describe "GET /api/v1/stories?project_id=X&issue_number=N" do
    setup do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      linked = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.1"})
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.2"})
      link!(linked, tenant.id, project.id, 41)

      %{tenant: tenant, raw_key: raw_key, project: project, linked: linked}
    end

    test "returns only the stories intake issue N produced", ctx do
      body = index(ctx.conn, ctx.raw_key, "project_id=#{ctx.project.id}&issue_number=41")

      assert [%{"id" => id}] = body["data"]
      assert id == ctx.linked.id
      assert body["meta"]["total_count"] == 1
    end

    test "an issue number no intake record carries returns nothing", ctx do
      body = index(ctx.conn, ctx.raw_key, "project_id=#{ctx.project.id}&issue_number=42")
      assert body["data"] == []
    end

    test "another tenant's record with the same issue number is not seen", ctx do
      other = fixture(:tenant)
      {other_key, _} = fixture(:api_key, %{tenant_id: other.id, role: :agent})
      other_project = fixture(:project, %{tenant_id: other.id})
      other_epic = fixture(:epic, %{tenant_id: other.id, project_id: other_project.id})
      theirs = fixture(:story, %{tenant_id: other.id, epic_id: other_epic.id, number: "1.1"})
      link!(theirs, other.id, other_project.id, 41)

      mine = index(ctx.conn, ctx.raw_key, "project_id=#{ctx.project.id}&issue_number=41")
      assert Enum.map(mine["data"], & &1["id"]) == [ctx.linked.id]

      # The other tenant's key cannot read this tenant's project at all.
      crossed = index(build_conn(), other_key, "project_id=#{ctx.project.id}&issue_number=41")
      assert crossed["data"] == []
    end

    for bad <- ["0", "-3", "abc", "4.5"] do
      test "issue_number=#{bad} is a 400", ctx do
        conn =
          ctx.conn
          |> auth_conn(ctx.raw_key)
          |> get("/api/v1/stories?project_id=#{ctx.project.id}&issue_number=#{unquote(bad)}")

        assert json_response(conn, 400)["error"]["message"] =~ "issue_number"
      end
    end

    defp index(conn, raw_key, query) do
      conn |> auth_conn(raw_key) |> get("/api/v1/stories?#{query}") |> json_response(200)
    end

    defp link!(story, tenant_id, project_id, issue_number) do
      {_source, record} =
        fixture(:intake_pair, %{
          tenant_id: tenant_id,
          project_id: project_id,
          issue_number: issue_number,
          repo_full_name: "mkreyman/sandbox-#{System.unique_integer([:positive])}"
        })

      Loopctl.AdminRepo.update_all(
        from(s in Loopctl.WorkBreakdown.Story, where: s.id == ^story.id),
        set: [intake_record_id: record.id]
      )
    end
  end
end
