defmodule LoopctlWeb.WorkItemNoteControllerTest do
  @moduledoc """
  US-52.17 (TC-52.17.6, TC-52.17.7, TC-52.17.8): the notes routes on real keys — the holder
  writes, another session of the same agent is 409, refusals render their codes, another
  tenant's story is 404 — and the retired orchestrator state paths answer 404.
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

    assert json_response(
             build_conn() |> auth(h1.raw_key) |> post(~p"/api/v1/stories/#{story.id}/claim"),
             200
           )

    %{tenant: tenant, story: story, h1: h1, h2: h2}
  end

  defp write(raw_key, story_id, params),
    do: build_conn() |> auth(raw_key) |> post(~p"/api/v1/stories/#{story_id}/notes", params)

  defp read(raw_key, story_id, query \\ %{}),
    do: build_conn() |> auth(raw_key) |> get(~p"/api/v1/stories/#{story_id}/notes?#{query}")

  test "the holder writes a note and reads it back with current", ctx do
    note =
      json_response(write(ctx.h1.raw_key, ctx.story.id, %{section: "plan", body: "do x"}), 201)[
        "note"
      ]

    assert note["holder_id"] == ctx.h1.holder.id
    assert note["section"] == "plan"

    body = json_response(read(ctx.h1.raw_key, ctx.story.id), 200)
    assert [%{"id" => id}] = body["data"]
    assert id == note["id"]
    assert body["current"]["plan"]["id"] == note["id"]
    assert body["has_more"] == false
  end

  test "another session of the same agent is 409 held_by_other_holder", ctx do
    error = json_response(write(ctx.h2.raw_key, ctx.story.id, %{section: "plan", body: "b"}), 409)

    assert error["error"]["code"] == "held_by_other_holder"
    assert error["error"]["holder_id"] == ctx.h1.holder.id
  end

  test "an agent key on an item nobody holds is 409 not_holder", ctx do
    free = fixture(:story, %{tenant_id: ctx.tenant.id})
    error = json_response(write(ctx.h1.raw_key, free.id, %{section: "plan", body: "b"}), 409)

    assert error["error"]["code"] == "not_holder"
  end

  test "an orchestrator key writes on any item", ctx do
    {orch_key, _} = fixture(:api_key, %{tenant_id: ctx.tenant.id, role: :orchestrator})

    assert json_response(write(orch_key, ctx.story.id, %{section: "decision", body: "ok"}), 201)
  end

  test "an orchestrator reusing the holder's idempotency_key is 409 idempotency_key_reused",
       ctx do
    params = %{section: "plan", body: "do x", idempotency_key: "plan"}
    assert json_response(write(ctx.h1.raw_key, ctx.story.id, params), 201)

    {orch_key, _} = fixture(:api_key, %{tenant_id: ctx.tenant.id, role: :orchestrator})
    error = json_response(write(orch_key, ctx.story.id, %{params | body: "mine"}), 409)

    assert error["error"]["code"] == "idempotency_key_reused"
  end

  test "a bad section or an oversized body is 422", ctx do
    assert json_response(write(ctx.h1.raw_key, ctx.story.id, %{section: "diary", body: "b"}), 422)

    big = String.duplicate("x", 16_385)
    assert json_response(write(ctx.h1.raw_key, ctx.story.id, %{section: "plan", body: big}), 422)
  end

  test "an unknown section or a bad cursor on the read is 422", ctx do
    assert json_response(read(ctx.h1.raw_key, ctx.story.id, %{section: "diary"}), 422)["error"][
             "code"
           ] == "invalid_section"

    assert json_response(read(ctx.h1.raw_key, ctx.story.id, %{after: "x"}), 422)["error"]["code"] ==
             "invalid_cursor"
  end

  test "another tenant's story is 404 on both routes", ctx do
    other = fixture(:tenant, %{trust_tier: :human_anchored})
    {orch_key, _} = fixture(:api_key, %{tenant_id: other.id, role: :orchestrator})

    assert json_response(write(orch_key, ctx.story.id, %{section: "plan", body: "b"}), 404)
    assert json_response(read(orch_key, ctx.story.id), 404)
  end

  test "the author is the key, never a param", ctx do
    params = %{
      section: "plan",
      body: "b",
      holder_id: ctx.h2.holder.id,
      author_api_key_id: Ecto.UUID.generate()
    }

    note = json_response(write(ctx.h1.raw_key, ctx.story.id, params), 201)["note"]
    assert note["holder_id"] == ctx.h1.holder.id
  end

  describe "the retired orchestrator state routes (TC-52.17.8)" do
    test "all three paths answer 404", ctx do
      {orch_key, _} = fixture(:api_key, %{tenant_id: ctx.tenant.id, role: :orchestrator})
      project = ctx.story.project_id

      conn = fn -> build_conn() |> auth(orch_key) end

      assert conn.() |> put("/api/v1/orchestrator/state/#{project}", %{}) |> response(404)
      assert conn.() |> get("/api/v1/orchestrator/state/#{project}") |> response(404)
      assert conn.() |> get("/api/v1/orchestrator/state/#{project}/history") |> response(404)
    end
  end
end
