defmodule Loopctl.OrchestratorTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Orchestrator

  describe "save_state/4" do
    test "creates new state with version=1 when none exists" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      attrs = %{
        state_key: "main",
        state_data: %{"current_epic" => 3, "completed_stories" => ["1.1", "1.2"]},
        version: 0
      }

      assert {:ok, state} = Orchestrator.save_state(tenant.id, project.id, attrs)
      assert state.state_key == "main"
      assert state.state_data == %{"current_epic" => 3, "completed_stories" => ["1.1", "1.2"]}
      assert state.version == 1
      assert state.tenant_id == tenant.id
      assert state.project_id == project.id
    end

    test "updates existing state when version matches" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      state =
        fixture(:orchestrator_state, %{
          tenant_id: tenant.id,
          project_id: project.id,
          state_key: "main",
          state_data: %{"current_epic" => 3},
          version: 5
        })

      attrs = %{
        state_key: "main",
        state_data: %{"current_epic" => 4, "completed_stories" => ["3.1"]},
        version: state.version
      }

      assert {:ok, updated} = Orchestrator.save_state(tenant.id, project.id, attrs)
      assert updated.version == 6
      assert updated.state_data == %{"current_epic" => 4, "completed_stories" => ["3.1"]}
    end

    test "returns version_conflict when version does not match" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      fixture(:orchestrator_state, %{
        tenant_id: tenant.id,
        project_id: project.id,
        state_key: "main",
        state_data: %{},
        version: 3
      })

      attrs = %{
        state_key: "main",
        state_data: %{"update" => true},
        version: 2
      }

      assert {:error, :version_conflict} = Orchestrator.save_state(tenant.id, project.id, attrs)
    end

    test "returns version_conflict when creating with non-zero version and no existing state" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      attrs = %{state_key: "main", state_data: %{"data" => true}, version: 5}

      assert {:error, :version_conflict} = Orchestrator.save_state(tenant.id, project.id, attrs)
    end

    test "returns not_found for non-existent project" do
      tenant = fixture(:tenant)
      fake_project_id = uuid()

      attrs = %{state_key: "main", state_data: %{}, version: 0}

      assert {:error, :not_found} =
               Orchestrator.save_state(tenant.id, fake_project_id, attrs)
    end

    test "returns changeset error for missing state_key" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      attrs = %{state_key: nil, state_data: %{"data" => true}, version: 0}

      assert {:error, %Ecto.Changeset{}} =
               Orchestrator.save_state(tenant.id, project.id, attrs)
    end

    test "stores and retrieves large state_data faithfully" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      large_data = %{
        "epics" => Enum.map(1..100, &%{"id" => &1, "status" => "done"}),
        "nested" => %{"deep" => %{"deeper" => %{"value" => 42}}},
        "mixed" => [1, "two", true, nil, 3.14]
      }

      attrs = %{state_key: "main", state_data: large_data, version: 0}

      assert {:ok, state} = Orchestrator.save_state(tenant.id, project.id, attrs)
      assert {:ok, retrieved} = Orchestrator.get_state(tenant.id, project.id, "main")
      assert retrieved.state_data == large_data
      assert state.id == retrieved.id
    end

    test "creates audit log entry on save" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      actor_id = uuid()

      attrs = %{state_key: "main", state_data: %{"step" => 1}, version: 0}

      assert {:ok, state} =
               Orchestrator.save_state(tenant.id, project.id, attrs,
                 actor_id: actor_id,
                 actor_label: "orchestrator:test"
               )

      {:ok, %{data: entries}} =
        Loopctl.Audit.list_entries(tenant.id,
          entity_type: "orchestrator_state",
          entity_id: state.id
        )

      assert length(entries) == 1
      [entry] = entries
      assert entry.action == "saved"
      assert entry.actor_id == actor_id
      assert entry.new_state["version"] == 1
      assert entry.new_state["state_data"] == %{"step" => 1}
    end

    test "concurrent writes: one wins, one gets version_conflict" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      fixture(:orchestrator_state, %{
        tenant_id: tenant.id,
        project_id: project.id,
        state_key: "main",
        state_data: %{"initial" => true},
        version: 1
      })

      task1 =
        Task.async(fn ->
          Orchestrator.save_state(tenant.id, project.id, %{
            state_key: "main",
            state_data: %{"writer" => 1},
            version: 1
          })
        end)

      task2 =
        Task.async(fn ->
          Orchestrator.save_state(tenant.id, project.id, %{
            state_key: "main",
            state_data: %{"writer" => 2},
            version: 1
          })
        end)

      results = [Task.await(task1), Task.await(task2)]

      successes = Enum.filter(results, &match?({:ok, _}, &1))
      failures = Enum.filter(results, &match?({:error, :version_conflict}, &1))

      assert length(successes) == 1
      assert length(failures) == 1

      [{:ok, winner}] = successes
      assert winner.version == 2
    end

    test "tenant isolation: cannot save state for another tenant's project" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_a = fixture(:project, %{tenant_id: tenant_a.id})

      attrs = %{state_key: "main", state_data: %{"hack" => true}, version: 0}

      assert {:error, :not_found} =
               Orchestrator.save_state(tenant_b.id, project_a.id, attrs)
    end
  end

  describe "get_state/3" do
    test "retrieves state by project and state_key" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      fixture(:orchestrator_state, %{
        tenant_id: tenant.id,
        project_id: project.id,
        state_key: "main",
        state_data: %{"epic" => 5},
        version: 10
      })

      fixture(:orchestrator_state, %{
        tenant_id: tenant.id,
        project_id: project.id,
        state_key: "backup",
        state_data: %{"epic" => 4},
        version: 8
      })

      assert {:ok, main_state} = Orchestrator.get_state(tenant.id, project.id, "main")
      assert main_state.state_data == %{"epic" => 5}
      assert main_state.version == 10

      assert {:ok, backup_state} = Orchestrator.get_state(tenant.id, project.id, "backup")
      assert backup_state.state_data == %{"epic" => 4}
      assert backup_state.version == 8
    end

    test "defaults to 'main' state_key when not provided" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      fixture(:orchestrator_state, %{
        tenant_id: tenant.id,
        project_id: project.id,
        state_key: "main",
        state_data: %{"default" => true}
      })

      assert {:ok, state} = Orchestrator.get_state(tenant.id, project.id)
      assert state.state_key == "main"
      assert state.state_data == %{"default" => true}
    end

    test "returns not_found for non-existent state" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      assert {:error, :not_found} = Orchestrator.get_state(tenant.id, project.id, "main")
    end

    test "returns not_found for non-existent project" do
      tenant = fixture(:tenant)

      assert {:error, :not_found} = Orchestrator.get_state(tenant.id, uuid(), "main")
    end

    test "tenant isolation: cannot read another tenant's state" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_a = fixture(:project, %{tenant_id: tenant_a.id})

      fixture(:orchestrator_state, %{
        tenant_id: tenant_a.id,
        project_id: project_a.id,
        state_key: "main"
      })

      assert {:error, :not_found} = Orchestrator.get_state(tenant_b.id, project_a.id, "main")
    end
  end

  describe "get_state_history/3" do
    test "returns history from audit log entries" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      # Save state 3 times to create audit entries
      attrs1 = %{state_key: "main", state_data: %{"step" => 1}, version: 0}
      assert {:ok, _} = Orchestrator.save_state(tenant.id, project.id, attrs1)

      attrs2 = %{state_key: "main", state_data: %{"step" => 2}, version: 1}
      assert {:ok, _} = Orchestrator.save_state(tenant.id, project.id, attrs2)

      attrs3 = %{state_key: "main", state_data: %{"step" => 3}, version: 2}
      assert {:ok, _} = Orchestrator.save_state(tenant.id, project.id, attrs3)

      assert {:ok, %{data: history, total: 3}} =
               Orchestrator.get_state_history(tenant.id, project.id, state_key: "main")

      assert length(history) == 3

      # Most recent first
      [h3, h2, h1] = history
      assert h3.version == 3
      assert h3.state_data == %{"step" => 3}
      assert h2.version == 2
      assert h2.state_data == %{"step" => 2}
      assert h1.version == 1
      assert h1.state_data == %{"step" => 1}
    end

    test "filters by state_key" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      # Save to "main" twice
      assert {:ok, _} =
               Orchestrator.save_state(tenant.id, project.id, %{
                 state_key: "main",
                 state_data: %{"m" => 1},
                 version: 0
               })

      assert {:ok, _} =
               Orchestrator.save_state(tenant.id, project.id, %{
                 state_key: "main",
                 state_data: %{"m" => 2},
                 version: 1
               })

      # Save to "backup" once
      assert {:ok, _} =
               Orchestrator.save_state(tenant.id, project.id, %{
                 state_key: "backup",
                 state_data: %{"b" => 1},
                 version: 0
               })

      assert {:ok, %{data: main_history, total: 2}} =
               Orchestrator.get_state_history(tenant.id, project.id, state_key: "main")

      assert {:ok, %{data: backup_history, total: 1}} =
               Orchestrator.get_state_history(tenant.id, project.id, state_key: "backup")

      assert length(main_history) == 2
      assert length(backup_history) == 1
    end

    test "returns empty list for project with no state history" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      assert {:ok, %{data: [], total: 0}} =
               Orchestrator.get_state_history(tenant.id, project.id, state_key: "main")
    end

    test "returns not_found for non-existent project" do
      tenant = fixture(:tenant)

      assert {:error, :not_found} =
               Orchestrator.get_state_history(tenant.id, uuid(), state_key: "main")
    end

    test "supports pagination" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      # Save state 5 times
      for i <- 0..4 do
        assert {:ok, _} =
                 Orchestrator.save_state(tenant.id, project.id, %{
                   state_key: "main",
                   state_data: %{"step" => i + 1},
                   version: i
                 })
      end

      assert {:ok, %{data: page1, total: 5, page: 1, page_size: 2}} =
               Orchestrator.get_state_history(tenant.id, project.id,
                 state_key: "main",
                 page: 1,
                 page_size: 2
               )

      assert length(page1) == 2
      # Most recent first
      assert Enum.at(page1, 0).version == 5
      assert Enum.at(page1, 1).version == 4

      assert {:ok, %{data: page2}} =
               Orchestrator.get_state_history(tenant.id, project.id,
                 state_key: "main",
                 page: 2,
                 page_size: 2
               )

      assert length(page2) == 2
      assert Enum.at(page2, 0).version == 3
      assert Enum.at(page2, 1).version == 2

      assert {:ok, %{data: page3}} =
               Orchestrator.get_state_history(tenant.id, project.id,
                 state_key: "main",
                 page: 3,
                 page_size: 2
               )

      assert length(page3) == 1
      assert Enum.at(page3, 0).version == 1
    end
  end
end
