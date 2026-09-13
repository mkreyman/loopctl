defmodule LoopctlWeb.RenewClaimLoggingTest do
  @moduledoc """
  Issue #815: a refused `renew-claim` names why. Its claimant is about to lose the claim to
  the reclaimer, and before this nothing recorded the presented epoch against the current
  one.

  `async: false` because the `:info` line is let past `config/test.exs`'s `:warning` primary
  level with a VM-global module level (see `LoopctlWeb.RunnerObservabilityTest`).
  """

  use LoopctlWeb.ConnCase, async: false

  import Ecto.Query
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

  test "a claim_epoch that is not an epoch is logged as :invalid, never its value", %{conn: conn} do
    tenant = fixture(:tenant)
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
    {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})
    story = fixture(:story, %{tenant_id: tenant.id, agent_status: :contracted})
    marker = "EPOCHVALUE-" <> String.duplicate("x", 10_000)

    conn
    |> put_req_header("authorization", "Bearer #{raw_key}")
    |> post(~p"/api/v1/stories/#{story.id}/claim")
    |> json_response(200)

    for epoch <- [marker, %{"nested" => %{"deep" => marker}}, 9_223_372_036_854_775_808, -1] do
      log =
        capture_log([level: :info], fn ->
          build_conn()
          |> put_req_header("authorization", "Bearer #{raw_key}")
          |> post(~p"/api/v1/stories/#{story.id}/renew-claim", %{"claim_epoch" => epoch})
          |> then(&assert(&1.status in [400, 409]))
        end)

      assert log =~ "presented_epoch=:invalid", "#{inspect(epoch, limit: 3)} not marked invalid"
      refute log =~ "EPOCHVALUE"
      refute log =~ "nested"
      refute log =~ "9223372036854775808"
    end
  end

  test "a story id that is not a UUID is logged as :invalid, never its value", %{conn: conn} do
    tenant = fixture(:tenant)
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
    {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})
    junk = "STORYVALUE" <> String.duplicate("y", 2_000)

    # A string epoch is refused before the story is read, so the junk id reaches the log.
    log =
      capture_log([level: :info], fn ->
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> post("/api/v1/stories/#{junk}/renew-claim", %{"claim_epoch" => "1"})
        |> response(400)
      end)

    assert log =~ "renew_claim refused"
    assert log =~ "story_id=:invalid"
    assert log =~ "current_epoch=nil"
    refute log =~ "STORYVALUE"
  end

  test "a 16-byte story id is :invalid, not a fabricated UUID, and no epoch is read for it", %{
    conn: conn
  } do
    tenant = fixture(:tenant)
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
    {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})
    segment = "aaaaaaaaaaaaaaaa"
    # What Ecto.UUID.cast/1 makes of those 16 bytes. A story at exactly that id, with an
    # epoch, shows whether the refusal path read one for the fabricated id.
    {:ok, fabricated} = Ecto.UUID.cast(segment)
    story = fixture(:story, %{tenant_id: tenant.id})

    {1, _} =
      Loopctl.AdminRepo.update_all(
        from(s in Loopctl.WorkBreakdown.Story, where: s.id == ^story.id),
        set: [id: fabricated, claim_epoch: 5]
      )

    log =
      capture_log([level: :info], fn ->
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> post("/api/v1/stories/#{segment}/renew-claim", %{"claim_epoch" => "1"})
        |> response(400)
      end)

    assert log =~ "renew_claim refused"
    assert log =~ "story_id=:invalid"
    assert log =~ "current_epoch=nil"
    refute log =~ fabricated
    refute log =~ segment
  end
end
