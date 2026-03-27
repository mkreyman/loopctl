defmodule Loopctl.Skills.SkillResultsTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Skills

  describe "create_skill_result/2" do
    test "creates a skill result linking verification to skill version" do
      tenant = fixture(:tenant)
      skill = fixture(:skill, %{tenant_id: tenant.id})
      story = fixture(:story, %{tenant_id: tenant.id})
      vr = fixture(:verification_result, %{tenant_id: tenant.id, story_id: story.id})

      # Get the version that was created with the skill
      {:ok, [v1]} = Skills.list_versions(tenant.id, skill.id)

      assert {:ok, result} =
               Skills.create_skill_result(tenant.id, %{
                 "skill_version_id" => v1.id,
                 "verification_result_id" => vr.id,
                 "story_id" => story.id,
                 "metrics" => %{
                   "findings_count" => 3,
                   "false_positive_count" => 1
                 }
               })

      assert result.skill_version_id == v1.id
      assert result.verification_result_id == vr.id
      assert result.metrics["findings_count"] == 3
    end
  end

  describe "skill_stats/2" do
    test "returns aggregate stats by version" do
      tenant = fixture(:tenant)
      skill = fixture(:skill, %{tenant_id: tenant.id})
      story = fixture(:story, %{tenant_id: tenant.id})

      vr_pass =
        fixture(:verification_result, %{
          tenant_id: tenant.id,
          story_id: story.id,
          result: :pass
        })

      vr_fail =
        fixture(:verification_result, %{
          tenant_id: tenant.id,
          story_id: story.id,
          result: :fail
        })

      {:ok, [v1]} = Skills.list_versions(tenant.id, skill.id)

      Skills.create_skill_result(tenant.id, %{
        "skill_version_id" => v1.id,
        "verification_result_id" => vr_pass.id,
        "story_id" => story.id
      })

      Skills.create_skill_result(tenant.id, %{
        "skill_version_id" => v1.id,
        "verification_result_id" => vr_fail.id,
        "story_id" => story.id
      })

      {:ok, stats} = Skills.skill_stats(tenant.id, skill.id)
      assert length(stats) == 1
      stat = hd(stats)
      assert stat.version == 1
      assert stat.total_results == 2
      assert stat.pass_count == 1
      assert stat.fail_count == 1
    end

    test "returns not_found for wrong tenant" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      skill = fixture(:skill, %{tenant_id: tenant_a.id})

      assert {:error, :not_found} = Skills.skill_stats(tenant_b.id, skill.id)
    end
  end

  describe "list_version_results/4" do
    test "lists results for a specific version" do
      tenant = fixture(:tenant)
      skill = fixture(:skill, %{tenant_id: tenant.id})
      story = fixture(:story, %{tenant_id: tenant.id})
      vr = fixture(:verification_result, %{tenant_id: tenant.id, story_id: story.id})

      {:ok, [v1]} = Skills.list_versions(tenant.id, skill.id)

      Skills.create_skill_result(tenant.id, %{
        "skill_version_id" => v1.id,
        "verification_result_id" => vr.id,
        "story_id" => story.id
      })

      {:ok, results} = Skills.list_version_results(tenant.id, skill.id, 1)
      assert length(results) == 1
    end
  end
end
