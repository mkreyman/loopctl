defmodule Loopctl.TokenUsage.DefaultArchivalTest do
  @moduledoc """
  Integration tests for DefaultArchival.

  Because DefaultArchival uses Repo.with_tenant (RLS-enforced Repo transactions),
  all test data is inserted via Repo (not AdminRepo) so that it is visible within
  the same DB connection context. async: false is required for shared sandbox mode.
  """

  # Must be async: false — DefaultArchival uses Repo.with_tenant which requires
  # the sandbox owner to be shared so that data and FKs are visible in both
  # the test process's Repo connection and the DefaultArchival Repo transactions.
  use Loopctl.DataCase, async: false

  alias Loopctl.Agents.Agent
  alias Loopctl.Projects.Project
  alias Loopctl.Repo
  alias Loopctl.Tenants.Tenant
  alias Loopctl.TokenUsage.CostAnomaly
  alias Loopctl.TokenUsage.DefaultArchival
  alias Loopctl.TokenUsage.Report
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.Story

  # --------------------------------------------------------------------------
  # Private helpers: create all data via Repo so it's on the same DB connection
  # as Repo.with_tenant operations inside DefaultArchival.
  # --------------------------------------------------------------------------

  defp repo_tenant do
    seq = System.unique_integer([:positive])

    %Tenant{}
    |> Tenant.create_changeset(%{
      name: "Test Tenant #{seq}",
      slug: "test-tenant-#{seq}",
      email: "test-#{seq}@example.com",
      settings: %{},
      status: :active
    })
    |> Repo.insert!()
  end

  defp repo_project(tenant_id) do
    seq = System.unique_integer([:positive])

    %Project{tenant_id: tenant_id}
    |> Project.create_changeset(%{
      name: "Project #{seq}",
      slug: "project-#{seq}",
      repo_url: "https://github.com/example/project-#{seq}",
      description: "test",
      tech_stack: "elixir",
      metadata: %{}
    })
    |> Repo.insert!()
  end

  defp repo_epic(tenant_id, project_id) do
    seq = System.unique_integer([:positive])

    %Epic{tenant_id: tenant_id, project_id: project_id}
    |> Epic.create_changeset(%{
      number: seq,
      title: "Epic #{seq}",
      description: "test",
      phase: "p0_foundation",
      position: 0,
      metadata: %{}
    })
    |> Repo.insert!()
  end

  defp repo_story(tenant_id, project_id, epic_id) do
    seq = System.unique_integer([:positive])
    minor = rem(seq, 9999) + 1

    %Story{tenant_id: tenant_id, project_id: project_id, epic_id: epic_id}
    |> Story.create_changeset(%{
      number: "1.#{minor}",
      title: "Story #{seq}",
      description: "test",
      acceptance_criteria: [],
      metadata: %{}
    })
    |> Repo.insert!()
  end

  defp repo_agent(tenant_id) do
    seq = System.unique_integer([:positive])

    %Agent{tenant_id: tenant_id}
    |> Agent.register_changeset(%{
      name: "agent-#{seq}",
      agent_type: :implementer,
      metadata: %{}
    })
    |> Repo.insert!()
  end

  defp make_context do
    tenant = repo_tenant()
    project = repo_project(tenant.id)
    epic = repo_epic(tenant.id, project.id)
    story = repo_story(tenant.id, project.id, epic.id)
    agent = repo_agent(tenant.id)
    %{tenant: tenant, project: project, epic: epic, story: story, agent: agent}
  end

  # Insert a token usage report via Repo.with_tenant
  defp insert_report(ctx) do
    {:ok, report} =
      Repo.with_tenant(ctx.tenant.id, fn ->
        %Report{
          tenant_id: ctx.tenant.id,
          story_id: ctx.story.id,
          agent_id: ctx.agent.id,
          project_id: ctx.project.id
        }
        |> Report.create_changeset(%{
          input_tokens: 100,
          output_tokens: 50,
          model_name: "claude-opus-4",
          cost_millicents: 500
        })
        |> Repo.insert!()
      end)

    report
  end

  # Backdate a report's inserted_at
  defp backdate_report(report, days_ago) do
    past = DateTime.add(DateTime.utc_now(), -days_ago * 86_400, :second)
    report |> Ecto.Changeset.change(inserted_at: past) |> Repo.update!()
  end

  # Soft-delete a report via Repo
  defp soft_delete_report(report, days_ago \\ 0) do
    deleted_at = DateTime.add(DateTime.utc_now(), -days_ago * 86_400, :second)
    report |> Ecto.Changeset.change(deleted_at: deleted_at) |> Repo.update!()
  end

  # Insert a cost anomaly via Repo.with_tenant
  defp insert_anomaly(ctx, anomaly_type \\ :high_cost) do
    {:ok, anomaly} =
      Repo.with_tenant(ctx.tenant.id, fn ->
        %CostAnomaly{tenant_id: ctx.tenant.id, story_id: ctx.story.id}
        |> CostAnomaly.create_changeset(%{
          anomaly_type: anomaly_type,
          story_cost_millicents: 75_000,
          reference_avg_millicents: 25_000,
          deviation_factor: Decimal.new("3.0")
        })
        |> Repo.insert!()
      end)

    anomaly
  end

  # Backdate an anomaly's inserted_at
  defp backdate_anomaly(anomaly, days_ago) do
    past = DateTime.add(DateTime.utc_now(), -days_ago * 86_400, :second)
    anomaly |> Ecto.Changeset.change(inserted_at: past) |> Repo.update!()
  end

  # --------------------------------------------------------------------------

  describe "soft_delete_old_reports/2" do
    test "soft-deletes reports older than retention_days" do
      ctx = make_context()

      old_report = insert_report(ctx)
      backdate_report(old_report, 100)

      # Recent report — should NOT be soft-deleted
      _recent = insert_report(ctx)

      assert {:ok, 1} = DefaultArchival.soft_delete_old_reports(ctx.tenant.id, 90)

      updated = Repo.get!(Report, old_report.id)
      assert updated.deleted_at != nil
    end

    test "does not re-delete already soft-deleted reports" do
      ctx = make_context()
      report = insert_report(ctx)
      backdate_report(report, 100)
      soft_delete_report(report)

      assert {:ok, 0} = DefaultArchival.soft_delete_old_reports(ctx.tenant.id, 90)
    end

    test "tenant isolation: only soft-deletes reports for the given tenant" do
      ctx_a = make_context()
      ctx_b = make_context()

      report_a = insert_report(ctx_a)
      backdate_report(report_a, 100)

      report_b = insert_report(ctx_b)
      backdate_report(report_b, 100)

      assert {:ok, 1} = DefaultArchival.soft_delete_old_reports(ctx_a.tenant.id, 90)

      # Verify tenant_a's report is soft-deleted — use with_tenant since SET LOCAL ROLE
      # persists in the sandbox outer transaction after DefaultArchival runs.
      {:ok, fetched_a} =
        Repo.with_tenant(ctx_a.tenant.id, fn -> Repo.get!(Report, report_a.id) end)

      assert fetched_a.deleted_at != nil

      # Verify tenant_b's report is untouched
      {:ok, fetched_b} =
        Repo.with_tenant(ctx_b.tenant.id, fn -> Repo.get!(Report, report_b.id) end)

      assert fetched_b.deleted_at == nil
    end

    test "returns 0 when no reports qualify" do
      ctx = make_context()
      assert {:ok, 0} = DefaultArchival.soft_delete_old_reports(ctx.tenant.id, 30)
    end
  end

  describe "hard_delete_expired_reports/1" do
    test "permanently removes reports deleted more than 30 days ago" do
      ctx = make_context()
      report = insert_report(ctx)
      soft_delete_report(report, 31)

      assert {:ok, 1} = DefaultArchival.hard_delete_expired_reports(ctx.tenant.id)

      assert Repo.get(Report, report.id) == nil
    end

    test "does not delete reports soft-deleted within grace period" do
      ctx = make_context()
      report = insert_report(ctx)
      soft_delete_report(report, 10)

      assert {:ok, 0} = DefaultArchival.hard_delete_expired_reports(ctx.tenant.id)

      assert Repo.get(Report, report.id) != nil
    end

    test "does not delete reports that are not soft-deleted" do
      ctx = make_context()
      report = insert_report(ctx)

      assert {:ok, 0} = DefaultArchival.hard_delete_expired_reports(ctx.tenant.id)

      assert Repo.get(Report, report.id) != nil
    end

    test "tenant isolation: only hard-deletes for the given tenant" do
      ctx_a = make_context()
      ctx_b = make_context()

      report_a = insert_report(ctx_a)
      soft_delete_report(report_a, 31)

      report_b = insert_report(ctx_b)
      soft_delete_report(report_b, 31)

      assert {:ok, 1} = DefaultArchival.hard_delete_expired_reports(ctx_a.tenant.id)

      # report_a was hard-deleted — with_tenant for ctx_a should find nothing
      {:ok, fetched_a} =
        Repo.with_tenant(ctx_a.tenant.id, fn -> Repo.get(Report, report_a.id) end)

      assert fetched_a == nil

      # report_b still exists — with_tenant for ctx_b should find it
      {:ok, fetched_b} =
        Repo.with_tenant(ctx_b.tenant.id, fn -> Repo.get(Report, report_b.id) end)

      assert fetched_b != nil
    end
  end

  describe "archive_old_anomalies/2" do
    test "archives anomalies older than retention_days" do
      ctx = make_context()

      old_anomaly = insert_anomaly(ctx)
      backdate_anomaly(old_anomaly, 100)

      _recent = insert_anomaly(ctx, :suspiciously_low)

      assert {:ok, 1} = DefaultArchival.archive_old_anomalies(ctx.tenant.id, 90)

      assert Repo.get!(CostAnomaly, old_anomaly.id).archived == true
    end

    test "does not re-archive already archived anomalies" do
      ctx = make_context()
      anomaly = insert_anomaly(ctx)
      backdate_anomaly(anomaly, 100)
      anomaly |> Ecto.Changeset.change(archived: true) |> Repo.update!()

      assert {:ok, 0} = DefaultArchival.archive_old_anomalies(ctx.tenant.id, 90)
    end

    test "tenant isolation: only archives anomalies for the given tenant" do
      ctx_a = make_context()
      ctx_b = make_context()

      anomaly_a = insert_anomaly(ctx_a)
      backdate_anomaly(anomaly_a, 100)

      anomaly_b = insert_anomaly(ctx_b)
      backdate_anomaly(anomaly_b, 100)

      assert {:ok, 1} = DefaultArchival.archive_old_anomalies(ctx_a.tenant.id, 90)

      # Use with_tenant for each tenant to read through the RLS-enforced Repo
      {:ok, fetched_a} =
        Repo.with_tenant(ctx_a.tenant.id, fn -> Repo.get!(CostAnomaly, anomaly_a.id) end)

      assert fetched_a.archived == true

      {:ok, fetched_b} =
        Repo.with_tenant(ctx_b.tenant.id, fn -> Repo.get!(CostAnomaly, anomaly_b.id) end)

      assert fetched_b.archived == false
    end
  end
end
