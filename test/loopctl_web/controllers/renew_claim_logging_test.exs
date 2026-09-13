defmodule LoopctlWeb.RenewClaimLoggingTest do
  @moduledoc """
  Issue #815: a refused `renew-claim` names why. Its claimant is about to lose the claim to
  the reclaimer, and before this nothing recorded the presented epoch against the current
  one.

  `async: false` because the `:info` line is let past `config/test.exs`'s `:warning` primary
  level with a VM-global module level (see `LoopctlWeb.RunnerObservabilityTest`).
  """

  use LoopctlWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  setup :verify_on_exit!

  setup do
    Logger.put_module_level(LoopctlWeb.StoryStatusController, :info)
    on_exit(fn -> Logger.delete_module_level(LoopctlWeb.StoryStatusController) end)
    :ok
  end

  test "a stale renewal logs story, presented and current epoch, agent and reason", %{conn: conn} do
    tenant = fixture(:tenant)
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
    {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})
    story = fixture(:story, %{tenant_id: tenant.id, agent_status: :contracted})

    conn
    |> put_req_header("authorization", "Bearer #{raw_key}")
    |> post(~p"/api/v1/stories/#{story.id}/claim")
    |> json_response(200)

    log =
      capture_log([level: :info], fn ->
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> post(~p"/api/v1/stories/#{story.id}/renew-claim", %{"claim_epoch" => 0})
        |> json_response(409)
      end)

    assert log =~ "renew_claim refused: reason=:stale_claim_epoch"
    assert log =~ "story_id=#{inspect(story.id)}"
    assert log =~ "presented_epoch=0 current_epoch=1"
    assert log =~ "agent_id=#{inspect(agent.id)}"
    assert log =~ "tenant_id=#{tenant.id}"
  end
end
