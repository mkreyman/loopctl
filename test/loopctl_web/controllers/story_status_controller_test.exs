defmodule LoopctlWeb.StoryStatusControllerTest do
  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Skills
  alias Loopctl.TokenUsage
  alias Loopctl.TokenUsage.Budget
  alias Loopctl.TokenUsage.Report
  alias Loopctl.Webhooks
  alias Loopctl.Webhooks.WebhookEvent

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  # Puts a story into :implementing (assigned to the implementer) and mints a
  # DIFFERENT reviewer agent + key so cross-agent report calls succeed
  # (chain-of-custody). Returns the base context plus :reviewer / :reviewer_key.
  defp implementing_story_with_reviewer(attrs \\ %{}) do
    ctx = setup_story_with_agent(attrs)

    story =
      ctx.story
      |> Ecto.Changeset.change(%{
        agent_status: :implementing,
        assigned_agent_id: ctx.agent.id,
        assigned_at: DateTime.utc_now()
      })
      |> AdminRepo.update!()

    reviewer = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :implementer})

    {reviewer_key, _} =
      fixture(:api_key, %{tenant_id: ctx.tenant.id, role: :agent, agent_id: reviewer.id})

    ctx
    |> Map.put(:story, story)
    |> Map.put(:reviewer, reviewer)
    |> Map.put(:reviewer_key, reviewer_key)
  end

  defp token_usage_payload(overrides) do
    Map.merge(
      %{
        "input_tokens" => 1000,
        "output_tokens" => 500,
        "model_name" => "claude-opus-4",
        "cost_millicents" => 8_500
      },
      overrides
    )
  end

  defp create_webhook_for_events(tenant_id, events) do
    {:ok, %{webhook: webhook}} =
      Webhooks.create_webhook(tenant_id, %{
        "url" => "https://example.com/hooks/#{System.unique_integer([:positive])}",
        "events" => events
      })

    webhook
  end

  defp find_webhook_events(tenant_id, event_type) do
    WebhookEvent
    |> where([e], e.tenant_id == ^tenant_id and e.event_type == ^event_type)
    |> AdminRepo.all()
  end

  defp threshold_crossed_entries(tenant_id, budget_id, threshold_type) do
    AuditLog
    |> where([a], a.tenant_id == ^tenant_id and a.entity_type == "token_budget")
    |> where([a], a.action == "threshold_crossed" and a.entity_id == ^budget_id)
    |> AdminRepo.all()
    |> Enum.filter(fn e -> e.metadata["threshold_type"] == threshold_type end)
  end

  defp same_tenant_skill_version(tenant_id) do
    skill =
      fixture(:skill, %{
        tenant_id: tenant_id,
        name: "skill-#{System.unique_integer([:positive])}"
      })

    {:ok, version} = Skills.get_version(tenant_id, skill.id, 1)
    version
  end

  defp setup_story_with_agent(attrs \\ %{}) do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

    {raw_key, api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

    story_attrs =
      Map.merge(
        %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          title: "Phoenix scaffold",
          acceptance_criteria: [
            %{"id" => "AC-1", "description" => "App boots"},
            %{"id" => "AC-2", "description" => "Tests pass"}
          ]
        },
        attrs
      )

    story = fixture(:story, story_attrs)

    %{
      tenant: tenant,
      project: project,
      epic: epic,
      agent: agent,
      api_key: api_key,
      raw_key: raw_key,
      story: story
    }
  end

  # --- Contract tests ---

  describe "POST /api/v1/stories/:id/contract" do
    test "contracts a story with correct title and AC count", %{conn: conn} do
      %{story: story, raw_key: raw_key} = setup_story_with_agent()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/contract", %{
          "story_title" => "Phoenix scaffold",
          "ac_count" => 2
        })

      body = json_response(conn, 200)
      assert body["story"]["agent_status"] == "contracted"
      assert body["story"]["id"] == story.id
    end

    test "rejects with wrong title (422)", %{conn: conn} do
      %{story: story, raw_key: raw_key} = setup_story_with_agent()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/contract", %{
          "story_title" => "Wrong title",
          "ac_count" => 2
        })

      assert json_response(conn, 422)
    end

    test "rejects with wrong AC count (422)", %{conn: conn} do
      %{story: story, raw_key: raw_key} = setup_story_with_agent()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/contract", %{
          "story_title" => "Phoenix scaffold",
          "ac_count" => 5
        })

      assert json_response(conn, 422)
    end

    test "rejects contract on non-pending story (409)", %{conn: conn} do
      %{story: story, raw_key: raw_key} =
        setup_story_with_agent(%{agent_status: :contracted})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/contract", %{
          "story_title" => story.title,
          "ac_count" => length(story.acceptance_criteria)
        })

      assert json_response(conn, 409)
    end

    test "creates audit log entry", %{conn: conn} do
      %{story: story, raw_key: raw_key, tenant: tenant} = setup_story_with_agent()

      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/stories/#{story.id}/contract", %{
        "story_title" => "Phoenix scaffold",
        "ac_count" => 2
      })

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "story", entity_id: story.id)

      assert result.data != []
      audit = Enum.find(result.data, &(&1.action == "status_changed"))
      assert audit.old_state["agent_status"] == "pending"
      assert audit.new_state["agent_status"] == "contracted"
    end
  end

  # --- Claim tests ---

  describe "POST /api/v1/stories/:id/claim" do
    test "claims a contracted story", %{conn: conn} do
      %{story: story, raw_key: raw_key, agent: agent} =
        setup_story_with_agent(%{agent_status: :contracted})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/claim")

      body = json_response(conn, 200)
      assert body["story"]["agent_status"] == "assigned"
      assert body["story"]["assigned_agent_id"] == agent.id
      assert body["story"]["assigned_at"] != nil
    end

    test "rejects claim on pending story (must contract first, 409)", %{conn: conn} do
      %{story: story, raw_key: raw_key} = setup_story_with_agent()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/claim")

      assert json_response(conn, 409)
    end

    test "rejects claim on already assigned story (409)", %{conn: conn} do
      %{story: story, raw_key: raw_key} =
        setup_story_with_agent(%{agent_status: :assigned})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/claim")

      assert json_response(conn, 409)
    end
  end

  # --- Start tests ---

  describe "POST /api/v1/stories/:id/start" do
    test "starts an assigned story", %{conn: conn} do
      %{story: story, raw_key: raw_key, agent: agent} = setup_story_with_agent()

      # Need to put agent into assigned status with correct agent
      story =
        story
        |> Ecto.Changeset.change(%{
          agent_status: :assigned,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/start")

      body = json_response(conn, 200)
      assert body["story"]["agent_status"] == "implementing"
    end

    test "cross-tenant start returns 404", %{conn: conn} do
      %{story: story, agent: agent} = setup_story_with_agent()

      story =
        story
        |> Ecto.Changeset.change(%{
          agent_status: :assigned,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      # Agent from a completely different tenant
      %{raw_key: other_raw_key} = setup_story_with_agent()

      conn =
        conn
        |> auth_conn(other_raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/start")

      assert json_response(conn, 404)
    end

    test "rejects start on non-assigned story (409)", %{conn: conn} do
      %{story: story, raw_key: raw_key} = setup_story_with_agent()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/start")

      assert json_response(conn, 409)
    end

    test "wrong agent on same tenant gets 403", %{conn: conn} do
      %{story: story, tenant: tenant, agent: agent} = setup_story_with_agent()

      # Assign story to original agent
      story =
        story
        |> Ecto.Changeset.change(%{
          agent_status: :assigned,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      # Create a second agent in same tenant
      other_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      {other_raw_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: other_agent.id})

      conn =
        conn
        |> auth_conn(other_raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/start")

      assert json_response(conn, 403)
    end
  end

  # --- Report tests ---

  describe "POST /api/v1/stories/:id/report" do
    test "cross-agent report succeeds (reviewer != implementer)", %{conn: conn} do
      %{story: story, agent: agent, tenant: tenant} = setup_story_with_agent()

      story =
        story
        |> Ecto.Changeset.change(%{
          agent_status: :implementing,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      # A different agent (reviewer) does the reporting
      reviewer = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      {reviewer_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: reviewer.id})

      conn =
        conn
        |> auth_conn(reviewer_key)
        |> post(~p"/api/v1/stories/#{story.id}/report")

      body = json_response(conn, 200)
      assert body["story"]["agent_status"] == "reported_done"
      assert body["story"]["reported_done_at"] != nil
      assert body["story"]["reported_by_agent_id"] == reviewer.id
    end

    test "self-report blocked (409) — assigned agent cannot report their own work", %{conn: conn} do
      %{story: story, raw_key: raw_key, agent: agent} = setup_story_with_agent()

      story =
        story
        |> Ecto.Changeset.change(%{
          agent_status: :implementing,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/report")

      body = json_response(conn, 409)
      assert body["error"]["status"] == 409
      assert body["error"]["message"] =~ "Cannot report your own implementation"
    end

    test "reports with optional artifact (cross-agent)", %{conn: conn} do
      %{story: story, agent: agent, tenant: tenant} = setup_story_with_agent()

      story =
        story
        |> Ecto.Changeset.change(%{
          agent_status: :implementing,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      reviewer = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      {reviewer_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: reviewer.id})

      conn =
        conn
        |> auth_conn(reviewer_key)
        |> post(~p"/api/v1/stories/#{story.id}/report", %{
          "artifact" => %{
            "artifact_type" => "commit_diff",
            "path" => "abc123",
            "exists" => true,
            "details" => %{"files_changed" => 5}
          }
        })

      body = json_response(conn, 200)
      assert body["story"]["agent_status"] == "reported_done"

      # Verify artifact was created
      artifacts =
        Loopctl.AdminRepo.all(
          from(a in Loopctl.Artifacts.ArtifactReport, where: a.story_id == ^story.id)
        )

      assert length(artifacts) == 1
      artifact = hd(artifacts)
      assert artifact.artifact_type == "commit_diff"
      assert artifact.path == "abc123"
      assert artifact.exists == true
      assert artifact.details == %{"files_changed" => 5}
      assert artifact.reported_by == :agent
      assert artifact.reporter_agent_id == reviewer.id
    end

    test "returns 422 when artifact changeset is invalid (cross-agent)", %{conn: conn} do
      %{story: story, agent: agent, tenant: tenant} = setup_story_with_agent()

      story =
        story
        |> Ecto.Changeset.change(%{
          agent_status: :implementing,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      reviewer = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      {reviewer_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: reviewer.id})

      conn =
        conn
        |> auth_conn(reviewer_key)
        |> post(~p"/api/v1/stories/#{story.id}/report", %{
          "artifact" => %{
            "artifact_type" => "migration",
            "exists" => true
            # Missing required "path" field
          }
        })

      body = json_response(conn, 422)
      assert body["error"]["status"] == 422
    end
  end

  # --- tokens-01: budget thresholds fire on the report_story path ---

  describe "POST /api/v1/stories/:id/report with token_usage — budget alerting (tokens-01)" do
    test "story budget: crossing alert_threshold_pct fires warning (only) + audit + flag",
         %{conn: conn} do
      ctx = implementing_story_with_reviewer()

      _webhook =
        create_webhook_for_events(ctx.tenant.id, [
          "token.budget_warning",
          "token.budget_exceeded"
        ])

      {:ok, budget} =
        TokenUsage.create_budget(ctx.tenant.id, %{
          scope_type: :story,
          scope_id: ctx.story.id,
          budget_millicents: 10_000,
          alert_threshold_pct: 80
        })

      # 8,500 / 10,000 = 85% -> warning fires, exceeded does NOT
      conn =
        conn
        |> auth_conn(ctx.reviewer_key)
        |> post(~p"/api/v1/stories/#{ctx.story.id}/report", %{
          "token_usage" => token_usage_payload(%{"cost_millicents" => 8_500})
        })

      assert json_response(conn, 200)

      assert [_warning_event] = find_webhook_events(ctx.tenant.id, "token.budget_warning")
      assert [] == find_webhook_events(ctx.tenant.id, "token.budget_exceeded")

      assert [_] = threshold_crossed_entries(ctx.tenant.id, budget.id, "warning")
      assert [] == threshold_crossed_entries(ctx.tenant.id, budget.id, "exceeded")

      reloaded = AdminRepo.get!(Budget, budget.id)
      assert reloaded.warning_fired == true
      assert reloaded.exceeded_fired == false
    end

    test "story budget: exceeding 100% fires BOTH warning and exceeded + audit + flags",
         %{conn: conn} do
      ctx = implementing_story_with_reviewer()

      _webhook =
        create_webhook_for_events(ctx.tenant.id, [
          "token.budget_warning",
          "token.budget_exceeded"
        ])

      {:ok, budget} =
        TokenUsage.create_budget(ctx.tenant.id, %{
          scope_type: :story,
          scope_id: ctx.story.id,
          budget_millicents: 5_000,
          alert_threshold_pct: 80
        })

      # 6,000 / 5,000 = 120% -> both warning and exceeded fire
      conn =
        conn
        |> auth_conn(ctx.reviewer_key)
        |> post(~p"/api/v1/stories/#{ctx.story.id}/report", %{
          "token_usage" => token_usage_payload(%{"cost_millicents" => 6_000})
        })

      assert json_response(conn, 200)

      assert [warning_event] = find_webhook_events(ctx.tenant.id, "token.budget_warning")
      assert [exceeded_event] = find_webhook_events(ctx.tenant.id, "token.budget_exceeded")

      assert warning_event.payload["scope_type"] == "story"
      assert exceeded_event.payload["overage_millicents"] == 1_000

      assert [_] = threshold_crossed_entries(ctx.tenant.id, budget.id, "warning")
      assert [_] = threshold_crossed_entries(ctx.tenant.id, budget.id, "exceeded")

      reloaded = AdminRepo.get!(Budget, budget.id)
      assert reloaded.warning_fired == true
      assert reloaded.exceeded_fired == true
    end

    test "epic and project budgets also fire on the report_story path", %{conn: conn} do
      ctx = implementing_story_with_reviewer()

      _webhook =
        create_webhook_for_events(ctx.tenant.id, ["token.budget_exceeded"])

      {:ok, epic_budget} =
        TokenUsage.create_budget(ctx.tenant.id, %{
          scope_type: :epic,
          scope_id: ctx.epic.id,
          budget_millicents: 5_000,
          alert_threshold_pct: 80
        })

      {:ok, project_budget} =
        TokenUsage.create_budget(ctx.tenant.id, %{
          scope_type: :project,
          scope_id: ctx.project.id,
          budget_millicents: 5_000,
          alert_threshold_pct: 80
        })

      conn =
        conn
        |> auth_conn(ctx.reviewer_key)
        |> post(~p"/api/v1/stories/#{ctx.story.id}/report", %{
          "token_usage" => token_usage_payload(%{"cost_millicents" => 6_000})
        })

      assert json_response(conn, 200)

      # Both epic-scope and project-scope budgets produce exceeded events
      assert Enum.count(find_webhook_events(ctx.tenant.id, "token.budget_exceeded")) == 2

      assert [_] = threshold_crossed_entries(ctx.tenant.id, epic_budget.id, "exceeded")
      assert [_] = threshold_crossed_entries(ctx.tenant.id, project_budget.id, "exceeded")

      assert AdminRepo.get!(Budget, epic_budget.id).exceeded_fired == true
      assert AdminRepo.get!(Budget, project_budget.id).exceeded_fired == true
    end

    test "a report under threshold fires nothing", %{conn: conn} do
      ctx = implementing_story_with_reviewer()

      _webhook =
        create_webhook_for_events(ctx.tenant.id, [
          "token.budget_warning",
          "token.budget_exceeded"
        ])

      {:ok, budget} =
        TokenUsage.create_budget(ctx.tenant.id, %{
          scope_type: :story,
          scope_id: ctx.story.id,
          budget_millicents: 100_000,
          alert_threshold_pct: 80
        })

      conn =
        conn
        |> auth_conn(ctx.reviewer_key)
        |> post(~p"/api/v1/stories/#{ctx.story.id}/report", %{
          "token_usage" => token_usage_payload(%{"cost_millicents" => 1_000})
        })

      assert json_response(conn, 200)

      assert [] == find_webhook_events(ctx.tenant.id, "token.budget_warning")
      assert [] == find_webhook_events(ctx.tenant.id, "token.budget_exceeded")
      assert [] == threshold_crossed_entries(ctx.tenant.id, budget.id, "warning")
      assert [] == threshold_crossed_entries(ctx.tenant.id, budget.id, "exceeded")

      reloaded = AdminRepo.get!(Budget, budget.id)
      assert reloaded.warning_fired == false
      assert reloaded.exceeded_fired == false
    end
  end

  # --- tokens-10: cross-tenant skill_version_id rejected on the report path ---

  describe "POST /api/v1/stories/:id/report with token_usage — skill_version ownership (tokens-10)" do
    test "cross-tenant skill_version_id is rejected 422, no report stored, nothing leaked",
         %{conn: conn} do
      ctx = implementing_story_with_reviewer()

      # A skill_version owned by a DIFFERENT tenant.
      other_tenant = fixture(:tenant)
      foreign_version = same_tenant_skill_version(other_tenant.id)

      conn =
        conn
        |> auth_conn(ctx.reviewer_key)
        |> post(~p"/api/v1/stories/#{ctx.story.id}/report", %{
          "token_usage" => token_usage_payload(%{"skill_version_id" => foreign_version.id})
        })

      body = json_response(conn, 422)
      assert body["error"]["status"] == 422
      assert body["error"]["message"] =~ "skill_version_id"

      # No report row was stored for the story.
      assert 0 ==
               Report
               |> where([r], r.story_id == ^ctx.story.id)
               |> AdminRepo.aggregate(:count, :id)

      # And nothing leaks through the read endpoint.
      index_conn =
        build_conn()
        |> auth_conn(ctx.reviewer_key)
        |> get(~p"/api/v1/stories/#{ctx.story.id}/token-usage")

      index_body = json_response(index_conn, 200)
      assert index_body["data"] == []
      assert index_body["meta"]["total_count"] == 0
    end

    test "same-tenant skill_version_id still works", %{conn: conn} do
      ctx = implementing_story_with_reviewer()
      version = same_tenant_skill_version(ctx.tenant.id)

      conn =
        conn
        |> auth_conn(ctx.reviewer_key)
        |> post(~p"/api/v1/stories/#{ctx.story.id}/report", %{
          "token_usage" => token_usage_payload(%{"skill_version_id" => version.id})
        })

      assert json_response(conn, 200)

      report =
        Report
        |> where([r], r.story_id == ^ctx.story.id)
        |> AdminRepo.one()

      assert report.skill_version_id == version.id
    end

    test "nonexistent skill_version_id is rejected 422 with no report stored", %{conn: conn} do
      ctx = implementing_story_with_reviewer()

      conn =
        conn
        |> auth_conn(ctx.reviewer_key)
        |> post(~p"/api/v1/stories/#{ctx.story.id}/report", %{
          "token_usage" => token_usage_payload(%{"skill_version_id" => Ecto.UUID.generate()})
        })

      body = json_response(conn, 422)
      assert body["error"]["status"] == 422

      assert 0 ==
               Report
               |> where([r], r.story_id == ^ctx.story.id)
               |> AdminRepo.aggregate(:count, :id)
    end
  end

  # --- Request Review tests ---

  describe "POST /api/v1/stories/:id/request-review" do
    test "succeeds for the assigned agent on an implementing story", %{conn: conn} do
      %{story: story, raw_key: raw_key, agent: agent} = setup_story_with_agent()

      story =
        story
        |> Ecto.Changeset.change(%{
          agent_status: :implementing,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/request-review")

      body = json_response(conn, 200)
      # Status does NOT change
      assert body["story"]["agent_status"] == "implementing"
      assert body["story"]["id"] == story.id
    end

    test "rejects non-assigned agent (403)", %{conn: conn} do
      %{story: story, agent: agent, tenant: tenant} = setup_story_with_agent()

      story =
        story
        |> Ecto.Changeset.change(%{
          agent_status: :implementing,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      other_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      {other_raw_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: other_agent.id})

      conn =
        conn
        |> auth_conn(other_raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/request-review")

      assert json_response(conn, 403)
    end

    test "rejects wrong status (409)", %{conn: conn} do
      %{story: story, raw_key: raw_key, agent: agent} = setup_story_with_agent()

      # Story is in assigned status, not implementing
      story =
        story
        |> Ecto.Changeset.change(%{
          agent_status: :assigned,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/request-review")

      assert json_response(conn, 409)
    end
  end

  # --- Unclaim tests ---

  describe "POST /api/v1/stories/:id/unclaim" do
    test "unclaims an implementing story back to pending", %{conn: conn} do
      %{story: story, raw_key: raw_key, agent: agent} = setup_story_with_agent()

      story =
        story
        |> Ecto.Changeset.change(%{
          agent_status: :implementing,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/unclaim")

      body = json_response(conn, 200)
      assert body["story"]["agent_status"] == "pending"
      assert body["story"]["assigned_agent_id"] == nil
      assert body["story"]["assigned_at"] == nil
    end

    test "rejects unclaim on pending story (409)", %{conn: conn} do
      %{story: story, raw_key: raw_key} = setup_story_with_agent()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/unclaim")

      assert json_response(conn, 409)
    end

    test "wrong agent cannot unclaim (403)", %{conn: conn} do
      %{story: story, tenant: tenant, agent: agent} = setup_story_with_agent()

      story =
        story
        |> Ecto.Changeset.change(%{
          agent_status: :assigned,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      other_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      {other_raw_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: other_agent.id})

      conn =
        conn
        |> auth_conn(other_raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/unclaim")

      assert json_response(conn, 403)
    end
  end

  # --- Full lifecycle test ---

  describe "full agent lifecycle" do
    test "contract -> claim -> start -> request-review -> report (cross-agent)", %{conn: _conn} do
      %{story: story, raw_key: raw_key, agent: agent, tenant: tenant} =
        setup_story_with_agent()

      # Create a reviewer agent (different from implementer)
      reviewer = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      {reviewer_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: reviewer.id})

      # Contract
      conn1 =
        build_conn()
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/contract", %{
          "story_title" => "Phoenix scaffold",
          "ac_count" => 2
        })

      assert json_response(conn1, 200)["story"]["agent_status"] == "contracted"

      # Claim
      conn2 =
        build_conn()
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/claim")

      body2 = json_response(conn2, 200)
      assert body2["story"]["agent_status"] == "assigned"
      assert body2["story"]["assigned_agent_id"] == agent.id
      assert body2["story"]["assigned_at"] != nil

      # Start
      conn3 =
        build_conn()
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/start")

      assert json_response(conn3, 200)["story"]["agent_status"] == "implementing"

      # Request review (implementer signals readiness)
      conn_rr =
        build_conn()
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/request-review")

      assert json_response(conn_rr, 200)["story"]["agent_status"] == "implementing"

      # Report (reviewer confirms implementation done)
      conn4 =
        build_conn()
        |> auth_conn(reviewer_key)
        |> post(~p"/api/v1/stories/#{story.id}/report")

      body4 = json_response(conn4, 200)
      assert body4["story"]["agent_status"] == "reported_done"
      assert body4["story"]["reported_done_at"] != nil
      assert body4["story"]["reported_by_agent_id"] == reviewer.id

      # Verify 4 audit log entries with action=status_changed (contract, claim, start, report)
      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id,
          entity_type: "story",
          entity_id: story.id,
          action: "status_changed"
        )

      assert length(result.data) == 4
    end
  end

  # --- Role enforcement tests ---

  describe "role enforcement" do
    test "orchestrator role cannot use agent-only endpoints (403)", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {orch_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: orch_agent.id})

      # claim, start, unclaim are agent-only; report and contract allow orchestrator too
      for action <- ["claim", "start", "unclaim"] do
        resp =
          conn
          |> auth_conn(orch_key)
          |> post("/api/v1/stories/#{story.id}/#{action}")

        assert resp.status == 403, "#{action} should require agent role, got #{resp.status}"
      end
    end

    test "orchestrator role can use contract endpoint (skip_contract_check)", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {orch_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: orch_agent.id})

      # Orchestrators skip the title/ac_count validation — any params succeed
      resp =
        conn
        |> auth_conn(orch_key)
        |> post("/api/v1/stories/#{story.id}/contract", %{})

      assert resp.status == 200
      body = json_response(resp, 200)
      assert body["story"]["agent_status"] == "contracted"
    end

    test "user role cannot use agent endpoints (403)", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
      {user_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      for action <- ["contract", "claim", "start", "report", "unclaim"] do
        resp =
          conn
          |> auth_conn(user_key)
          |> post("/api/v1/stories/#{story.id}/#{action}")

        assert resp.status == 403, "#{action} should require agent role, got #{resp.status}"
      end
    end
  end

  # --- Tenant isolation tests ---

  describe "tenant isolation" do
    test "cross-tenant access returns 404", %{conn: conn} do
      # Tenant A with story
      tenant_a = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant_a.id})
      epic = fixture(:epic, %{tenant_id: tenant_a.id, project_id: project.id})

      story =
        fixture(:story, %{tenant_id: tenant_a.id, epic_id: epic.id, agent_status: :contracted})

      # Tenant B with agent
      tenant_b = fixture(:tenant)
      agent_b = fixture(:agent, %{tenant_id: tenant_b.id, agent_type: :implementer})

      {raw_key_b, _} =
        fixture(:api_key, %{tenant_id: tenant_b.id, role: :agent, agent_id: agent_b.id})

      conn =
        conn
        |> auth_conn(raw_key_b)
        |> post(~p"/api/v1/stories/#{story.id}/claim")

      assert json_response(conn, 404)
    end
  end

  # --- Invalid transition tests ---

  describe "invalid state transitions" do
    test "cannot start from pending (409)", %{conn: conn} do
      %{story: story, raw_key: raw_key} = setup_story_with_agent()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/start")

      assert json_response(conn, 409)
    end

    test "cannot report from pending (409)", %{conn: conn} do
      %{story: story, raw_key: raw_key} = setup_story_with_agent()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/report")

      assert json_response(conn, 409)
    end

    test "nonexistent story returns 404", %{conn: conn} do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{Ecto.UUID.generate()}/claim")

      assert json_response(conn, 404)
    end
  end

  # The concurrent-claim race invariant ("only one agent wins the claim") is
  # proven deterministically in `test/loopctl/progress/claim_lock_test.exs`
  # using two independent `sandbox: false` DB sessions. It CANNOT be tested at
  # the HTTP layer here: the sandbox multiplexes every allowed Task onto ONE
  # shared connection, so the claim's `SELECT ... FOR UPDATE` lock can neither
  # serialize the two requests nor be distinguished from no lock at all — the
  # old two-`Task.async` POST test was flaky for exactly that reason.
end
