defmodule Loopctl.QualityAssuranceTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.QualityAssurance

  # --- Setup helpers ---

  defp setup_project do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
    %{tenant: tenant, project: project, agent: agent}
  end

  # --- start_ui_test/4 ---

  describe "start_ui_test/4" do
    test "creates a run with status in_progress" do
      %{tenant: tenant, project: project, agent: agent} = setup_project()

      assert {:ok, run} =
               QualityAssurance.start_ui_test(
                 tenant.id,
                 project.id,
                 %{"guide_reference" => "docs/guides/checkout.md"},
                 agent_id: agent.id,
                 actor_id: agent.id,
                 actor_label: "agent:test"
               )

      assert run.tenant_id == tenant.id
      assert run.project_id == project.id
      assert run.started_by_agent_id == agent.id
      assert run.status == :in_progress
      assert run.guide_reference == "docs/guides/checkout.md"
      assert run.findings == []
      assert run.findings_count == 0
      assert run.critical_count == 0
      assert run.high_count == 0
      assert run.screenshots_count == 0
      assert run.summary == nil
      assert run.completed_at == nil
      assert run.started_at != nil
    end

    test "creates a run without an agent_id" do
      %{tenant: tenant, project: project} = setup_project()

      assert {:ok, run} =
               QualityAssurance.start_ui_test(
                 tenant.id,
                 project.id,
                 %{"guide_reference" => "docs/guides/login.md"}
               )

      assert run.started_by_agent_id == nil
      assert run.status == :in_progress
    end

    test "returns error when guide_reference is missing" do
      %{tenant: tenant, project: project} = setup_project()

      assert {:error, changeset} =
               QualityAssurance.start_ui_test(tenant.id, project.id, %{})

      assert errors_on(changeset)[:guide_reference] != nil
    end

    test "returns error when guide_reference is blank" do
      %{tenant: tenant, project: project} = setup_project()

      assert {:error, changeset} =
               QualityAssurance.start_ui_test(
                 tenant.id,
                 project.id,
                 %{"guide_reference" => ""}
               )

      assert errors_on(changeset)[:guide_reference] != nil
    end

    test "writes an audit log entry" do
      %{tenant: tenant, project: project} = setup_project()

      assert {:ok, run} =
               QualityAssurance.start_ui_test(
                 tenant.id,
                 project.id,
                 %{"guide_reference" => "docs/guides/test.md"},
                 actor_id: Ecto.UUID.generate(),
                 actor_label: "agent:worker"
               )

      import Ecto.Query
      alias Loopctl.AdminRepo
      alias Loopctl.Audit.AuditLog

      log =
        AdminRepo.one(
          from(a in AuditLog,
            where: a.tenant_id == ^tenant.id and a.entity_id == ^run.id,
            order_by: [desc: a.inserted_at],
            limit: 1
          )
        )

      assert log != nil
      assert log.action == "ui_test.started"
      assert log.entity_type == "ui_test_run"
    end
  end

  # --- add_finding/3 ---

  describe "add_finding/3" do
    test "appends a finding and increments counts" do
      %{tenant: tenant, project: project} = setup_project()
      run = fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})

      finding_params = %{
        "step" => "2. Click checkout",
        "severity" => "critical",
        "type" => "crash",
        "description" => "Page crashes on click",
        "screenshot_path" => "screenshots/crash.png",
        "console_errors" => "TypeError: null"
      }

      assert {:ok, updated} = QualityAssurance.add_finding(tenant.id, run.id, finding_params)

      assert length(updated.findings) == 1
      assert updated.findings_count == 1
      assert updated.critical_count == 1
      assert updated.high_count == 0
      assert updated.screenshots_count == 1

      finding = List.first(updated.findings)
      assert finding["step"] == "2. Click checkout"
      assert finding["severity"] == "critical"
      assert finding["type"] == "crash"
      assert finding["description"] == "Page crashes on click"
      assert finding["screenshot_path"] == "screenshots/crash.png"
      assert finding["console_errors"] == "TypeError: null"
      assert finding["recorded_at"] != nil
    end

    test "increments high_count for high severity findings" do
      %{tenant: tenant, project: project} = setup_project()
      run = fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})

      assert {:ok, updated} =
               QualityAssurance.add_finding(tenant.id, run.id, %{
                 "severity" => "high",
                 "description" => "Wrong label"
               })

      assert updated.high_count == 1
      assert updated.critical_count == 0
    end

    test "does not increment high_count for medium findings" do
      %{tenant: tenant, project: project} = setup_project()
      run = fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})

      assert {:ok, updated} =
               QualityAssurance.add_finding(tenant.id, run.id, %{"severity" => "medium"})

      assert updated.high_count == 0
      assert updated.critical_count == 0
      assert updated.findings_count == 1
    end

    test "accumulates multiple findings correctly" do
      %{tenant: tenant, project: project} = setup_project()
      run = fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})

      {:ok, run} = QualityAssurance.add_finding(tenant.id, run.id, %{"severity" => "critical"})
      {:ok, run} = QualityAssurance.add_finding(tenant.id, run.id, %{"severity" => "high"})
      {:ok, run} = QualityAssurance.add_finding(tenant.id, run.id, %{"severity" => "medium"})

      assert run.findings_count == 3
      assert run.critical_count == 1
      assert run.high_count == 1
    end

    test "does not increment screenshots_count when screenshot_path is nil" do
      %{tenant: tenant, project: project} = setup_project()
      run = fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})

      assert {:ok, updated} =
               QualityAssurance.add_finding(tenant.id, run.id, %{
                 "severity" => "low",
                 "screenshot_path" => nil
               })

      assert updated.screenshots_count == 0
    end

    test "returns error when run does not exist" do
      %{tenant: tenant} = setup_project()

      assert {:error, :not_found} =
               QualityAssurance.add_finding(tenant.id, Ecto.UUID.generate(), %{})
    end

    test "returns error when run is not in progress" do
      %{tenant: tenant, project: project} = setup_project()

      run =
        fixture(:ui_test_run, %{
          tenant_id: tenant.id,
          project_id: project.id,
          status: :passed
        })

      assert {:error, :run_not_in_progress} =
               QualityAssurance.add_finding(tenant.id, run.id, %{"description" => "too late"})
    end

    test "returns error when run is failed" do
      %{tenant: tenant, project: project} = setup_project()

      run =
        fixture(:ui_test_run, %{
          tenant_id: tenant.id,
          project_id: project.id,
          status: :failed
        })

      assert {:error, :run_not_in_progress} =
               QualityAssurance.add_finding(tenant.id, run.id, %{"description" => "too late"})
    end

    test "writes an audit log entry" do
      %{tenant: tenant, project: project} = setup_project()
      run = fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})

      {:ok, updated} =
        QualityAssurance.add_finding(tenant.id, run.id, %{
          "severity" => "high",
          "description" => "Wrong color"
        })

      import Ecto.Query
      alias Loopctl.AdminRepo
      alias Loopctl.Audit.AuditLog

      log =
        AdminRepo.one(
          from(a in AuditLog,
            where: a.tenant_id == ^tenant.id and a.entity_id == ^updated.id,
            where: a.action == "ui_test.finding_added",
            limit: 1
          )
        )

      assert log != nil
    end
  end

  # --- complete_ui_test/4 ---

  describe "complete_ui_test/4" do
    test "completes a run with passed status" do
      %{tenant: tenant, project: project} = setup_project()
      run = fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})

      assert {:ok, completed} =
               QualityAssurance.complete_ui_test(
                 tenant.id,
                 run.id,
                 %{"status" => "passed", "summary" => "All flows passed successfully."}
               )

      assert completed.status == :passed
      assert completed.summary == "All flows passed successfully."
      assert completed.completed_at != nil
    end

    test "completes a run with failed status" do
      %{tenant: tenant, project: project} = setup_project()
      run = fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})

      assert {:ok, completed} =
               QualityAssurance.complete_ui_test(
                 tenant.id,
                 run.id,
                 %{"status" => "failed", "summary" => "Found 3 critical bugs."}
               )

      assert completed.status == :failed
      assert completed.summary == "Found 3 critical bugs."
    end

    test "returns error when summary is missing" do
      %{tenant: tenant, project: project} = setup_project()
      run = fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})

      assert {:error, changeset} =
               QualityAssurance.complete_ui_test(
                 tenant.id,
                 run.id,
                 %{"status" => "passed"}
               )

      assert errors_on(changeset)[:summary] != nil
    end

    test "returns error when status is invalid" do
      %{tenant: tenant, project: project} = setup_project()
      run = fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})

      assert {:error, changeset} =
               QualityAssurance.complete_ui_test(
                 tenant.id,
                 run.id,
                 %{"status" => "in_progress", "summary" => "summary"}
               )

      assert errors_on(changeset)[:status] != nil
    end

    test "returns error when run is already completed" do
      %{tenant: tenant, project: project} = setup_project()

      run =
        fixture(:ui_test_run, %{
          tenant_id: tenant.id,
          project_id: project.id,
          status: :passed
        })

      assert {:error, :run_not_in_progress} =
               QualityAssurance.complete_ui_test(
                 tenant.id,
                 run.id,
                 %{"status" => "failed", "summary" => "Cannot complete twice"}
               )
    end

    test "returns error when run does not exist" do
      %{tenant: tenant} = setup_project()

      assert {:error, :not_found} =
               QualityAssurance.complete_ui_test(
                 tenant.id,
                 Ecto.UUID.generate(),
                 %{"status" => "passed", "summary" => "summary"}
               )
    end

    test "writes an audit log entry" do
      %{tenant: tenant, project: project} = setup_project()
      run = fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})

      {:ok, completed} =
        QualityAssurance.complete_ui_test(
          tenant.id,
          run.id,
          %{"status" => "passed", "summary" => "All passed"},
          actor_id: Ecto.UUID.generate(),
          actor_label: "agent:review"
        )

      import Ecto.Query
      alias Loopctl.AdminRepo
      alias Loopctl.Audit.AuditLog

      log =
        AdminRepo.one(
          from(a in AuditLog,
            where: a.tenant_id == ^tenant.id and a.entity_id == ^completed.id,
            where: a.action == "ui_test.completed",
            limit: 1
          )
        )

      assert log != nil
    end
  end

  # --- list_ui_tests/3 ---

  describe "list_ui_tests/3" do
    test "returns all runs for a project" do
      %{tenant: tenant, project: project} = setup_project()
      fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})
      fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})

      {:ok, result} = QualityAssurance.list_ui_tests(tenant.id, project.id)

      assert result.total == 2
      assert length(result.data) == 2
    end

    test "filters by status" do
      %{tenant: tenant, project: project} = setup_project()
      fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id, status: :passed})
      fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id, status: :failed})
      fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})

      {:ok, result} = QualityAssurance.list_ui_tests(tenant.id, project.id, status: :passed)

      assert result.total == 1
      assert Enum.all?(result.data, &(&1.status == :passed))
    end

    test "respects limit and offset" do
      %{tenant: tenant, project: project} = setup_project()

      Enum.each(1..5, fn _ ->
        fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})
      end)

      {:ok, result} = QualityAssurance.list_ui_tests(tenant.id, project.id, limit: 2, offset: 0)

      assert result.total == 5
      assert length(result.data) == 2
      assert result.limit == 2
      assert result.offset == 0
    end

    test "returns empty list for project with no runs" do
      %{tenant: tenant, project: project} = setup_project()

      {:ok, result} = QualityAssurance.list_ui_tests(tenant.id, project.id)

      assert result.total == 0
      assert result.data == []
    end

    test "does not return runs from another project" do
      %{tenant: tenant, project: project} = setup_project()
      other_project = fixture(:project, %{tenant_id: tenant.id})
      fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: other_project.id})

      {:ok, result} = QualityAssurance.list_ui_tests(tenant.id, project.id)

      assert result.total == 0
    end
  end

  # --- get_ui_test/2 ---

  describe "get_ui_test/2" do
    test "returns the run when found" do
      %{tenant: tenant, project: project} = setup_project()
      run = fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})

      assert {:ok, found} = QualityAssurance.get_ui_test(tenant.id, run.id)
      assert found.id == run.id
    end

    test "returns error when run does not exist" do
      %{tenant: tenant} = setup_project()

      assert {:error, :not_found} = QualityAssurance.get_ui_test(tenant.id, Ecto.UUID.generate())
    end
  end

  # --- Tenant isolation ---

  describe "tenant isolation" do
    test "tenant A cannot see tenant B's runs" do
      tenant_a = fixture(:tenant)
      project_a = fixture(:project, %{tenant_id: tenant_a.id})

      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})

      run_b = fixture(:ui_test_run, %{tenant_id: tenant_b.id, project_id: project_b.id})

      # Tenant A cannot get tenant B's run
      assert {:error, :not_found} = QualityAssurance.get_ui_test(tenant_a.id, run_b.id)

      # Tenant A's project list is empty
      {:ok, result} = QualityAssurance.list_ui_tests(tenant_a.id, project_a.id)
      assert result.total == 0
    end

    test "tenant A cannot add findings to tenant B's run" do
      tenant_a = fixture(:tenant)

      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      run_b = fixture(:ui_test_run, %{tenant_id: tenant_b.id, project_id: project_b.id})

      assert {:error, :not_found} =
               QualityAssurance.add_finding(tenant_a.id, run_b.id, %{"severity" => "critical"})
    end

    test "tenant A cannot complete tenant B's run" do
      tenant_a = fixture(:tenant)

      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      run_b = fixture(:ui_test_run, %{tenant_id: tenant_b.id, project_id: project_b.id})

      assert {:error, :not_found} =
               QualityAssurance.complete_ui_test(
                 tenant_a.id,
                 run_b.id,
                 %{"status" => "passed", "summary" => "Sneaky"}
               )
    end
  end

  # --- Full lifecycle ---

  describe "full start → findings → complete lifecycle" do
    test "complete flow from start to completion" do
      %{tenant: tenant, project: project, agent: agent} = setup_project()

      # Start
      {:ok, run} =
        QualityAssurance.start_ui_test(
          tenant.id,
          project.id,
          %{"guide_reference" => "docs/guides/full_flow.md"},
          agent_id: agent.id
        )

      assert run.status == :in_progress

      # Add findings
      {:ok, run} =
        QualityAssurance.add_finding(tenant.id, run.id, %{
          "severity" => "critical",
          "type" => "crash",
          "description" => "Critical crash on load"
        })

      {:ok, run} =
        QualityAssurance.add_finding(tenant.id, run.id, %{
          "severity" => "high",
          "type" => "wrong_behavior",
          "description" => "Button disabled incorrectly",
          "screenshot_path" => "screenshots/btn.png"
        })

      assert run.findings_count == 2
      assert run.critical_count == 1
      assert run.high_count == 1
      assert run.screenshots_count == 1

      # Complete
      {:ok, completed} =
        QualityAssurance.complete_ui_test(
          tenant.id,
          run.id,
          %{"status" => "failed", "summary" => "2 critical issues found"}
        )

      assert completed.status == :failed
      assert completed.summary == "2 critical issues found"
      assert completed.completed_at != nil
      assert completed.findings_count == 2
    end
  end
end
