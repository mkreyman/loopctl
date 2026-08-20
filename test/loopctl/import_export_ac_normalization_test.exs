defmodule Loopctl.ImportExportAcNormalizationTest do
  @moduledoc """
  Tests for Issues 2 and 3:
  - Issue 2: AC normalization (description → criterion mapping)
  - Issue 3: Better import error messages for acceptance_criteria
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.ImportExport

  defp base_payload(story_attrs) do
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
      assert message =~ "must be an object"

      # The message now LOCATES the offending entry rather than describing the
      # array generically, so an import carrying 40 criteria names which one is
      # wrong. Asserting the index is what keeps that specific.
      assert message =~ "acceptance_criteria[0]"
      assert message =~ "not a string"
    end

    test "a criterion carrying no text at all is rejected, and located" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      # `%{}` and `%{"note" => ...}` both used to pass: the old guard checked only
      # `is_map/1` while printing an error claiming 'id' and 'description' were
      # required. A textless criterion normalizes into the story with nothing for
      # verify_story to be judged against, which is the defect that mattered.
      payload =
        base_payload(%{
          "acceptance_criteria" => [
            %{"id" => "AC-1", "description" => "Feature works"},
            %{"id" => "AC-2", "note" => "tbd"}
          ]
        })

      assert {:error, :validation, message} = run_import(tenant.id, project.id, payload)

      assert message =~ "acceptance_criteria[1]"
      assert message =~ "description"
      assert message =~ "criterion"
    end

    test "a criterion with a blank description is rejected" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      payload =
        base_payload(%{"acceptance_criteria" => [%{"id" => "AC-1", "description" => "   "}]})

      assert {:error, :validation, message} = run_import(tenant.id, project.id, payload)
      assert message =~ "acceptance_criteria[0]"
    end

    test "the 'criterion' key alone still satisfies the text requirement (#509)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      # Regression guard. This endpoint has accepted `criterion` as an alternative
      # to `description` since #509 and has never required `id`; tightening the
      # textless check must not quietly re-impose either.
      payload = base_payload(%{"acceptance_criteria" => [%{"criterion" => "Feature works"}]})

      assert {:ok, _summary} = run_import(tenant.id, project.id, payload)
    end

    test "an AC-less story still imports, so backfill of pre-loopctl work keeps working" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      # Deliberate, not an oversight: importing a skeleton for historical work is a
      # supported path (backfill_story / bulk_mark_complete). The "a story must have
      # criteria" rule belongs at the verify gate, not at the import boundary, and
      # enforcing it here would break backfill to close a hole it does not close.
      # A separate project per import: the same epic/story numbers imported twice
      # into ONE project is a duplicate-number conflict, which would fail this test
      # for a reason that has nothing to do with acceptance criteria.
      other = fixture(:project, %{tenant_id: tenant.id})

      assert {:ok, _} = run_import(tenant.id, project.id, base_payload(%{}))

      assert {:ok, _} =
               run_import(tenant.id, other.id, base_payload(%{"acceptance_criteria" => []}))
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
