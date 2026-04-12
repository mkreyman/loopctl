defmodule Loopctl.Auth.ApiKeyInvariantsTest do
  @moduledoc """
  Tests for US-26.1.3 — api_keys database invariants.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query
  import Loopctl.Fixtures

  alias Ecto.Adapters.SQL
  alias Loopctl.AdminRepo
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Progress

  setup :verify_on_exit!

  describe "nil identity self-check" do
    test "validate_not_self_report blocks nil agent_id" do
      %{tenant: tenant, story: story, agent: agent} = setup_implementing_story()

      result = Progress.report_story(tenant.id, story.id, agent_id: nil)
      assert result == {:error, :self_report_blocked}
    end

    test "validate_not_self_verify blocks nil orchestrator_agent_id" do
      %{tenant: tenant, story: story} = setup_reported_done_story()

      result =
        Progress.verify_story(
          tenant.id,
          story.id,
          %{"summary" => "test"},
          orchestrator_agent_id: nil
        )

      assert {:error, :self_verify_blocked} = result
    end
  end

  describe "FK constraint on api_keys.agent_id" do
    test "inserting key with non-existent agent_id raises FK violation" do
      tenant = fixture(:tenant)
      fake_agent_id = Ecto.UUID.generate()

      {:ok, tenant_uuid} = Ecto.UUID.dump(tenant.id)
      {:ok, agent_uuid} = Ecto.UUID.dump(fake_agent_id)

      assert_raise Postgrex.Error, ~r/api_keys_agent_id_fkey/, fn ->
        SQL.query!(
          AdminRepo,
          """
          INSERT INTO api_keys (id, tenant_id, agent_id, name, key_hash, key_prefix, role, inserted_at, updated_at)
          VALUES (gen_random_uuid(), $1, $2, 'test', 'hash', 'lc_xxx', 'agent', NOW(), NOW())
          """,
          [tenant_uuid, agent_uuid]
        )
      end
    end
  end

  describe "role-agent_id consistency" do
    test "user-role key with nil agent_id is allowed" do
      tenant = fixture(:tenant)
      {_raw, key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      assert key.agent_id == nil
    end

    # DB check constraint deferred to US-26.2.1 (dispatch lineage).
    # Application-level enforcement tested via the Auth module.
  end

  describe "one active key per agent (partial unique index)" do
    test "second active key for same agent is blocked" do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id})

      {_raw, _first_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      # Second key for the same agent should fail
      {:ok, tenant_uuid} = Ecto.UUID.dump(tenant.id)
      {:ok, agent_uuid} = Ecto.UUID.dump(agent.id)

      assert_raise Postgrex.Error, ~r/api_keys_one_role_per_agent_idx/, fn ->
        SQL.query!(
          AdminRepo,
          """
          INSERT INTO api_keys (id, tenant_id, agent_id, name, key_hash, key_prefix, role, inserted_at, updated_at)
          VALUES (gen_random_uuid(), $1, $2, 'second', 'hash2', 'lc_yyy', 'agent', NOW(), NOW())
          """,
          [tenant_uuid, agent_uuid]
        )
      end
    end
  end

  describe "role immutability trigger" do
    test "updating role is blocked by trigger" do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id})
      {_raw, key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      assert_raise Postgrex.Error, ~r/api_key_role_immutable/, fn ->
        from(k in ApiKey, where: k.id == ^key.id)
        |> AdminRepo.update_all(set: [role: "orchestrator"])
      end
    end
  end

  # --- Helpers ---

  defp setup_implementing_story do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id})

    story =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        agent_status: :implementing,
        assigned_agent_id: agent.id,
        assigned_at: DateTime.utc_now()
      })

    %{tenant: tenant, story: story, agent: agent}
  end

  defp setup_reported_done_story do
    ctx = setup_implementing_story()

    story =
      ctx.story
      |> Ecto.Changeset.change(%{
        agent_status: :reported_done,
        reported_done_at: DateTime.utc_now()
      })
      |> AdminRepo.update!()

    %{ctx | story: story}
  end
end
