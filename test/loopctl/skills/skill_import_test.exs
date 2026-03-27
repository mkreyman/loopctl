defmodule Loopctl.Skills.SkillImportTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Skills

  describe "import_skills/3" do
    test "creates new skills" do
      tenant = fixture(:tenant)

      skills_data = [
        %{
          "name" => "loopctl:review",
          "description" => "Review skill",
          "prompt_text" => "Review all code"
        },
        %{
          "name" => "loopctl:verify",
          "description" => "Verify skill",
          "prompt_text" => "Verify artifacts"
        }
      ]

      {:ok, summary} = Skills.import_skills(tenant.id, skills_data)
      assert summary["total"] == 2
      assert summary["created"] == 2
      assert summary["updated"] == 0
      assert summary["unchanged"] == 0
    end

    test "updates existing skills with new version (idempotent)" do
      tenant = fixture(:tenant)

      # Create initial skill
      Skills.create_skill(tenant.id, %{
        "name" => "loopctl:review",
        "prompt_text" => "v1 prompt"
      })

      # Import with same name and different prompt -- should create v2
      skills_data = [
        %{
          "name" => "loopctl:review",
          "prompt_text" => "v2 prompt updated",
          "changelog" => "Updated via import"
        }
      ]

      {:ok, summary} = Skills.import_skills(tenant.id, skills_data)
      assert summary["total"] == 1
      assert summary["created"] == 0
      assert summary["updated"] == 1

      # Verify the skill now has version 2
      {:ok, skill} = Skills.get_skill_by_name(tenant.id, "loopctl:review")
      assert skill.current_version == 2
    end

    test "skips unchanged skills (identical prompt_text)" do
      tenant = fixture(:tenant)

      Skills.create_skill(tenant.id, %{
        "name" => "loopctl:review",
        "prompt_text" => "same prompt"
      })

      # Import with identical prompt -- should be unchanged
      skills_data = [
        %{"name" => "loopctl:review", "prompt_text" => "same prompt"}
      ]

      {:ok, summary} = Skills.import_skills(tenant.id, skills_data)
      assert summary["total"] == 1
      assert summary["unchanged"] == 1
      assert summary["updated"] == 0

      # Version should still be 1
      {:ok, skill} = Skills.get_skill_by_name(tenant.id, "loopctl:review")
      assert skill.current_version == 1
    end

    test "mixes creates and updates" do
      tenant = fixture(:tenant)

      Skills.create_skill(tenant.id, %{
        "name" => "existing-skill",
        "prompt_text" => "v1"
      })

      skills_data = [
        %{"name" => "existing-skill", "prompt_text" => "v2"},
        %{"name" => "new-skill", "prompt_text" => "v1"}
      ]

      {:ok, summary} = Skills.import_skills(tenant.id, skills_data)
      assert summary["created"] == 1
      assert summary["updated"] == 1
    end

    test "handles empty list" do
      tenant = fixture(:tenant)

      {:ok, summary} = Skills.import_skills(tenant.id, [])
      assert summary["total"] == 0
    end

    test "rolls back all changes on failure" do
      tenant = fixture(:tenant)

      # Import with a nil name should fail the changeset
      skills_data = [
        %{"name" => "good-skill", "prompt_text" => "good"},
        %{"name" => nil, "prompt_text" => "bad"}
      ]

      assert {:error, _changeset} = Skills.import_skills(tenant.id, skills_data)

      # First skill should not have been created (transaction rolled back)
      assert {:error, :not_found} = Skills.get_skill_by_name(tenant.id, "good-skill")
    end
  end
end
