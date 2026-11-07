defmodule LoopctlWeb.TuningDraftControllerTest do
  @moduledoc """
  US-48.13 (AC-48.13.4): `GET /api/v1/tuning_drafts` and `POST /api/v1/tuning_drafts/:id/landed`
  — the improvement loop's operator surface, for a `user`-role key only, and never another
  tenant's drafts. Landing records the PR and changes nothing else.
  """

  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Agents.TuningDraft
  alias Loopctl.Audit.AuditLog

  setup :verify_on_exit!

  @pr "https://github.com/mkreyman/loopctl/pull/1042"

  setup do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    {user_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
    project = fixture(:project, %{tenant_id: tenant.id})
    %{tenant: tenant, user_key: user_key, project: project}
  end

  defp at(seconds), do: DateTime.add(~U[2026-11-07 12:00:00.000000Z], seconds, :second)

  defp get_drafts(raw_key, params \\ %{}) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{raw_key}")
    |> get(~p"/api/v1/tuning_drafts", params)
  end

  defp land(raw_key, id, body) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{raw_key}")
    |> post(~p"/api/v1/tuning_drafts/#{id}/landed", body)
  end

  describe "index" do
    test "lists the tenant's drafts newest first with their verdict and traces", ctx do
      t = ctx.tenant.id

      old =
        fixture(:tuning_draft, %{
          tenant_id: t,
          project_id: ctx.project.id,
          status: :rejected,
          inserted_at: at(-60)
        })

      trace = %{"trace_id" => Ecto.UUID.generate(), "untrusted" => "fenced"}

      new =
        fixture(:tuning_draft, %{
          tenant_id: t,
          project_id: ctx.project.id,
          input: %{"traces" => [trace]},
          inserted_at: at(0)
        })

      body = ctx.user_key |> get_drafts() |> json_response(200)

      assert Enum.map(body["data"], & &1["id"]) == [new.id, old.id]
      assert body["has_more"] == false

      [first, second] = body["data"]
      assert first["status"] == "proposed"
      assert first["target_spec"] == %{"id" => "triage", "version" => 1}
      assert first["template"] == %{"id" => "triage", "from_version" => 1, "to_version" => 2}
      assert first["traces"] == [trace]
      assert first["scores"]["proposed"] == %{"passed" => 2, "total" => 2}
      assert second["status"] == "rejected"
      assert second["rejection_reasons"] == ["not_better"]
    end

    test "filters by status, spec and project, and pages through next_cursor", ctx do
      t = ctx.tenant.id

      ids =
        for n <- 0..2,
            do:
              fixture(:tuning_draft, %{
                tenant_id: t,
                project_id: ctx.project.id,
                inserted_at: at(-n)
              }).id

      _pending = fixture(:tuning_draft, %{tenant_id: t, status: :pending, inserted_at: at(-10)})

      proposed = ctx.user_key |> get_drafts(%{"status" => "proposed"}) |> json_response(200)
      assert Enum.map(proposed["data"], & &1["id"]) == ids

      in_project =
        ctx.user_key |> get_drafts(%{"project_id" => ctx.project.id}) |> json_response(200)

      assert length(in_project["data"]) == 3

      none = ctx.user_key |> get_drafts(%{"spec_id" => "implement"}) |> json_response(200)
      assert none["data"] == []

      page1 = ctx.user_key |> get_drafts(%{"limit" => "2"}) |> json_response(200)
      assert page1["has_more"] == true

      page2 =
        ctx.user_key
        |> get_drafts(%{"limit" => "2", "cursor" => page1["next_cursor"]})
        |> json_response(200)

      assert page2["has_more"] == false
      assert length(page1["data"] ++ page2["data"]) == 4
    end

    test "a bad filter, limit or cursor is 400", ctx do
      for params <- [
            %{"status" => "applied"},
            %{"project_id" => "nope"},
            %{"limit" => "0"},
            %{"limit" => "x"},
            %{"cursor" => "forged"},
            %{"spec_id" => String.duplicate("a", 65)}
          ] do
        assert ctx.user_key |> get_drafts(params) |> json_response(400), inspect(params)
      end
    end

    test "agent and orchestrator keys are 403'd", ctx do
      for role <- [:agent, :orchestrator] do
        {raw, _} = fixture(:api_key, %{tenant_id: ctx.tenant.id, role: role})
        assert raw |> get_drafts() |> json_response(403)
      end
    end

    test "tenant isolation: another tenant's drafts are never listed", ctx do
      other = fixture(:tenant, %{trust_tier: :human_anchored})
      _theirs = fixture(:tuning_draft, %{tenant_id: other.id})

      assert ctx.user_key |> get_drafts() |> json_response(200) |> Map.fetch!("data") == []
    end
  end

  describe "landed" do
    setup ctx do
      %{draft: fixture(:tuning_draft, %{tenant_id: ctx.tenant.id, project_id: ctx.project.id})}
    end

    test "a proposed draft lands, naming the PR, and the act is audited", ctx do
      body = ctx.user_key |> land(ctx.draft.id, %{"pr_url" => @pr}) |> json_response(200)

      assert body["data"]["status"] == "landed"
      assert body["data"]["pr_url"] == @pr
      assert body["data"]["landed_at"]

      assert [entry] =
               AdminRepo.all(
                 from a in AuditLog,
                   where: a.tenant_id == ^ctx.tenant.id and a.entity_id == ^ctx.draft.id
               )

      assert entry.action == "tuning_draft_landed"
      assert entry.actor_type == "api_key"
      assert entry.actor_id
    end

    test "a draft not proposed is 409 not_proposed", ctx do
      rejected = fixture(:tuning_draft, %{tenant_id: ctx.tenant.id, status: :rejected})

      body = ctx.user_key |> land(rejected.id, %{"pr_url" => @pr}) |> json_response(409)
      assert body["error"]["code"] == "not_proposed"
      assert AdminRepo.get!(TuningDraft, rejected.id).status == :rejected
    end

    test "a malformed or missing pr_url is 422", ctx do
      assert ctx.user_key
             |> land(ctx.draft.id, %{"pr_url" => "https://example.com/a/b/pull/1"})
             |> json_response(422)

      assert ctx.user_key |> land(ctx.draft.id, %{}) |> json_response(422)
      assert AdminRepo.get!(TuningDraft, ctx.draft.id).status == :proposed
    end

    test "an unknown draft is 404", ctx do
      assert ctx.user_key |> land(Ecto.UUID.generate(), %{"pr_url" => @pr}) |> json_response(404)
    end

    test "agent and orchestrator keys are 403'd and nothing lands", ctx do
      for role <- [:agent, :orchestrator] do
        {raw, _} = fixture(:api_key, %{tenant_id: ctx.tenant.id, role: role})
        assert raw |> land(ctx.draft.id, %{"pr_url" => @pr}) |> json_response(403)
      end

      assert AdminRepo.get!(TuningDraft, ctx.draft.id).status == :proposed
    end

    test "tenant isolation: another tenant's key cannot land this draft", ctx do
      other = fixture(:tenant, %{trust_tier: :human_anchored})
      {other_key, _} = fixture(:api_key, %{tenant_id: other.id, role: :user})

      assert other_key |> land(ctx.draft.id, %{"pr_url" => @pr}) |> json_response(404)
      assert AdminRepo.get!(TuningDraft, ctx.draft.id).status == :proposed
    end
  end
end
