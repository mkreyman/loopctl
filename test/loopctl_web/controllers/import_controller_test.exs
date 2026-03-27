defmodule LoopctlWeb.ImportControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Webhooks.WebhookEvent
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.WorkBreakdown.StoryDependency

  import Ecto.Query

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp valid_import_payload do
    %{
      "epics" => [
        %{
          "number" => 1,
          "title" => "Foundation",
          "description" => "Base infrastructure",
          "phase" => "p0_foundation",
          "position" => 0,
          "stories" => [
            %{
              "number" => "1.1",
              "title" => "Schema Setup",
              "description" => "Create base schemas",
              "acceptance_criteria" => [%{"id" => "AC-1", "description" => "Schema works"}],
              "estimated_hours" => 4
            },
            %{
              "number" => "1.2",
              "title" => "Auth Pipeline",
              "description" => "Build auth",
              "estimated_hours" => 6
            }
          ]
        },
        %{
          "number" => 2,
          "title" => "API Layer",
          "description" => "REST endpoints",
          "phase" => "p1_api",
          "position" => 1,
          "stories" => [
            %{
              "number" => "2.1",
              "title" => "Project CRUD",
              "description" => "Project endpoints",
              "estimated_hours" => 3
            },
            %{
              "number" => "2.2",
              "title" => "Story CRUD",
              "description" => "Story endpoints",
              "estimated_hours" => 5
            }
          ]
        }
      ],
      "story_dependencies" => [
        %{"story" => "2.1", "depends_on" => "1.1"}
      ]
    }
  end

  describe "POST /api/v1/projects/:id/import" do
    test "successful import with epics, stories, and dependencies", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{project.id}/import", valid_import_payload())

      body = json_response(conn, 201)
      import_result = body["import"]

      assert import_result["epics_created"] == 2
      assert import_result["stories_created"] == 4
      assert import_result["dependencies_created"] == 1

      # Verify epics exist
      epics =
        Epic
        |> where([e], e.project_id == ^project.id and e.tenant_id == ^tenant.id)
        |> AdminRepo.all()

      assert length(epics) == 2

      # Verify stories exist with correct default statuses
      stories =
        Story
        |> where([s], s.project_id == ^project.id and s.tenant_id == ^tenant.id)
        |> AdminRepo.all()

      assert length(stories) == 4
      assert Enum.all?(stories, &(&1.agent_status == :pending))
      assert Enum.all?(stories, &(&1.verified_status == :unverified))

      # Verify dependency exists
      deps =
        StoryDependency
        |> where([d], d.tenant_id == ^tenant.id)
        |> AdminRepo.all()

      assert length(deps) == 1

      # Verify audit log
      audit =
        AuditLog
        |> where([a], a.tenant_id == ^tenant.id and a.action == "imported")
        |> AdminRepo.all()

      assert length(audit) == 1
    end

    test "rolls back on validation error (blank story title)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})

      payload = %{
        "epics" => [
          %{
            "number" => 1,
            "title" => "Epic 1",
            "stories" => [
              %{"number" => "1.1", "title" => "Good Story"},
              %{"number" => "1.2", "title" => ""}
            ]
          }
        ]
      }

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{project.id}/import", payload)

      assert json_response(conn, 422)

      # Nothing was created
      assert AdminRepo.aggregate(
               from(e in Epic, where: e.project_id == ^project.id),
               :count,
               :id
             ) == 0
    end

    test "cycle detection rejects circular dependencies", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})

      payload = %{
        "epics" => [
          %{
            "number" => 1,
            "title" => "Epic 1",
            "stories" => [
              %{"number" => "1.1", "title" => "Story A"},
              %{"number" => "1.2", "title" => "Story B"},
              %{"number" => "1.3", "title" => "Story C"}
            ]
          }
        ],
        "story_dependencies" => [
          %{"story" => "1.1", "depends_on" => "1.2"},
          %{"story" => "1.2", "depends_on" => "1.3"},
          %{"story" => "1.3", "depends_on" => "1.1"}
        ]
      }

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{project.id}/import", payload)

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "Cycle detected"
    end

    test "duplicate story numbers rejected", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})

      payload = %{
        "epics" => [
          %{
            "number" => 1,
            "title" => "Epic 1",
            "stories" => [
              %{"number" => "1.1", "title" => "Story A"},
              %{"number" => "1.1", "title" => "Story B"}
            ]
          }
        ]
      }

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{project.id}/import", payload)

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "Duplicate story number"
    end

    test "tenant isolation on import", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})
      project_b = fixture(:project, %{tenant_id: tenant_b.id})

      conn =
        conn
        |> auth_conn(raw_key_a)
        |> post(~p"/api/v1/projects/#{project_b.id}/import", valid_import_payload())

      assert json_response(conn, 404)
    end

    test "webhook event emitted on successful import", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})

      fixture(:webhook, %{
        tenant_id: tenant.id,
        events: ["project.imported"],
        active: true
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{project.id}/import", valid_import_payload())

      assert json_response(conn, 201)

      events =
        WebhookEvent
        |> where([e], e.tenant_id == ^tenant.id and e.event_type == "project.imported")
        |> AdminRepo.all()

      assert length(events) == 1
      event = hd(events)
      assert event.payload["project_id"] == project.id
      assert event.payload["epic_count"] == 2
      assert event.payload["story_count"] == 4
    end

    test "dependency references non-existent story number", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})

      payload = %{
        "epics" => [
          %{
            "number" => 1,
            "title" => "Epic 1",
            "stories" => [
              %{"number" => "1.1", "title" => "Story A"}
            ]
          }
        ],
        "story_dependencies" => [
          %{"story" => "1.1", "depends_on" => "99.99"}
        ]
      }

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{project.id}/import", payload)

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "Unresolved dependency reference"
    end

    test "duplicate import without merge flag returns 409 Conflict", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})

      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.1", title: "Existing"})

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.2",
        title: "Existing 2"
      })

      payload = %{
        "epics" => [
          %{
            "number" => 1,
            "title" => "Epic 1",
            "stories" => [
              %{"number" => "1.1", "title" => "Story A"},
              %{"number" => "1.2", "title" => "Story B"}
            ]
          }
        ]
      }

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{project.id}/import", payload)

      body = json_response(conn, 409)
      assert body["error"]["status"] == 409
      assert "1.1" in body["error"]["details"]["duplicate_story_numbers"]
      assert "1.2" in body["error"]["details"]["duplicate_story_numbers"]
    end

    test "agent role cannot import", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{project.id}/import", valid_import_payload())

      assert json_response(conn, 403)
    end
  end
end
