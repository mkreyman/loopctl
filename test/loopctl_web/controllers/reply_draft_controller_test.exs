defmodule LoopctlWeb.ReplyDraftControllerTest do
  @moduledoc """
  US-48.9 (AC-48.9.3, TC-48.9.4): `GET /api/v1/projects/:project_id/reply_drafts` — a
  project's reply drafts, newest first, keyset-paginated, for a `user`-role key only, and
  never another tenant's.
  """

  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    {user_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
    project = fixture(:project, %{tenant_id: tenant.id})
    %{tenant: tenant, user_key: user_key, project: project}
  end

  defp get_drafts(raw_key, project_id, params \\ %{}) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{raw_key}")
    |> get(~p"/api/v1/projects/#{project_id}/reply_drafts", params)
  end

  defp at(seconds), do: DateTime.add(~U[2026-11-07 12:00:00.000000Z], seconds, :second)

  describe "index" do
    test "lists the project's drafts newest first, drafted and refused, in full", ctx do
      t = ctx.tenant.id
      p = ctx.project.id

      old = fixture(:reply_draft, %{tenant_id: t, project_id: p, inserted_at: at(-60)})

      refused =
        fixture(:reply_draft, %{
          tenant_id: t,
          project_id: p,
          status: :refused,
          screen_signals: ["instruction_override:reply_body"],
          inserted_at: at(0)
        })

      # Another project of the same tenant is not listed.
      _elsewhere = fixture(:reply_draft, %{tenant_id: t, inserted_at: at(30)})

      body = ctx.user_key |> get_drafts(p) |> json_response(200)

      assert Enum.map(body["data"], & &1["id"]) == [refused.id, old.id]
      assert body["has_more"] == false
      assert body["next_cursor"] == nil

      [first, second] = body["data"]
      assert first["status"] == "refused"
      assert first["body"] == nil
      assert first["screen_code"] == "injection_detector_draft"
      assert first["screen_signals"] == ["instruction_override:reply_body"]

      assert second["status"] == "drafted"
      assert second["body"] == "Thanks for writing in."
      assert second["ticket_id"] == old.ticket_id
      assert second["story_id"] == old.story_id
      assert second["dispatch_id"] == old.dispatch_id
    end

    test "pages through next_cursor with no row skipped or repeated, ties included", ctx do
      t = ctx.tenant.id
      p = ctx.project.id

      # Five rows, two sharing one instant: the keyset breaks the tie on id.
      ids =
        for seconds <- [0, 10, 10, 20, 30] do
          fixture(:reply_draft, %{tenant_id: t, project_id: p, inserted_at: at(seconds)}).id
        end

      page1 = ctx.user_key |> get_drafts(p, %{"limit" => "2"}) |> json_response(200)
      assert page1["has_more"] == true
      assert is_binary(page1["next_cursor"])

      page2 =
        ctx.user_key
        |> get_drafts(p, %{"limit" => "2", "cursor" => page1["next_cursor"]})
        |> json_response(200)

      page3 =
        ctx.user_key
        |> get_drafts(p, %{"limit" => "2", "cursor" => page2["next_cursor"]})
        |> json_response(200)

      assert page3["has_more"] == false
      assert page3["next_cursor"] == nil

      seen =
        Enum.flat_map([page1, page2, page3], fn page -> Enum.map(page["data"], & &1["id"]) end)

      assert length(seen) == 5
      assert Enum.sort(seen) == Enum.sort(ids)
    end

    test "agent and orchestrator keys are refused 403 (ticket-derived text)", ctx do
      fixture(:reply_draft, %{tenant_id: ctx.tenant.id, project_id: ctx.project.id})
      {orch, _} = fixture(:api_key, %{tenant_id: ctx.tenant.id, role: :orchestrator})
      {agent, _key, _agent} = fixture(:agent_key, %{tenant_id: ctx.tenant.id})

      for raw <- [orch, agent] do
        assert ctx.user_key != raw
        conn = get_drafts(raw, ctx.project.id)
        assert conn.status == 403
        refute conn.resp_body =~ "Thanks for writing in."
      end
    end

    test "a cursor that is not this endpoint's, or a bad limit, is a 400", ctx do
      for params <- [
            %{"cursor" => "not-a-cursor"},
            %{"limit" => "0"},
            %{"limit" => "ten"}
          ] do
        assert ctx.user_key |> get_drafts(ctx.project.id, params) |> json_response(400)
      end
    end

    test "an unknown project is a 404 and a malformed id a 422", ctx do
      assert ctx.user_key |> get_drafts(Ecto.UUID.generate()) |> json_response(404)
      assert get_drafts(ctx.user_key, "x").status in [404, 422]
    end
  end

  describe "tenant isolation (TC-48.9.4)" do
    setup ctx do
      other = fixture(:tenant, %{trust_tier: :human_anchored})
      {their_key, _} = fixture(:api_key, %{tenant_id: other.id, role: :user})
      their_project = fixture(:project, %{tenant_id: other.id})

      theirs =
        fixture(:reply_draft, %{
          tenant_id: other.id,
          project_id: their_project.id,
          body: "their customer's reply"
        })

      mine = fixture(:reply_draft, %{tenant_id: ctx.tenant.id, project_id: ctx.project.id})

      Map.merge(ctx, %{
        other: other,
        their_key: their_key,
        their_project: their_project,
        theirs: theirs,
        mine: mine
      })
    end

    test "another tenant's project is a 404, never its drafts", ctx do
      conn = get_drafts(ctx.user_key, ctx.their_project.id)
      assert json_response(conn, 404)
      refute conn.resp_body =~ "their customer's reply"
    end

    test "each tenant lists only its own", ctx do
      mine = ctx.user_key |> get_drafts(ctx.project.id) |> json_response(200)
      assert Enum.map(mine["data"], & &1["id"]) == [ctx.mine.id]

      theirs = ctx.their_key |> get_drafts(ctx.their_project.id) |> json_response(200)
      assert Enum.map(theirs["data"], & &1["id"]) == [ctx.theirs.id]
    end

    test "a cursor one tenant was issued is refused 400 to another", ctx do
      t = ctx.tenant.id

      for s <- [10, 20],
          do:
            fixture(:reply_draft, %{tenant_id: t, project_id: ctx.project.id, inserted_at: at(s)})

      page = ctx.user_key |> get_drafts(ctx.project.id, %{"limit" => "1"}) |> json_response(200)
      assert is_binary(page["next_cursor"])

      assert ctx.their_key
             |> get_drafts(ctx.their_project.id, %{"cursor" => page["next_cursor"]})
             |> json_response(400)
    end
  end
end
