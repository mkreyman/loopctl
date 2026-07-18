defmodule LoopctlWeb.ChannelPostControllerTest do
  @moduledoc """
  US-39.2 — the coordination bus write endpoint `POST /api/v1/channel/posts`.

  Everything (auth resolution AND the channel write) runs through
  `Loopctl.AdminRepo`, one sandbox connection, so this stays `async: true`.
  """
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Loopctl.AdminRepo
  alias Loopctl.Coordination.ChannelPost

  @path "/api/v1/channel/posts"
  @sth_header "0:AAAAAAAAAAAAAAAAAAAAAA"

  # A role:agent key whose api_key.agent_id points at a real agent in the tenant
  # (generate_api_key does not auto-assign one, so we wire it explicitly — the
  # endpoint requires an agent identity).
  defp agent_key(tenant, attrs \\ %{}) do
    agent = fixture(:agent, %{tenant_id: tenant.id})

    {raw, key} =
      fixture(
        :api_key,
        Map.merge(%{tenant_id: tenant.id, role: :agent, agent_id: agent.id}, attrs)
      )

    {raw, key, agent}
  end

  defp authed_conn(raw) do
    build_conn()
    |> put_req_header("x-loopctl-last-known-sth", @sth_header)
    |> put_req_header("authorization", "Bearer #{raw}")
  end

  defp post_json(raw, params), do: authed_conn(raw) |> post(@path, params)

  # Stateful counting stub for the DI-resolved rate limiter (config/test.exs maps
  # `:rate_limiter` to Loopctl.MockRateLimiter, whose default stub always allows).
  # Reproduces the fixed-window post-increment-per-bucket contract so the
  # controller's per-write cap actually trips — mirrors rate_limiter_test.exs.
  defp stub_counting_limiter do
    {:ok, counts} = Agent.start_link(fn -> %{} end)

    stub(Loopctl.MockRateLimiter, :check_rate, fn bucket, _window_ms, limit ->
      count =
        Agent.get_and_update(counts, fn m ->
          c = Map.get(m, bucket, 0) + 1
          {c, Map.put(m, bucket, c)}
        end)

      if count <= limit, do: {:allow, count}, else: {:deny, limit}
    end)

    counts
  end

  describe "POST /api/v1/channel/posts" do
    # TC-39.2.1
    test "agent posts to own project channel -> 201 with server-stamped identity + ~30d expiry" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = agent_key(tenant)

      conn = post_json(raw, %{"project_id" => project.id, "body" => "pushed PR #107, CI green"})

      assert %{"post" => post} = json_response(conn, 201)
      assert post["agent_id"] == agent.id
      assert post["tenant_id"] == tenant.id
      assert post["project_id"] == project.id
      assert post["body"] == "pushed PR #107, CI green"

      {:ok, expires, _} = DateTime.from_iso8601(post["expires_at"])
      expected = DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
      assert_in_delta DateTime.to_unix(expires), DateTime.to_unix(expected), 120
    end

    # TC-39.2.2
    test "agent_id/tenant_id in the body are ignored (server-stamped from the key)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = agent_key(tenant)

      foreign_tenant = fixture(:tenant)
      foreign_agent = fixture(:agent, %{tenant_id: foreign_tenant.id})

      conn =
        post_json(raw, %{
          "project_id" => project.id,
          "body" => "x",
          "agent_id" => foreign_agent.id,
          "tenant_id" => foreign_tenant.id
        })

      assert %{"post" => post} = json_response(conn, 201)
      assert post["agent_id"] == agent.id
      assert post["tenant_id"] == tenant.id
    end

    # TC-39.2.3
    test "cross-tenant AND not-found project both 422 with a byte-identical body, no row" do
      tenant = fixture(:tenant)
      other = fixture(:tenant)
      foreign = fixture(:project, %{tenant_id: other.id})
      {raw, _key, _agent} = agent_key(tenant)

      cross_body =
        post_json(raw, %{"project_id" => foreign.id, "body" => "x"}) |> json_response(422)

      missing_body =
        post_json(raw, %{"project_id" => Ecto.UUID.generate(), "body" => "x"})
        |> json_response(422)

      # No existence oracle: the "not yours" and "does not exist" bodies are identical.
      assert cross_body == missing_body
      assert AdminRepo.aggregate(ChannelPost, :count, :id) == 0
    end

    # TC-39.2.4
    test "keyed post upserts within a session (200, same id) and is distinct across sessions (201)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = agent_key(tenant)

      slot = fn session, body ->
        %{
          "project_id" => project.id,
          "session_id" => session,
          "key" => "session_goal",
          "body" => body
        }
      end

      c1 = post_json(raw, slot.("S1", "v1"))
      assert %{"post" => p1} = json_response(c1, 201)

      c2 = post_json(raw, slot.("S1", "v2"))
      assert %{"post" => p2} = json_response(c2, 200)
      assert p2["id"] == p1["id"]
      assert p2["body"] == "v2"

      c3 = post_json(raw, slot.("S2", "other"))
      assert %{"post" => p3} = json_response(c3, 201)
      assert p3["id"] != p1["id"]

      count =
        AdminRepo.aggregate(
          from(p in ChannelPost, where: p.project_id == ^project.id),
          :count,
          :id
        )

      assert count == 2
    end

    # TC-39.2.5
    test "an agent key with no agent identity -> 403 agent_identity_required, no row + security log" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: nil})

      log =
        capture_log(fn ->
          conn = post_json(raw, %{"project_id" => project.id, "body" => "x"})

          assert %{"error" => %{"code" => "agent_identity_required", "status" => 403}} =
                   json_response(conn, 403)
        end)

      assert AdminRepo.aggregate(ChannelPost, :count, :id) == 0
      assert log =~ "agent_identity_required"
    end

    # TC-39.2.6
    test "over-cap writes are 429 with Retry-After and emit a security-event log" do
      stub_counting_limiter()
      tenant = fixture(:tenant, %{settings: %{"channel_post_write_limit_per_minute" => 3}})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = agent_key(tenant)

      # First 3 writes are within the per-write cap.
      for _ <- 1..3 do
        conn = post_json(raw, %{"project_id" => project.id, "body" => "x"})
        assert conn.status in [200, 201]
      end

      log =
        capture_log(fn ->
          conn = post_json(raw, %{"project_id" => project.id, "body" => "x"})

          assert %{"error" => %{"status" => 429}} = json_response(conn, 429)
          assert [retry] = get_resp_header(conn, "retry-after")
          assert String.to_integer(retry) >= 1
        end)

      assert log =~ "rate_limited"
    end

    # AC-39.2.6 — a denylist hit / oversized body is a 422 (validation), not persisted.
    test "an oversized body is rejected 422 and not persisted" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = agent_key(tenant)

      conn =
        post_json(raw, %{"project_id" => project.id, "body" => String.duplicate("a", 16_385)})

      assert json_response(conn, 422)
      assert AdminRepo.aggregate(ChannelPost, :count, :id) == 0
    end

    test "the route requires agent role (a lower/unauthenticated caller cannot post)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        build_conn()
        |> put_req_header("x-loopctl-last-known-sth", @sth_header)
        |> post(@path, %{"project_id" => project.id, "body" => "x"})

      assert conn.status in [401, 403]
    end
  end
end
