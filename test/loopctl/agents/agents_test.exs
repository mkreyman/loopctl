defmodule Loopctl.AgentsTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Agents
  alias Loopctl.Agents.Agent

  describe "register_agent/3" do
    test "registers an agent with valid attributes" do
      tenant = fixture(:tenant)

      attrs = %{
        name: "worker-1",
        agent_type: :implementer,
        metadata: %{"lang" => "elixir"}
      }

      assert {:ok, %Agent{} = agent} =
               Agents.register_agent(tenant.id, attrs,
                 actor_id: uuid(),
                 actor_label: "agent:worker-1"
               )

      assert agent.name == "worker-1"
      assert agent.agent_type == :implementer
      assert agent.status == :active
      assert agent.tenant_id == tenant.id
      assert agent.metadata == %{"lang" => "elixir"}
      assert %DateTime{} = agent.last_seen_at
    end

    test "registers orchestrator agent" do
      tenant = fixture(:tenant)

      attrs = %{name: "orchestrator-main", agent_type: :orchestrator}

      assert {:ok, %Agent{} = agent} = Agents.register_agent(tenant.id, attrs)
      assert agent.agent_type == :orchestrator
      assert agent.status == :active
    end

    test "creates audit log entry on registration" do
      tenant = fixture(:tenant)
      actor_id = uuid()

      attrs = %{name: "audited-agent", agent_type: :implementer}

      assert {:ok, %Agent{}} =
               Agents.register_agent(tenant.id, attrs,
                 actor_id: actor_id,
                 actor_label: "agent:audited-agent"
               )

      # Verify audit log was created
      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "agent", action: "registered")

      assert length(result.data) == 1
      entry = hd(result.data)
      assert entry.entity_type == "agent"
      assert entry.action == "registered"
      assert entry.actor_id == actor_id
      assert entry.actor_label == "agent:audited-agent"
      assert entry.new_state["name"] == "audited-agent"
      assert entry.new_state["agent_type"] == "implementer"
      assert entry.new_state["status"] == "active"
    end

    test "rejects duplicate name within same tenant" do
      tenant = fixture(:tenant)

      attrs = %{name: "worker-1", agent_type: :implementer}
      assert {:ok, _} = Agents.register_agent(tenant.id, attrs)

      assert {:error, changeset} = Agents.register_agent(tenant.id, attrs)
      assert "has already been taken for this tenant" in errors_on(changeset).tenant_id
    end

    test "allows same name in different tenants" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      attrs = %{name: "worker-1", agent_type: :implementer}

      assert {:ok, _} = Agents.register_agent(tenant_a.id, attrs)
      assert {:ok, _} = Agents.register_agent(tenant_b.id, attrs)
    end

    test "rejects missing required fields" do
      tenant = fixture(:tenant)

      assert {:error, changeset} = Agents.register_agent(tenant.id, %{})
      errors = errors_on(changeset)
      assert errors.name != []
      assert errors.agent_type != []
    end

    test "rejects invalid agent_type" do
      tenant = fixture(:tenant)

      attrs = %{name: "bad-agent", agent_type: :invalid_type}

      assert {:error, changeset} = Agents.register_agent(tenant.id, attrs)
      assert errors_on(changeset).agent_type != []
    end

    test "defaults metadata to empty map" do
      tenant = fixture(:tenant)

      attrs = %{name: "minimal-agent", agent_type: :implementer}
      assert {:ok, agent} = Agents.register_agent(tenant.id, attrs)
      assert agent.metadata == %{}
    end
  end

  describe "get_agent/2" do
    test "returns agent by ID within tenant" do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id, name: "my-agent"})

      assert {:ok, found} = Agents.get_agent(tenant.id, agent.id)
      assert found.id == agent.id
      assert found.name == "my-agent"
    end

    test "returns not_found for unknown ID" do
      tenant = fixture(:tenant)
      assert {:error, :not_found} = Agents.get_agent(tenant.id, uuid())
    end

    test "returns not_found for agent in different tenant" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant_b.id})

      assert {:error, :not_found} = Agents.get_agent(tenant_a.id, agent.id)
    end
  end

  describe "update_agent/3" do
    test "updates agent status" do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id})

      assert {:ok, updated} = Agents.update_agent(tenant.id, agent, %{status: :idle})
      assert updated.status == :idle
    end

    test "updates agent metadata" do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id})

      new_metadata = %{"capabilities" => ["code", "test"]}
      assert {:ok, updated} = Agents.update_agent(tenant.id, agent, %{metadata: new_metadata})
      assert updated.metadata == new_metadata
    end

    test "rejects invalid status" do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id})

      assert {:error, changeset} = Agents.update_agent(tenant.id, agent, %{status: :invalid})
      assert errors_on(changeset).status != []
    end
  end

  describe "touch_last_seen/3" do
    test "updates last_seen_at timestamp" do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id})
      now = DateTime.utc_now()

      assert {:ok, updated} = Agents.touch_last_seen(tenant.id, agent.id, now)
      assert updated.last_seen_at != nil
    end

    test "returns not_found for nonexistent agent" do
      tenant = fixture(:tenant)
      assert {:error, :not_found} = Agents.touch_last_seen(tenant.id, uuid(), DateTime.utc_now())
    end
  end

  describe "list_agents/2" do
    test "lists agents for a tenant" do
      tenant = fixture(:tenant)
      fixture(:agent, %{tenant_id: tenant.id, name: "agent-a"})
      fixture(:agent, %{tenant_id: tenant.id, name: "agent-b"})

      {:ok, result} = Agents.list_agents(tenant.id)

      assert length(result.data) == 2
      assert result.total == 2
      assert result.page == 1
      assert result.page_size == 20
    end

    test "filters by agent_type" do
      tenant = fixture(:tenant)
      fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator, name: "orch"})
      fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer, name: "impl"})

      {:ok, result} = Agents.list_agents(tenant.id, agent_type: :orchestrator)

      assert length(result.data) == 1
      assert hd(result.data).agent_type == :orchestrator
    end

    test "filters by status" do
      tenant = fixture(:tenant)
      active = fixture(:agent, %{tenant_id: tenant.id, name: "active-one"})
      _idle = fixture(:agent, %{tenant_id: tenant.id, name: "idle-one"})

      # Update one to idle
      Agents.update_agent(tenant.id, active, %{status: :idle})

      {:ok, result} = Agents.list_agents(tenant.id, status: :idle)

      assert length(result.data) == 1
      assert hd(result.data).status == :idle
    end

    test "paginates results" do
      tenant = fixture(:tenant)

      for i <- 1..5 do
        fixture(:agent, %{
          tenant_id: tenant.id,
          name: "agent-#{String.pad_leading(to_string(i), 2, "0")}"
        })
      end

      {:ok, page1} = Agents.list_agents(tenant.id, page: 1, page_size: 2)
      assert length(page1.data) == 2
      assert page1.total == 5
      assert page1.page == 1

      {:ok, page3} = Agents.list_agents(tenant.id, page: 3, page_size: 2)
      assert length(page3.data) == 1
    end

    test "returns agents ordered by name" do
      tenant = fixture(:tenant)
      fixture(:agent, %{tenant_id: tenant.id, name: "zeta-agent"})
      fixture(:agent, %{tenant_id: tenant.id, name: "alpha-agent"})

      {:ok, result} = Agents.list_agents(tenant.id)

      names = Enum.map(result.data, & &1.name)
      assert names == ["alpha-agent", "zeta-agent"]
    end

    test "sorts by specified field" do
      tenant = fixture(:tenant)
      fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator, name: "beta"})
      fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer, name: "alpha"})

      {:ok, result} = Agents.list_agents(tenant.id, sort_by: "agent_type")

      types = Enum.map(result.data, & &1.agent_type)
      assert types == [:implementer, :orchestrator]
    end

    test "falls back to name for invalid sort_by" do
      tenant = fixture(:tenant)
      fixture(:agent, %{tenant_id: tenant.id, name: "zeta"})
      fixture(:agent, %{tenant_id: tenant.id, name: "alpha"})

      {:ok, result} = Agents.list_agents(tenant.id, sort_by: "invalid_field")

      names = Enum.map(result.data, & &1.name)
      assert names == ["alpha", "zeta"]
    end
  end

  describe "tenant isolation" do
    test "tenant A cannot see tenant B's agents" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      fixture(:agent, %{tenant_id: tenant_a.id, name: "agent-a"})
      fixture(:agent, %{tenant_id: tenant_b.id, name: "agent-b"})

      {:ok, result_a} = Agents.list_agents(tenant_a.id)
      {:ok, result_b} = Agents.list_agents(tenant_b.id)

      assert length(result_a.data) == 1
      assert hd(result_a.data).name == "agent-a"

      assert length(result_b.data) == 1
      assert hd(result_b.data).name == "agent-b"
    end

    test "get_agent returns not_found for cross-tenant access" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      agent_b = fixture(:agent, %{tenant_id: tenant_b.id})

      assert {:error, :not_found} = Agents.get_agent(tenant_a.id, agent_b.id)
    end
  end
end
