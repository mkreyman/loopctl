defmodule LoopctlWeb.StoryClaimHolderControllerTest do
  @moduledoc """
  US-52.14 (AC-52.14.3): the 409 a second session gets on a story another session holds,
  and the role gate in front of it, unchanged.
  """
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.Holders

  setup :verify_on_exit!

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  setup do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    {_plain, _key, agent} = fixture(:agent_key, %{tenant_id: tenant.id})
    story = fixture(:story, %{tenant_id: tenant.id, agent_status: :contracted})

    [h1, h2] =
      for {session, host} <- [{"s1", "minis"}, {"s2", "x1"}] do
        attrs = %{"kind" => "interactive", "session_id" => session, "host" => host}
        {:ok, reg} = Holders.register(tenant.id, agent.id, attrs)
        reg
      end

    %{tenant: tenant, story: story, h1: h1, h2: h2}
  end

  defp claim(raw_key, story),
    do: build_conn() |> auth(raw_key) |> post(~p"/api/v1/stories/#{story.id}/claim")

  test "a second session of the same agent gets 409 held_by_other_holder naming the first", ctx do
    assert json_response(claim(ctx.h1.raw_key, ctx.story), 200)

    error = json_response(claim(ctx.h2.raw_key, ctx.story), 409)["error"]
    assert error["code"] == "held_by_other_holder"
    assert error["holder_id"] == ctx.h1.holder.id
    assert error["holder_kind"] == "interactive"
    assert error["holder_host"] == "minis"
  end

  test "the same session's retried claim answers 200 with the claim unchanged", ctx do
    first = json_response(claim(ctx.h1.raw_key, ctx.story), 200)["story"]
    again = json_response(claim(ctx.h1.raw_key, ctx.story), 200)["story"]

    assert again["claim_epoch"] == first["claim_epoch"]
    assert again["assigned_holder_id"] == ctx.h1.holder.id
  end

  test "an orchestrator key is still 403 on claim", ctx do
    {orch_key, _} = fixture(:api_key, %{tenant_id: ctx.tenant.id, role: :orchestrator})
    assert json_response(claim(orch_key, ctx.story), 403)
  end
end
