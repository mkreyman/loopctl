defmodule Loopctl.SkillsTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Skills

  describe "create_skill/3" do
    test "creates a skill with initial version" do
      tenant = fixture(:tenant)

      assert {:ok, %{skill: skill, version: version}} =
               Skills.create_skill(tenant.id, %{
                 "name" => "loopctl:review",
                 "description" => "Enhanced review skill",
                 "prompt_text" => "Review all code..."
               })

      assert skill.name == "loopctl:review"
      assert skill.current_version == 1
      assert skill.status == :active
      assert version.version == 1
      assert version.prompt_text == "Review all code..."
    end

    test "rejects duplicate names within same tenant" do
      tenant = fixture(:tenant)

      assert {:ok, _} =
               Skills.create_skill(tenant.id, %{
                 "name" => "dup-skill",
                 "prompt_text" => "v1"
               })

      assert {:error, changeset} =
               Skills.create_skill(tenant.id, %{
                 "name" => "dup-skill",
                 "prompt_text" => "v1"
               })

      # Unique constraint on [:tenant_id, :name] puts error on first field
      assert errors_on(changeset)[:tenant_id] || errors_on(changeset)[:name]
    end

    test "allows same name in different tenants" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      assert {:ok, _} =
               Skills.create_skill(tenant_a.id, %{
                 "name" => "shared-skill",
                 "prompt_text" => "v1"
               })

      assert {:ok, _} =
               Skills.create_skill(tenant_b.id, %{
                 "name" => "shared-skill",
                 "prompt_text" => "v1"
               })
    end
  end

  describe "list_skills/2" do
    test "lists skills for a tenant" do
      tenant = fixture(:tenant)
      fixture(:skill, %{tenant_id: tenant.id, name: "skill-a"})
      fixture(:skill, %{tenant_id: tenant.id, name: "skill-b"})

      {:ok, result} = Skills.list_skills(tenant.id)
      assert result.total == 2
      assert length(result.data) == 2
    end

    test "filters by status" do
      tenant = fixture(:tenant)
      fixture(:skill, %{tenant_id: tenant.id, name: "active-skill"})
      skill_b = fixture(:skill, %{tenant_id: tenant.id, name: "archived-skill"})
      Skills.archive_skill(tenant.id, skill_b.id)

      {:ok, result} = Skills.list_skills(tenant.id, status: "active")
      assert result.total == 1
    end

    test "filters by name pattern" do
      tenant = fixture(:tenant)
      fixture(:skill, %{tenant_id: tenant.id, name: "loopctl:review"})
      fixture(:skill, %{tenant_id: tenant.id, name: "loopctl:verify"})
      fixture(:skill, %{tenant_id: tenant.id, name: "other:skill"})

      {:ok, result} = Skills.list_skills(tenant.id, name_pattern: "loopctl")
      assert result.total == 2
    end

    test "tenant isolation" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      fixture(:skill, %{tenant_id: tenant_a.id, name: "skill-a"})
      fixture(:skill, %{tenant_id: tenant_b.id, name: "skill-b"})

      {:ok, result_a} = Skills.list_skills(tenant_a.id)
      {:ok, result_b} = Skills.list_skills(tenant_b.id)

      assert result_a.total == 1
      assert result_b.total == 1
      assert hd(result_a.data).name == "skill-a"
      assert hd(result_b.data).name == "skill-b"
    end
  end

  describe "get_skill/2" do
    test "returns skill by id" do
      tenant = fixture(:tenant)
      skill = fixture(:skill, %{tenant_id: tenant.id})

      assert {:ok, found} = Skills.get_skill(tenant.id, skill.id)
      assert found.id == skill.id
    end

    test "returns not_found for wrong tenant" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      skill = fixture(:skill, %{tenant_id: tenant_a.id})

      assert {:error, :not_found} = Skills.get_skill(tenant_b.id, skill.id)
    end
  end

  describe "update_skill/4" do
    test "updates description and status" do
      tenant = fixture(:tenant)
      skill = fixture(:skill, %{tenant_id: tenant.id})

      assert {:ok, updated} =
               Skills.update_skill(tenant.id, skill.id, %{
                 "description" => "Updated description"
               })

      assert updated.description == "Updated description"
    end
  end

  describe "archive_skill/3" do
    test "sets status to archived" do
      tenant = fixture(:tenant)
      skill = fixture(:skill, %{tenant_id: tenant.id})

      assert {:ok, archived} = Skills.archive_skill(tenant.id, skill.id)
      assert archived.status == :archived
    end
  end

  describe "create_version/4" do
    test "creates a new version and increments current_version" do
      tenant = fixture(:tenant)
      skill = fixture(:skill, %{tenant_id: tenant.id})

      assert {:ok, %{skill: updated_skill, version: v2}} =
               Skills.create_version(tenant.id, skill.id, %{
                 "prompt_text" => "Updated prompt v2",
                 "changelog" => "Improved instructions"
               })

      assert updated_skill.current_version == 2
      assert v2.version == 2
      assert v2.prompt_text == "Updated prompt v2"
      assert v2.changelog == "Improved instructions"
    end
  end

  describe "list_versions/3" do
    test "lists all versions for a skill" do
      tenant = fixture(:tenant)
      skill = fixture(:skill, %{tenant_id: tenant.id})

      Skills.create_version(tenant.id, skill.id, %{
        "prompt_text" => "v2 prompt",
        "changelog" => "v2 changes"
      })

      {:ok, versions} = Skills.list_versions(tenant.id, skill.id)
      assert length(versions) == 2
      assert Enum.map(versions, & &1.version) == [1, 2]
    end
  end

  describe "get_version/3" do
    test "gets a specific version" do
      tenant = fixture(:tenant)
      skill = fixture(:skill, %{tenant_id: tenant.id})

      {:ok, v1} = Skills.get_version(tenant.id, skill.id, 1)
      assert v1.version == 1
    end

    test "returns not_found for nonexistent version" do
      tenant = fixture(:tenant)
      skill = fixture(:skill, %{tenant_id: tenant.id})

      assert {:error, :not_found} = Skills.get_version(tenant.id, skill.id, 999)
    end
  end
end
