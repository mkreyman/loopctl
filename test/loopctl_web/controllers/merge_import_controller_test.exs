defmodule LoopctlWeb.MergeImportControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.WorkBreakdown.Story

  import Ecto.Query

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "POST /api/v1/projects/:id/import?merge=true" do
    test "merge creates new stories and updates existing ones", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.1",
        title: "Original Title",
        description: "Original desc",
        agent_status: :implementing
      })

      payload = %{
        "epics" => [
          %{
            "number" => 1,
            "title" => "Updated Epic",
            "stories" => [
              %{"number" => "1.1", "title" => "Updated Title", "description" => "Updated desc"},
              %{"number" => "1.2", "title" => "New Story"}
            ]
          }
        ]
      }

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{project.id}/import?merge=true", payload)

      body = json_response(conn, 200)
      import_result = body["import"]

      assert import_result["stories_updated"] == 1
      assert import_result["stories_created"] == 1
      assert import_result["epics_updated"] == 1

      # Verify story 1.1 was updated
      updated =
        Story
        |> where([s], s.tenant_id == ^tenant.id and s.number == "1.1")
        |> AdminRepo.one()

      assert updated.title == "Updated Title"
      # Status preserved
      assert updated.agent_status == :implementing

      # Verify story 1.2 was created
      new_story =
        Story
        |> where([s], s.tenant_id == ^tenant.id and s.number == "1.2")
        |> AdminRepo.one()

      assert new_story.title == "New Story"
      assert new_story.agent_status == :pending
    end

    test "merge preserves all status fields on existing stories", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      agent = fixture(:agent, %{tenant_id: tenant.id})

      story =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          number: "1.1",
          agent_status: :reported_done,
          verified_status: :verified
        })

      # Set verified_at and assigned_agent_id
      story
      |> Ecto.Changeset.change(%{
        assigned_agent_id: agent.id,
        verified_at: ~U[2026-03-15 10:00:00.000000Z]
      })
      |> AdminRepo.update!()

      payload = %{
        "epics" => [
          %{
            "number" => 1,
            "title" => "Epic",
            "stories" => [
              %{"number" => "1.1", "title" => "Updated desc only", "description" => "New desc"}
            ]
          }
        ]
      }

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{project.id}/import?merge=true", payload)

      assert json_response(conn, 200)

      reloaded =
        Story
        |> where([s], s.id == ^story.id)
        |> AdminRepo.one()

      assert reloaded.agent_status == :reported_done
      assert reloaded.verified_status == :verified
      assert reloaded.assigned_agent_id == agent.id
      assert reloaded.verified_at == ~U[2026-03-15 10:00:00.000000Z]
    end

    test "orphaned stories flagged but not deleted", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})

      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.1", title: "Story One"})

      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.2", title: "Story Two"})

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.3",
        title: "Story Three"
      })

      # Import only 1.1 and 1.2 -- 1.3 should be orphaned
      payload = %{
        "epics" => [
          %{
            "number" => 1,
            "title" => "Epic",
            "stories" => [
              %{"number" => "1.1", "title" => "Story One Updated"},
              %{"number" => "1.2", "title" => "Story Two Updated"}
            ]
          }
        ]
      }

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{project.id}/import?merge=true", payload)

      body = json_response(conn, 200)
      orphaned = body["import"]["stories_orphaned"]

      assert length(orphaned) == 1
      assert hd(orphaned)["number"] == "1.3"
      assert hd(orphaned)["title"] == "Story Three"

      # Story 1.3 still exists
      assert AdminRepo.exists?(
               from(s in Story, where: s.number == "1.3" and s.tenant_id == ^tenant.id)
             )
    end

    test "merge with new epic creates it with all stories", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})

      fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1, title: "Existing"})

      payload = %{
        "epics" => [
          %{
            "number" => 1,
            "title" => "Existing Updated",
            "stories" => []
          },
          %{
            "number" => 2,
            "title" => "New Epic",
            "stories" => [
              %{"number" => "2.1", "title" => "New S1"},
              %{"number" => "2.2", "title" => "New S2"},
              %{"number" => "2.3", "title" => "New S3"}
            ]
          }
        ]
      }

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{project.id}/import?merge=true", payload)

      body = json_response(conn, 200)
      assert body["import"]["epics_created"] == 1
      assert body["import"]["epics_updated"] == 1
      assert body["import"]["stories_created"] == 3
    end

    test "merge detects cycles in combined dependency graph", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})

      s1 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.1"})
      s2 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.2"})

      # Existing dependency: 1.2 depends on 1.1
      fixture(:story_dependency, %{
        tenant_id: tenant.id,
        story_id: s2.id,
        depends_on_story_id: s1.id
      })

      # Now try to add: 1.1 depends on 1.2 (creates cycle)
      payload = %{
        "epics" => [
          %{
            "number" => 1,
            "title" => "Epic",
            "stories" => [
              %{"number" => "1.1", "title" => "S1"},
              %{"number" => "1.2", "title" => "S2"}
            ]
          }
        ],
        "story_dependencies" => [
          %{"story" => "1.1", "depends_on" => "1.2"}
        ]
      }

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{project.id}/import?merge=true", payload)

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "Cycle detected"
    end

    test "merge rollback on failure", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.1",
        title: "Original"
      })

      # Update 1.1 and add invalid new story
      payload = %{
        "epics" => [
          %{
            "number" => 1,
            "title" => "Epic",
            "stories" => [
              %{"number" => "1.1", "title" => "Updated"},
              %{"number" => "1.2", "title" => ""}
            ]
          }
        ]
      }

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{project.id}/import?merge=true", payload)

      assert json_response(conn, 422)

      # Story 1.1 should still be "Original" (rolled back)
      story =
        Story
        |> where([s], s.number == "1.1" and s.tenant_id == ^tenant.id)
        |> AdminRepo.one()

      assert story.title == "Original"
    end

    test "merge import with absent field preserves existing value", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.1",
        title: "Original Title",
        acceptance_criteria: [%{"desc" => "Original AC"}],
        estimated_hours: 5
      })

      # Only update title, omit acceptance_criteria and estimated_hours
      payload = %{
        "epics" => [
          %{
            "number" => 1,
            "title" => "Epic",
            "stories" => [
              %{"number" => "1.1", "title" => "Updated Title"}
            ]
          }
        ]
      }

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{project.id}/import?merge=true", payload)

      assert json_response(conn, 200)

      story =
        Story
        |> where([s], s.number == "1.1" and s.tenant_id == ^tenant.id)
        |> AdminRepo.one()

      assert story.title == "Updated Title"
      assert story.acceptance_criteria == [%{"desc" => "Original AC"}]
      assert Decimal.equal?(story.estimated_hours, Decimal.new(5))
    end

    test "cross-tenant isolation on merge import", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})
      project_b = fixture(:project, %{tenant_id: tenant_b.id})

      payload = %{
        "epics" => [
          %{"number" => 1, "title" => "E1", "stories" => []}
        ]
      }

      conn =
        conn
        |> auth_conn(raw_key_a)
        |> post(~p"/api/v1/projects/#{project_b.id}/import?merge=true", payload)

      assert json_response(conn, 404)
    end
  end
end
