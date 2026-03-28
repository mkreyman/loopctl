defmodule Loopctl.ImportExportAcNormalizationTest do
  @moduledoc """
  Tests for Issues 2 and 3:
  - Issue 2: AC normalization (description → criterion mapping)
  - Issue 3: Better import error messages for acceptance_criteria
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.ImportExport

  defp base_payload(story_attrs \\ %{}) do
    story =
      Map.merge(
        %{
          "number" => "1.1",
          "title" => "Test Story"
        },
        story_attrs
      )

    %{
      "epics" => [
        %{
          "number" => 1,
          "title" => "Foundation",
          "stories" => [story]
        }
      ]
    }
  end

  defp run_import(tenant_id, project_id, payload) do
    ImportExport.import_project(tenant_id, project_id, payload,
      actor_id: uuid(),
      actor_label: "user:test"
    )
  end

  describe "acceptance_criteria normalization on import (Issue 2)" do
    test ~s(accepts {"criterion": "..."} format unchanged) do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      payload =
        base_payload(%{
          "acceptance_criteria" => [%{"criterion" => "Feature works"}]
        })

      assert {:ok, _summary} = run_import(tenant.id, project.id, payload)

      story = Loopctl.AdminRepo.get_by!(Loopctl.WorkBreakdown.Story, number: "1.1")
      assert [%{"criterion" => "Feature works"}] = story.acceptance_criteria
    end

    test ~s(normalizes {"id": "AC-1", "description": "..."} to criterion key) do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      payload =
        base_payload(%{
          "acceptance_criteria" => [%{"id" => "AC-1", "description" => "Feature works"}]
        })

      assert {:ok, _summary} = run_import(tenant.id, project.id, payload)

      story = Loopctl.AdminRepo.get_by!(Loopctl.WorkBreakdown.Story, number: "1.1")
      [ac] = story.acceptance_criteria
      # description mapped to criterion; id preserved
      assert ac["criterion"] == "Feature works"
      assert ac["id"] == "AC-1"
      refute Map.has_key?(ac, "description")
    end

    test "prefers description over criterion when both are present" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      payload =
        base_payload(%{
          "acceptance_criteria" => [
            %{"criterion" => "old text", "description" => "new text from description"}
          ]
        })

      assert {:ok, _summary} = run_import(tenant.id, project.id, payload)

      story = Loopctl.AdminRepo.get_by!(Loopctl.WorkBreakdown.Story, number: "1.1")
      [ac] = story.acceptance_criteria
      assert ac["criterion"] == "new text from description"
      refute Map.has_key?(ac, "description")
    end

    test "handles nil acceptance_criteria gracefully" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      payload = base_payload(%{"acceptance_criteria" => nil})

      assert {:ok, _summary} = run_import(tenant.id, project.id, payload)
    end

    test "handles empty acceptance_criteria list" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      payload = base_payload(%{"acceptance_criteria" => []})

      assert {:ok, _summary} = run_import(tenant.id, project.id, payload)
    end

    test "normalizes multiple AC items in one story" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      payload =
        base_payload(%{
          "acceptance_criteria" => [
            %{"id" => "AC-1", "description" => "First criterion"},
            %{"criterion" => "Second criterion"},
            %{"id" => "AC-3", "description" => "Third criterion"}
          ]
        })

      assert {:ok, _summary} = run_import(tenant.id, project.id, payload)

      story = Loopctl.AdminRepo.get_by!(Loopctl.WorkBreakdown.Story, number: "1.1")
      acs = story.acceptance_criteria
      assert length(acs) == 3
      assert Enum.all?(acs, &Map.has_key?(&1, "criterion"))
      refute Enum.any?(acs, &Map.has_key?(&1, "description"))
    end
  end

  describe "better validation error messages (Issue 3)" do
    test "returns helpful message when acceptance_criteria is not a list" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      payload = base_payload(%{"acceptance_criteria" => "not a list"})

      assert {:error, :validation, message} = run_import(tenant.id, project.id, payload)

      assert message =~ "acceptance_criteria"
      assert message =~ "array"
      assert message =~ "id"
      assert message =~ "description"
      # Should include example
      assert message =~ "AC-1"
    end

    test "returns helpful message when acceptance_criteria items are not objects" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      payload = base_payload(%{"acceptance_criteria" => ["plain string", "another"]})

      assert {:error, :validation, message} = run_import(tenant.id, project.id, payload)

      assert message =~ "acceptance_criteria"
      assert message =~ "objects"
    end

    test "includes path context in error message" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      payload =
        base_payload(%{
          "acceptance_criteria" => "invalid"
        })

      assert {:error, :validation, message} = run_import(tenant.id, project.id, payload)

      # The path like epics[0].stories[0] should appear
      assert message =~ "epics[0]"
      assert message =~ "stories[0]"
    end
  end
end
