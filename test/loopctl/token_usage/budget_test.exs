defmodule Loopctl.TokenUsage.BudgetTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.TokenUsage
  alias Loopctl.TokenUsage.Budget

  setup :verify_on_exit!

  defp setup_project do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

    story =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        project_id: project.id
      })

    %{tenant: tenant, project: project, epic: epic, story: story}
  end

  # --- create_budget/3 ---

  describe "create_budget/3" do
    test "creates a budget for a story scope" do
      %{tenant: tenant, story: story} = setup_project()

      attrs = %{
        scope_type: :story,
        scope_id: story.id,
        budget_millicents: 500_000
      }

      assert {:ok, %Budget{} = budget} = TokenUsage.create_budget(tenant.id, attrs)
      assert budget.tenant_id == tenant.id
      assert budget.scope_type == :story
      assert budget.scope_id == story.id
      assert budget.budget_millicents == 500_000
      assert budget.alert_threshold_pct == 80
    end

    test "creates a budget for an epic scope" do
      %{tenant: tenant, epic: epic} = setup_project()

      attrs = %{
        scope_type: :epic,
        scope_id: epic.id,
        budget_millicents: 2_000_000
      }

      assert {:ok, %Budget{} = budget} = TokenUsage.create_budget(tenant.id, attrs)
      assert budget.scope_type == :epic
      assert budget.scope_id == epic.id
    end

    test "creates a budget for a project scope" do
      %{tenant: tenant, project: project} = setup_project()

      attrs = %{
        scope_type: :project,
        scope_id: project.id,
        budget_millicents: 10_000_000
      }

      assert {:ok, %Budget{} = budget} = TokenUsage.create_budget(tenant.id, attrs)
      assert budget.scope_type == :project
      assert budget.scope_id == project.id
    end

    test "accepts optional budget_input_tokens and budget_output_tokens" do
      %{tenant: tenant, story: story} = setup_project()

      attrs = %{
        scope_type: :story,
        scope_id: story.id,
        budget_millicents: 500_000,
        budget_input_tokens: 100_000,
        budget_output_tokens: 50_000
      }

      assert {:ok, budget} = TokenUsage.create_budget(tenant.id, attrs)
      assert budget.budget_input_tokens == 100_000
      assert budget.budget_output_tokens == 50_000
    end

    test "accepts custom alert_threshold_pct" do
      %{tenant: tenant, story: story} = setup_project()

      attrs = %{
        scope_type: :story,
        scope_id: story.id,
        budget_millicents: 500_000,
        alert_threshold_pct: 90
      }

      assert {:ok, budget} = TokenUsage.create_budget(tenant.id, attrs)
      assert budget.alert_threshold_pct == 90
    end

    test "accepts metadata" do
      %{tenant: tenant, story: story} = setup_project()

      attrs = %{
        scope_type: :story,
        scope_id: story.id,
        budget_millicents: 500_000,
        metadata: %{"reason" => "hotfix budget"}
      }

      assert {:ok, budget} = TokenUsage.create_budget(tenant.id, attrs)
      assert budget.metadata == %{"reason" => "hotfix budget"}
    end

    test "returns :conflict when budget already exists for scope" do
      %{tenant: tenant, story: story} = setup_project()

      attrs = %{
        scope_type: :story,
        scope_id: story.id,
        budget_millicents: 500_000
      }

      assert {:ok, _} = TokenUsage.create_budget(tenant.id, attrs)
      assert {:error, :conflict} = TokenUsage.create_budget(tenant.id, attrs)
    end

    test "returns :not_found when scope entity does not exist" do
      tenant = fixture(:tenant)

      attrs = %{
        scope_type: :story,
        scope_id: Ecto.UUID.generate(),
        budget_millicents: 500_000
      }

      assert {:error, :not_found} = TokenUsage.create_budget(tenant.id, attrs)
    end

    test "returns error when budget_millicents is zero" do
      %{tenant: tenant, story: story} = setup_project()

      attrs = %{
        scope_type: :story,
        scope_id: story.id,
        budget_millicents: 0
      }

      assert {:error, changeset} = TokenUsage.create_budget(tenant.id, attrs)
      assert errors_on(changeset).budget_millicents != []
    end

    test "returns error when budget_millicents is missing" do
      %{tenant: tenant, story: story} = setup_project()

      attrs = %{
        scope_type: :story,
        scope_id: story.id
      }

      assert {:error, changeset} = TokenUsage.create_budget(tenant.id, attrs)
      assert errors_on(changeset).budget_millicents != []
    end

    test "returns error when alert_threshold_pct is out of range" do
      %{tenant: tenant, story: story} = setup_project()

      attrs = %{
        scope_type: :story,
        scope_id: story.id,
        budget_millicents: 500_000,
        alert_threshold_pct: 101
      }

      assert {:error, changeset} = TokenUsage.create_budget(tenant.id, attrs)
      assert errors_on(changeset).alert_threshold_pct != []
    end

    test "creates an audit log entry" do
      %{tenant: tenant, story: story} = setup_project()

      attrs = %{
        scope_type: :story,
        scope_id: story.id,
        budget_millicents: 500_000
      }

      {:ok, budget} =
        TokenUsage.create_budget(tenant.id, attrs, actor_id: Ecto.UUID.generate())

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id,
          entity_type: "token_budget",
          entity_id: budget.id,
          action: "created"
        )

      assert length(result.data) == 1
      audit = hd(result.data)
      assert audit.entity_type == "token_budget"
      assert audit.action == "created"
      assert audit.new_state["budget_millicents"] == 500_000
    end

    test "accepts string keys in attrs" do
      %{tenant: tenant, story: story} = setup_project()

      attrs = %{
        "scope_type" => "story",
        "scope_id" => story.id,
        "budget_millicents" => 500_000
      }

      assert {:ok, %Budget{}} = TokenUsage.create_budget(tenant.id, attrs)
    end
  end

  # --- get_budget/2 ---

  describe "get_budget/2" do
    test "returns a budget by id" do
      %{tenant: tenant, story: story} = setup_project()

      budget =
        fixture(:token_budget, %{
          tenant_id: tenant.id,
          scope_type: :story,
          scope_id: story.id
        })

      assert {:ok, found} = TokenUsage.get_budget(tenant.id, budget.id)
      assert found.id == budget.id
    end

    test "returns :not_found for nonexistent budget" do
      tenant = fixture(:tenant)
      assert {:error, :not_found} = TokenUsage.get_budget(tenant.id, Ecto.UUID.generate())
    end

    test "returns :not_found for wrong tenant" do
      %{tenant: tenant, story: story} = setup_project()

      budget =
        fixture(:token_budget, %{
          tenant_id: tenant.id,
          scope_type: :story,
          scope_id: story.id
        })

      other_tenant = fixture(:tenant)
      assert {:error, :not_found} = TokenUsage.get_budget(other_tenant.id, budget.id)
    end
  end

  # --- list_budgets/2 ---

  describe "list_budgets/2" do
    test "returns all budgets for a tenant" do
      %{tenant: tenant, project: project, epic: epic, story: story} = setup_project()

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :project,
        scope_id: project.id
      })

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :epic,
        scope_id: epic.id
      })

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :story,
        scope_id: story.id
      })

      {:ok, result} = TokenUsage.list_budgets(tenant.id)
      assert result.total == 3
      assert length(result.data) == 3
    end

    test "filters by scope_type" do
      %{tenant: tenant, project: project, story: story} = setup_project()

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :project,
        scope_id: project.id
      })

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :story,
        scope_id: story.id
      })

      {:ok, result} = TokenUsage.list_budgets(tenant.id, scope_type: :story)
      assert result.total == 1
    end

    test "filters by scope_id" do
      %{tenant: tenant, story: story} = setup_project()

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :story,
        scope_id: story.id
      })

      story2 =
        fixture(:story, %{tenant_id: tenant.id})

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :story,
        scope_id: story2.id
      })

      {:ok, result} = TokenUsage.list_budgets(tenant.id, scope_id: story.id)
      assert result.total == 1
    end

    test "includes current spend and remaining" do
      %{tenant: tenant, story: story} = setup_project()
      agent = fixture(:agent, %{tenant_id: tenant.id})

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :story,
        scope_id: story.id,
        budget_millicents: 10_000
      })

      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story.id,
        agent_id: agent.id,
        cost_millicents: 3000
      })

      {:ok, result} = TokenUsage.list_budgets(tenant.id)
      entry = hd(result.data)

      assert entry.current_spend_millicents == 3000
      assert entry.remaining_millicents == 7000
    end

    test "paginates results" do
      %{tenant: tenant} = setup_project()

      for _i <- 1..5 do
        story = fixture(:story, %{tenant_id: tenant.id})

        fixture(:token_budget, %{
          tenant_id: tenant.id,
          scope_type: :story,
          scope_id: story.id
        })
      end

      {:ok, result} = TokenUsage.list_budgets(tenant.id, page: 1, page_size: 2)
      assert length(result.data) == 2
      assert result.total == 5
    end
  end

  # --- update_budget/4 ---

  describe "update_budget/4" do
    test "updates budget_millicents" do
      %{tenant: tenant, story: story} = setup_project()

      budget =
        fixture(:token_budget, %{
          tenant_id: tenant.id,
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 500_000
        })

      assert {:ok, updated} =
               TokenUsage.update_budget(tenant.id, budget.id, %{budget_millicents: 1_000_000})

      assert updated.budget_millicents == 1_000_000
    end

    test "updates alert_threshold_pct" do
      %{tenant: tenant, story: story} = setup_project()

      budget =
        fixture(:token_budget, %{
          tenant_id: tenant.id,
          scope_type: :story,
          scope_id: story.id
        })

      assert {:ok, updated} =
               TokenUsage.update_budget(tenant.id, budget.id, %{alert_threshold_pct: 95})

      assert updated.alert_threshold_pct == 95
    end

    test "updates budget_input_tokens and budget_output_tokens" do
      %{tenant: tenant, story: story} = setup_project()

      budget =
        fixture(:token_budget, %{
          tenant_id: tenant.id,
          scope_type: :story,
          scope_id: story.id
        })

      assert {:ok, updated} =
               TokenUsage.update_budget(tenant.id, budget.id, %{
                 budget_input_tokens: 200_000,
                 budget_output_tokens: 100_000
               })

      assert updated.budget_input_tokens == 200_000
      assert updated.budget_output_tokens == 100_000
    end

    test "returns :not_found for nonexistent budget" do
      tenant = fixture(:tenant)

      assert {:error, :not_found} =
               TokenUsage.update_budget(tenant.id, Ecto.UUID.generate(), %{
                 budget_millicents: 100
               })
    end

    test "creates an audit log entry" do
      %{tenant: tenant, story: story} = setup_project()

      budget =
        fixture(:token_budget, %{
          tenant_id: tenant.id,
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 500_000
        })

      {:ok, _} =
        TokenUsage.update_budget(tenant.id, budget.id, %{budget_millicents: 1_000_000},
          actor_id: Ecto.UUID.generate()
        )

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id,
          entity_type: "token_budget",
          entity_id: budget.id,
          action: "updated"
        )

      assert length(result.data) == 1
      audit = hd(result.data)
      assert audit.old_state["budget_millicents"] == 500_000
      assert audit.new_state["budget_millicents"] == 1_000_000
    end
  end

  # --- delete_budget/3 ---

  describe "delete_budget/3" do
    test "deletes a budget" do
      %{tenant: tenant, story: story} = setup_project()

      budget =
        fixture(:token_budget, %{
          tenant_id: tenant.id,
          scope_type: :story,
          scope_id: story.id
        })

      assert {:ok, deleted} = TokenUsage.delete_budget(tenant.id, budget.id)
      assert deleted.id == budget.id
      assert {:error, :not_found} = TokenUsage.get_budget(tenant.id, budget.id)
    end

    test "does not delete associated token usage reports" do
      %{tenant: tenant, story: story} = setup_project()
      agent = fixture(:agent, %{tenant_id: tenant.id})

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :story,
        scope_id: story.id
      })

      report =
        fixture(:token_usage_report, %{
          tenant_id: tenant.id,
          story_id: story.id,
          agent_id: agent.id
        })

      budgets = Loopctl.AdminRepo.all(Budget)
      budget = hd(budgets)

      {:ok, _} = TokenUsage.delete_budget(tenant.id, budget.id)

      # Report should still exist
      assert Loopctl.AdminRepo.get(Loopctl.TokenUsage.Report, report.id) != nil
    end

    test "returns :not_found for nonexistent budget" do
      tenant = fixture(:tenant)
      assert {:error, :not_found} = TokenUsage.delete_budget(tenant.id, Ecto.UUID.generate())
    end

    test "creates an audit log entry" do
      %{tenant: tenant, story: story} = setup_project()

      budget =
        fixture(:token_budget, %{
          tenant_id: tenant.id,
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 500_000
        })

      {:ok, _} =
        TokenUsage.delete_budget(tenant.id, budget.id, actor_id: Ecto.UUID.generate())

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id,
          entity_type: "token_budget",
          entity_id: budget.id,
          action: "deleted"
        )

      assert length(result.data) == 1
    end
  end

  # --- get_effective_budget/3 ---

  describe "get_effective_budget/3" do
    test "returns explicit story budget" do
      %{tenant: tenant, story: story} = setup_project()

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :story,
        scope_id: story.id,
        budget_millicents: 500_000
      })

      assert {:ok, {500_000, :explicit}} =
               TokenUsage.get_effective_budget(tenant.id, :story, story.id)
    end

    test "inherits epic budget when no story budget exists" do
      %{tenant: tenant, epic: epic, story: story} = setup_project()

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :epic,
        scope_id: epic.id,
        budget_millicents: 2_000_000
      })

      assert {:ok, {2_000_000, :epic_inherited}} =
               TokenUsage.get_effective_budget(tenant.id, :story, story.id)
    end

    test "inherits project budget when no story or epic budget exists" do
      %{tenant: tenant, project: project, story: story} = setup_project()

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :project,
        scope_id: project.id,
        budget_millicents: 10_000_000
      })

      assert {:ok, {10_000_000, :project_inherited}} =
               TokenUsage.get_effective_budget(tenant.id, :story, story.id)
    end

    test "returns tenant default when no explicit budgets exist" do
      %{tenant: tenant, story: story} = setup_project()

      # Set tenant default
      tenant
      |> Ecto.Changeset.change(%{default_story_budget_millicents: 100_000})
      |> Loopctl.AdminRepo.update!()

      assert {:ok, {100_000, :tenant_default}} =
               TokenUsage.get_effective_budget(tenant.id, :story, story.id)
    end

    test "returns nil when no budget at any level" do
      %{tenant: tenant, story: story} = setup_project()

      assert {:ok, nil} = TokenUsage.get_effective_budget(tenant.id, :story, story.id)
    end

    test "story budget takes precedence over epic budget" do
      %{tenant: tenant, epic: epic, story: story} = setup_project()

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :story,
        scope_id: story.id,
        budget_millicents: 500_000
      })

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :epic,
        scope_id: epic.id,
        budget_millicents: 2_000_000
      })

      assert {:ok, {500_000, :explicit}} =
               TokenUsage.get_effective_budget(tenant.id, :story, story.id)
    end

    test "epic budget takes precedence over project budget for story" do
      %{tenant: tenant, project: project, epic: epic, story: story} = setup_project()

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :epic,
        scope_id: epic.id,
        budget_millicents: 2_000_000
      })

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :project,
        scope_id: project.id,
        budget_millicents: 10_000_000
      })

      assert {:ok, {2_000_000, :epic_inherited}} =
               TokenUsage.get_effective_budget(tenant.id, :story, story.id)
    end

    test "epic inherits project budget" do
      %{tenant: tenant, project: project, epic: epic} = setup_project()

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :project,
        scope_id: project.id,
        budget_millicents: 10_000_000
      })

      assert {:ok, {10_000_000, :project_inherited}} =
               TokenUsage.get_effective_budget(tenant.id, :epic, epic.id)
    end

    test "epic falls back to tenant default" do
      %{tenant: tenant, epic: epic} = setup_project()

      tenant
      |> Ecto.Changeset.change(%{default_story_budget_millicents: 100_000})
      |> Loopctl.AdminRepo.update!()

      assert {:ok, {100_000, :tenant_default}} =
               TokenUsage.get_effective_budget(tenant.id, :epic, epic.id)
    end

    test "project falls back to tenant default" do
      %{tenant: tenant, project: project} = setup_project()

      tenant
      |> Ecto.Changeset.change(%{default_story_budget_millicents: 100_000})
      |> Loopctl.AdminRepo.update!()

      assert {:ok, {100_000, :tenant_default}} =
               TokenUsage.get_effective_budget(tenant.id, :project, project.id)
    end
  end

  # --- get_scope_spend/3 ---

  describe "get_scope_spend/3" do
    test "calculates story-level spend" do
      %{tenant: tenant, story: story} = setup_project()
      agent = fixture(:agent, %{tenant_id: tenant.id})

      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story.id,
        agent_id: agent.id,
        cost_millicents: 3000
      })

      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story.id,
        agent_id: agent.id,
        cost_millicents: 2000
      })

      assert TokenUsage.get_scope_spend(tenant.id, :story, story.id) == 5000
    end

    test "calculates epic-level spend across stories" do
      %{tenant: tenant, epic: epic, story: story} = setup_project()
      agent = fixture(:agent, %{tenant_id: tenant.id})

      story2 =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          project_id: story.project_id
        })

      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story.id,
        agent_id: agent.id,
        cost_millicents: 3000
      })

      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story2.id,
        agent_id: agent.id,
        cost_millicents: 2000
      })

      assert TokenUsage.get_scope_spend(tenant.id, :epic, epic.id) == 5000
    end

    test "calculates project-level spend across all stories" do
      %{tenant: tenant, project: project, story: story} = setup_project()
      agent = fixture(:agent, %{tenant_id: tenant.id})

      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story.id,
        agent_id: agent.id,
        cost_millicents: 5000
      })

      assert TokenUsage.get_scope_spend(tenant.id, :project, project.id) == 5000
    end

    test "returns zero when no reports exist" do
      %{tenant: tenant, story: story} = setup_project()
      assert TokenUsage.get_scope_spend(tenant.id, :story, story.id) == 0
    end
  end

  # --- Tenant isolation ---

  describe "tenant isolation" do
    test "tenant A cannot see tenant B's budgets" do
      %{tenant: tenant_a, story: story_a} = setup_project()

      fixture(:token_budget, %{
        tenant_id: tenant_a.id,
        scope_type: :story,
        scope_id: story_a.id
      })

      tenant_b = fixture(:tenant)

      {:ok, result} = TokenUsage.list_budgets(tenant_b.id)
      assert result.data == []
      assert result.total == 0
    end

    test "tenant A cannot get tenant B's budget by id" do
      %{tenant: tenant_a, story: story_a} = setup_project()

      budget =
        fixture(:token_budget, %{
          tenant_id: tenant_a.id,
          scope_type: :story,
          scope_id: story_a.id
        })

      tenant_b = fixture(:tenant)
      assert {:error, :not_found} = TokenUsage.get_budget(tenant_b.id, budget.id)
    end

    test "budgets are scoped to their tenant for unique constraint" do
      # Two different tenants can have budgets for different stories
      %{tenant: tenant_a, story: story_a} = setup_project()

      fixture(:token_budget, %{
        tenant_id: tenant_a.id,
        scope_type: :story,
        scope_id: story_a.id
      })

      tenant_b = fixture(:tenant)
      story_b = fixture(:story, %{tenant_id: tenant_b.id})

      # This should succeed (different tenant, different story)
      assert {:ok, _} =
               TokenUsage.create_budget(tenant_b.id, %{
                 scope_type: :story,
                 scope_id: story_b.id,
                 budget_millicents: 500_000
               })
    end
  end

  # --- Fixture test ---

  describe "fixture/2" do
    test "creates a token budget with auto-dependency resolution" do
      budget = fixture(:token_budget)

      assert budget.id != nil
      assert budget.tenant_id != nil
      assert budget.scope_id != nil
      assert budget.scope_type == :story
      assert budget.budget_millicents == 500_000
    end

    test "creates a token budget with custom attributes" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      budget =
        fixture(:token_budget, %{
          tenant_id: tenant.id,
          scope_type: :project,
          scope_id: project.id,
          budget_millicents: 10_000_000,
          alert_threshold_pct: 90
        })

      assert budget.tenant_id == tenant.id
      assert budget.scope_type == :project
      assert budget.scope_id == project.id
      assert budget.budget_millicents == 10_000_000
      assert budget.alert_threshold_pct == 90
    end
  end
end
