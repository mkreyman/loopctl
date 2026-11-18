defmodule LoopctlWeb.ChgFindingControllerTest do
  @moduledoc """
  US-51.6 (AC-51.6.1, AC-51.6.4): `GET /api/v1/chg_findings` lists the tenant's findings for
  any key from agent role up; `POST /api/v1/chg_findings/:id/clear` is a user key on a
  human-anchored tenant, and refuses everything else.
  """

  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Changes.Finding

  setup :verify_on_exit!

  @at ~U[2026-11-19 04:10:00.000000Z]

  setup do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    {agent_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
    {user_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
    %{tenant: tenant, agent_key: agent_key, user_key: user_key}
  end

  defp finding!(tenant_id, attrs) do
    escalated? = Map.get(attrs, :state) == :escalated

    AdminRepo.insert!(
      struct(
        %Finding{
          tenant_id: tenant_id,
          kind: "flaky_test",
          fingerprint: "hcb:" <> Ecto.UUID.generate(),
          repo_full_name: "mkreyman/home_care_billing",
          state: :filed,
          first_seen_at: @at,
          last_seen_at: @at,
          escalated_at: if(escalated?, do: @at),
          escalated_reason: if(escalated?, do: "fix_attempts_2")
        },
        attrs
      )
    )
  end

  defp call(raw_key, method, path, params \\ %{}) do
    conn = put_req_header(build_conn(), "authorization", "Bearer #{raw_key}")

    case method do
      :get -> get(conn, path, params)
      :post -> post(conn, path, params)
    end
  end

  describe "index" do
    test "an agent key lists the tenant's findings with their issue url, filtered", ctx do
      t = ctx.tenant.id
      finding!(t, %{issue_number: 7, last_seen_at: DateTime.add(@at, -60, :second)})
      newest = finding!(t, %{kind: "selection_miss", repo_full_name: "mkreyman/chg"})

      body = ctx.agent_key |> call(:get, ~p"/api/v1/chg_findings") |> json_response(200)
      assert [%{"id" => id}, %{"issue_url" => url, "state" => "filed"}] = body["data"]
      assert id == newest.id
      assert url == "https://github.com/mkreyman/home_care_billing/issues/7"

      only =
        ctx.agent_key
        |> call(:get, ~p"/api/v1/chg_findings", %{
          "kind" => "selection_miss",
          "repo" => "MKREYMAN/chg"
        })
        |> json_response(200)

      assert [%{"id" => ^id, "issue_url" => nil}] = only["data"]
    end

    test "an unknown state or kind, or a bad limit, is 422", ctx do
      for params <- [
            %{"state" => "open"},
            %{"kind" => "bug"},
            %{"limit" => "0"},
            %{"limit" => "x"}
          ] do
        assert ctx.agent_key
               |> call(:get, ~p"/api/v1/chg_findings", params)
               |> json_response(422)
      end
    end

    test "another tenant's findings are never listed", ctx do
      other = fixture(:tenant, %{})
      finding!(other.id, %{})

      body = ctx.agent_key |> call(:get, ~p"/api/v1/chg_findings") |> json_response(200)
      assert body["data"] == []
    end
  end

  describe "clear" do
    test "a user key clears an escalated finding back to queued", ctx do
      f = finding!(ctx.tenant.id, %{state: :escalated, issue_number: 9, fix_attempts: 2})

      body =
        ctx.user_key |> call(:post, ~p"/api/v1/chg_findings/#{f.id}/clear") |> json_response(200)

      assert %{"state" => "queued", "fix_attempts" => 0, "cycle" => 1, "issue_url" => nil} =
               body["data"]
    end

    test "a finding that is not escalated is 409; an unknown one is 404", ctx do
      f = finding!(ctx.tenant.id, %{})

      assert %{"error" => %{"code" => "not_escalated"}} =
               ctx.user_key
               |> call(:post, ~p"/api/v1/chg_findings/#{f.id}/clear")
               |> json_response(409)

      ctx.user_key
      |> call(:post, ~p"/api/v1/chg_findings/#{Ecto.UUID.generate()}/clear")
      |> json_response(404)
    end

    test "an agent key is 403 and the finding stays escalated", ctx do
      f = finding!(ctx.tenant.id, %{state: :escalated})

      ctx.agent_key |> call(:post, ~p"/api/v1/chg_findings/#{f.id}/clear") |> json_response(403)
      assert %Finding{state: :escalated} = AdminRepo.get(Finding, f.id)
    end

    test "a user key on an agent-rooted tenant is 403 custody_tier_required" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {user_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      f = finding!(tenant.id, %{state: :escalated})

      body = user_key |> call(:post, ~p"/api/v1/chg_findings/#{f.id}/clear") |> json_response(403)
      assert body["error"]["code"] == "custody_tier_required"
      assert %Finding{state: :escalated} = AdminRepo.get(Finding, f.id)
    end

    test "another tenant's escalated finding is 404", ctx do
      other = fixture(:tenant, %{})
      f = finding!(other.id, %{state: :escalated})

      ctx.user_key |> call(:post, ~p"/api/v1/chg_findings/#{f.id}/clear") |> json_response(404)
      assert %Finding{state: :escalated} = AdminRepo.get(Finding, f.id)
    end
  end
end
