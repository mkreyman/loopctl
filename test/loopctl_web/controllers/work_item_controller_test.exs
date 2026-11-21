defmodule LoopctlWeb.WorkItemControllerTest do
  @moduledoc """
  US-52.18 TC-52.18.5: `POST /api/v1/work_items` on real keys. A holder opens its branch's
  item (201) and reopens it (200), another holder is 409 `branch_held`, a plain agent key is
  403 `holder_credential_required`, and another tenant's repo is 404 `project_not_found`.
  """
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.Holders

  setup :verify_on_exit!

  @repo "https://github.com/mkreyman/chg"

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp open(raw_key, params),
    do: build_conn() |> auth(raw_key) |> post(~p"/api/v1/work_items", params)

  setup do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    {plain, _key, agent} = fixture(:agent_key, %{tenant_id: tenant.id})
    project = fixture(:project, %{tenant_id: tenant.id, repo_url: @repo})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 3})

    [h1, h2] =
      for {session, host} <- [{"s1", "minis"}, {"s2", "x1"}] do
        attrs = %{"kind" => "interactive", "session_id" => session, "host" => host}
        {:ok, reg} = Holders.register(tenant.id, agent.id, attrs)
        reg
      end

    %{tenant: tenant, plain: plain, epic: epic, h1: h1, h2: h2}
  end

  defp params(ctx, branch), do: %{repo_url: @repo, branch: branch, epic_id: ctx.epic.id}

  test "a holder opens its item, and reopening returns it", ctx do
    body = json_response(open(ctx.h1.raw_key, params(ctx, "fix/demo")), 201)
    item = body["work_item"]

    assert body["outcome"] == "created"
    assert item["title"] == "fix/demo"
    assert item["branch"] == "fix/demo"
    assert item["agent_status"] == "implementing"
    assert item["assigned_holder_id"] == ctx.h1.holder.id

    again = json_response(open(ctx.h1.raw_key, params(ctx, "fix/demo")), 200)
    assert again["outcome"] == "existing"
    assert again["work_item"]["id"] == item["id"]
  end

  test "another holder on the same branch is 409 branch_held", ctx do
    item = json_response(open(ctx.h1.raw_key, params(ctx, "fix/demo")), 201)["work_item"]
    error = json_response(open(ctx.h2.raw_key, params(ctx, "fix/demo")), 409)["error"]

    assert error["code"] == "branch_held"
    assert error["story_id"] == item["id"]
    assert error["holder_id"] == ctx.h1.holder.id
  end

  test "a plain agent key is 403 holder_credential_required", ctx do
    error = json_response(open(ctx.plain, params(ctx, "fix/demo")), 403)["error"]
    assert error["code"] == "holder_credential_required"
  end

  test "another tenant's repo is 404 project_not_found", ctx do
    other = fixture(:tenant, %{trust_tier: :human_anchored})
    {_plain, _key, other_agent} = fixture(:agent_key, %{tenant_id: other.id})

    {:ok, reg} =
      Holders.register(other.id, other_agent.id, %{
        "kind" => "interactive",
        "session_id" => "s9",
        "host" => "minis"
      })

    error =
      json_response(open(reg.raw_key, %{repo_url: @repo, branch: "fix/demo"}), 404)["error"]

    assert error["code"] == "project_not_found"
    refute error["message"] =~ ctx.tenant.id
  end

  test "no target epic is 422 no_target_epic and says to pass epic_id", ctx do
    error =
      json_response(open(ctx.h1.raw_key, %{repo_url: @repo, branch: "fix/demo"}), 422)["error"]

    assert error["code"] == "no_target_epic"
    assert error["message"] =~ "epic_id"
  end

  test "a detached HEAD is 422 invalid_branch", ctx do
    error = json_response(open(ctx.h1.raw_key, params(ctx, "HEAD")), 422)["error"]
    assert error["code"] == "invalid_branch"
  end
end
