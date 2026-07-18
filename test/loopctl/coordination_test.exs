defmodule Loopctl.CoordinationTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.Coordination
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.Repo

  describe "create_post/4" do
    test "inserts with programmatic tenant/project/agent/expires and cast body" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = Ecto.UUID.generate()

      assert {:ok, post} =
               Coordination.create_post(tenant.id, project.id, agent_id, %{
                 "body" => "pushed PR #107, CI green"
               })

      assert post.tenant_id == tenant.id
      assert post.project_id == project.id
      assert post.agent_id == agent_id
      assert post.body == "pushed PR #107, CI green"
      assert is_nil(post.key)
      assert is_nil(post.refs)

      # expires_at is ~30 days out (server-set, uniform retention).
      expected = DateTime.add(DateTime.utc_now(), Coordination.retention_days() * 86_400, :second)
      assert_in_delta DateTime.to_unix(post.expires_at), DateTime.to_unix(expected), 120
    end

    test "a mispaired project (belongs to another tenant) returns {:error, :not_found}" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})

      assert {:error, :not_found} =
               Coordination.create_post(tenant_a.id, project_b.id, Ecto.UUID.generate(), %{
                 "body" => "cross-tenant attempt"
               })
    end

    test "a duplicate same-session keyed post returns {:error, changeset}, not a raise" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = Ecto.UUID.generate()

      attrs = %{"body" => "goal", "session_id" => "S1", "key" => "session_goal"}

      assert {:ok, _post} = Coordination.create_post(tenant.id, project.id, agent_id, attrs)

      assert {:error, %Ecto.Changeset{} = cs} =
               Coordination.create_post(tenant.id, project.id, agent_id, attrs)

      assert %{key: _} = errors_on(cs)
    end

    test "accepts valid refs restricted to the allowlist" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      assert {:ok, post} =
               Coordination.create_post(tenant.id, project.id, Ecto.UUID.generate(), %{
                 "body" => "see the fix",
                 "refs" => %{"pr" => "107", "branch" => "epic-39-us-39.1"}
               })

      assert post.refs == %{"pr" => "107", "branch" => "epic-39-us-39.1"}
    end
  end

  describe "tenant isolation (both paths)" do
    test "recent/3 (AdminRepo + explicit filter) and RLS Repo both hide another tenant's posts" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_a = fixture(:project, %{tenant_id: tenant_a.id})

      {:ok, _post} =
        Coordination.create_post(tenant_a.id, project_a.id, Ecto.UUID.generate(), %{
          "body" => "tenant A only"
        })

      # AdminRepo path: tenant_b's explicit filter yields zero rows for A's project.
      assert Coordination.recent(tenant_b.id, project_a.id) == []
      # And tenant_a sees its own post.
      assert [%ChannelPost{body: "tenant A only"}] =
               Coordination.recent(tenant_a.id, project_a.id)

      # RLS Repo path (belt-and-suspenders): scoped to tenant_b, the row is invisible.
      {:ok, rows} =
        Repo.with_tenant(tenant_b.id, fn ->
          Repo.all(from(p in ChannelPost, where: p.project_id == ^project_a.id))
        end)

      assert rows == []
    end
  end

  describe "per-session keyed slot" do
    test "two sessions with the same key do not clobber each other" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = Ecto.UUID.generate()

      assert {:ok, post_a} =
               Coordination.create_post(tenant.id, project.id, agent_id, %{
                 "body" => "goal A",
                 "session_id" => "S1",
                 "key" => "session_goal"
               })

      assert {:ok, post_b} =
               Coordination.create_post(tenant.id, project.id, agent_id, %{
                 "body" => "goal B",
                 "session_id" => "S2",
                 "key" => "session_goal"
               })

      assert post_a.id != post_b.id
      posts = Coordination.recent(tenant.id, project.id)
      assert length(posts) == 2
    end
  end
end
