defmodule LoopctlWeb.AgentOutcomeControllerTest do
  @moduledoc """
  US-48.12 (AC-48.12.4, AC-48.12.5): `GET /api/v1/agent_specs/:spec_id/outcomes` — an agent
  spec's per-version outcome summary, for any authenticated key from agent role up, scoped
  to the key's own tenant.
  """

  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  setup do
    tenant = fixture(:stage_tenant, %{})
    {agent_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
    %{tenant: tenant, agent_key: agent_key}
  end

  defp get_outcomes(raw_key, spec_id, params \\ %{}) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{raw_key}")
    |> get(~p"/api/v1/agent_specs/#{spec_id}/outcomes", params)
  end

  test "an agent key reads the spec's per-version summary", ctx do
    t = ctx.tenant.id
    fixture(:agent_run_outcome, %{tenant_id: t, signals: %{"merged" => %{"value" => true}}})
    fixture(:agent_run_outcome, %{tenant_id: t, end_reason: "wall_clock_exceeded"})
    fixture(:agent_run_outcome, %{tenant_id: t, spec_version: 2})

    body = ctx.agent_key |> get_outcomes("implement") |> json_response(200)

    assert %{"spec_id" => "implement", "window_days" => 30, "versions" => [v2, v1]} =
             body["data"]

    assert {:ok, _, _} = DateTime.from_iso8601(body["data"]["since"])
    assert %{"spec_version" => 2, "runs" => 1} = v2

    assert %{
             "spec_version" => 1,
             "runs" => 2,
             "successes" => 1,
             "budget_exhausted" => 1,
             "success_rate" => 0.5,
             "budget_exhausted_rate" => 0.5,
             "median_turns" => nil
           } = v1
  end

  test "window_days narrows the window", ctx do
    t = ctx.tenant.id
    old = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)
    fixture(:agent_run_outcome, %{tenant_id: t, inserted_at: old})
    fixture(:agent_run_outcome, %{tenant_id: t})

    body = ctx.agent_key |> get_outcomes("implement", %{window_days: "7"}) |> json_response(200)
    assert %{"window_days" => 7, "versions" => [%{"runs" => 1}]} = body["data"]
  end

  test "a malformed spec_id or window_days is a 400", ctx do
    assert ctx.agent_key |> get_outcomes("Implement") |> json_response(400)

    for days <- ["0", "366", "7.5", "seven"] do
      assert ctx.agent_key
             |> get_outcomes("implement", %{window_days: days})
             |> json_response(400),
             "window_days=#{days} was accepted"
    end
  end

  test "no key is a 401" do
    assert build_conn() |> get(~p"/api/v1/agent_specs/implement/outcomes") |> json_response(401)
  end

  test "tenant isolation: another tenant's outcomes are never counted", ctx do
    other = fixture(:stage_tenant, %{})
    fixture(:agent_run_outcome, %{tenant_id: other.id})
    fixture(:agent_run_outcome, %{tenant_id: other.id})
    fixture(:agent_run_outcome, %{tenant_id: ctx.tenant.id})

    body = ctx.agent_key |> get_outcomes("implement") |> json_response(200)
    assert [%{"runs" => 1}] = body["data"]["versions"]
  end
end
