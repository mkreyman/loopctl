defmodule LoopctlWeb.StoryChangeControllerTest do
  @moduledoc """
  US-47.7 / AC-47.7.1: `GET /api/v1/stories/:id/changes`. The ordering, filter and bounds are
  `Loopctl.Changes.StoryChangesTest`'s; this file covers the HTTP shape, the role gate, the
  bounds as the response states them, and the 404 for a story that is not the tenant's.
  """

  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.Changes

  setup :verify_on_exit!

  @repo "mkreyman/loopctl"

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  setup do
    tenant = fixture(:tenant)
    story = fixture(:story, %{tenant_id: tenant.id})
    {_secret, source} = fixture(:intake_source, %{tenant_id: tenant.id})
    {agent_key, _api_key, _agent} = fixture(:agent_key, %{tenant_id: tenant.id})
    %{tenant: tenant, story: story, source: source, agent_key: agent_key}
  end

  defp bind(ctx, change_id) do
    fixture(:change_binding, %{
      tenant_id: ctx.tenant.id,
      story_id: ctx.story.id,
      repo: @repo,
      change_id: change_id
    })
  end

  defp event(ctx, change_id, seq, attrs \\ %{}) do
    fixture(
      :change_event,
      Map.merge(
        %{
          tenant_id: ctx.tenant.id,
          source_id: ctx.source.id,
          repo: @repo,
          change_id: change_id,
          event_seq: seq
        },
        attrs
      )
    )
  end

  defp read(conn, raw_key, story_id) do
    conn
    |> auth(raw_key)
    |> get(~p"/api/v1/stories/#{story_id}/changes")
  end

  describe "GET /api/v1/stories/:id/changes" do
    test "an agent key reads the bindings, oldest first, each with its applied events",
         %{conn: conn} = ctx do
      first = bind(ctx, "chg-first")
      second = bind(ctx, "chg-second")

      event(ctx, "chg-first", 1, %{
        kind: "submitted",
        revision: 1,
        data: %{"note" => "SECRET-ISH"}
      })

      event(ctx, "chg-second", 1, %{kind: "submitted"})
      event(ctx, "chg-second", 2, %{kind: "check_passed", revision: 2})
      event(ctx, "chg-second", 4, %{applied: false})

      raw = conn |> read(ctx.agent_key, ctx.story.id) |> response(200)

      # The untrusted chg payload is never returned, nor the effect.
      refute raw =~ "SECRET-ISH"
      body = Jason.decode!(raw)

      assert body["story_id"] == ctx.story.id
      assert body["binding_count"] == 2

      assert body["meta"] == %{
               "order" => "oldest_first",
               "max_bindings" => Changes.max_bindings(),
               "max_events_per_change" => Changes.max_events_per_change()
             }

      assert [a, b] = body["bindings"]

      assert a["id"] == first.id
      assert a["repo"] == @repo
      assert a["change_id"] == "chg-first"
      assert a["current"] == false
      assert is_binary(a["superseded_at"])
      assert a["submitter_not_claimant"] == true
      assert is_binary(a["inserted_at"])

      assert [ev] = a["events"]

      assert Map.keys(ev) |> Enum.sort() ==
               ~w(applied_at event_seq kind occurred_at revision sha)

      assert ev["event_seq"] == 1
      assert ev["kind"] == "submitted"

      assert b["id"] == second.id
      assert b["current"] == true
      assert b["superseded_at"] == nil
      assert Enum.map(b["events"], & &1["event_seq"]) == [1, 2]
      assert b["applied_event_count"] == 2
      assert b["events_truncated"] == false
    end

    test "the per-change cap holds and the response says the list is truncated",
         %{conn: conn} = ctx do
      max = Changes.max_events_per_change()
      bind(ctx, "chg-long")
      for seq <- 1..(max + 1), do: event(ctx, "chg-long", seq)

      body = conn |> read(ctx.agent_key, ctx.story.id) |> json_response(200)

      assert [b] = body["bindings"]
      assert length(b["events"]) == max
      assert hd(b["events"])["event_seq"] == 2
      assert b["applied_event_count"] == max + 1
      assert b["events_truncated"] == true
    end

    test "a tenant story with no binding answers an empty list", %{conn: conn} = ctx do
      body = conn |> read(ctx.agent_key, ctx.story.id) |> json_response(200)
      assert body["bindings"] == []
      assert body["binding_count"] == 0
    end

    test "user and orchestrator keys read it too (role hierarchy)", %{conn: conn} = ctx do
      bind(ctx, "chg-roles")

      for role <- [:user, :orchestrator] do
        {raw, _key} = fixture(:api_key, %{tenant_id: ctx.tenant.id, role: role})
        body = build_conn() |> read(raw, ctx.story.id) |> json_response(200)
        assert [%{"change_id" => "chg-roles"}] = body["bindings"]
      end

      _ = conn
    end

    test "tenant isolation: another tenant's story answers exactly like an unknown id",
         %{conn: conn} = ctx do
      other = fixture(:tenant)
      foreign = fixture(:story, %{tenant_id: other.id})
      fixture(:change_binding, %{tenant_id: other.id, story_id: foreign.id})

      foreign_body = conn |> read(ctx.agent_key, foreign.id) |> json_response(404)

      unknown_body =
        build_conn() |> read(ctx.agent_key, Ecto.UUID.generate()) |> json_response(404)

      malformed_body = build_conn() |> read(ctx.agent_key, "not-a-uuid") |> json_response(404)

      assert foreign_body == unknown_body
      assert malformed_body == unknown_body
    end

    test "an impersonating superadmin reads the impersonated tenant; without it, 400",
         %{conn: conn} = ctx do
      bind(ctx, "chg-super")
      {raw_super, _key} = fixture(:api_key, %{role: :superadmin})

      body =
        conn
        |> put_req_header("x-impersonate-tenant", ctx.tenant.id)
        |> read(raw_super, ctx.story.id)
        |> json_response(200)

      assert [%{"change_id" => "chg-super"}] = body["bindings"]

      assert build_conn() |> read(raw_super, ctx.story.id) |> json_response(400)
    end

    test "no key is 401", %{conn: conn} = ctx do
      assert conn |> get(~p"/api/v1/stories/#{ctx.story.id}/changes") |> json_response(401)
    end
  end

  describe "the OpenAPI operation" do
    test "documents both bounds from the one value the query enforces", %{conn: conn} do
      spec = conn |> get(~p"/api/v1/openapi") |> json_response(200)
      op = spec["paths"]["/api/v1/stories/{id}/changes"]["get"]

      assert op["description"] =~ "#{Changes.max_events_per_change()} events per change"
      assert op["description"] =~ "#{Changes.max_bindings()} bindings"

      schema = op["responses"]["200"]["content"]["application/json"]["schema"]
      assert schema["properties"]["bindings"]["maxItems"] == Changes.max_bindings()

      assert schema["properties"]["bindings"]["items"]["properties"]["events"]["maxItems"] ==
               Changes.max_events_per_change()

      assert Map.has_key?(op["responses"], "404")
    end
  end
end
