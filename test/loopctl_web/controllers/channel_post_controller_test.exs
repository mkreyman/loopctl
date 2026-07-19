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
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Coordination
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

  # A role:agent key whose agent is a WRITABLE MEMBER of `project` (US-40.D3):
  # writes are now project-scoped by membership (a channel is a project_id), and
  # membership is derived from a story assignment. Assigning the agent a story in
  # `project` admits its writes through the default-deny gate. Use this wherever a
  # test expects a SUCCESSFUL (or changeset-level) post to its own project; the
  # cross-tenant/not-found tests deliberately keep the plain, non-member key.
  defp member_agent_key(tenant, project, attrs \\ %{}) do
    {raw, key, agent} = agent_key(tenant, attrs)

    fixture(:story, %{
      tenant_id: tenant.id,
      project_id: project.id,
      assigned_agent_id: agent.id,
      agent_status: :assigned
    })

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
      {raw, _key, agent} = member_agent_key(tenant, project)

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

    # TC-40.A1.1 — a multi-item typed-open refs LIST is persisted and returned as-is.
    test "a multi-item typed-open refs list is persisted and returned -> 201" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      refs = [
        %{"type" => "issue", "value" => "#812"},
        %{"type" => "file", "value" => "lib/a.ex:1", "label" => "x"},
        %{"type" => "commit", "value" => "abc123"}
      ]

      conn = post_json(raw, %{"project_id" => project.id, "body" => "handoff", "refs" => refs})

      assert %{"post" => post} = json_response(conn, 201)
      assert post["refs"] == refs

      # and it reads back from channel_recent as the same list
      read = authed_conn(raw) |> get(@path, %{"project_id" => project.id})
      assert %{"data" => [read_post]} = json_response(read, 200)
      assert read_post["refs"] == refs
    end

    # TC-40.A1.2 — a free `type` not in the removed allowlist is accepted.
    test "a free ref type (capability) not in the old allowlist -> 201" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      conn =
        post_json(raw, %{
          "project_id" => project.id,
          "body" => "ok",
          "refs" => [%{"type" => "capability", "value" => "read:secrets"}]
        })

      assert %{"post" => post} = json_response(conn, 201)
      assert post["refs"] == [%{"type" => "capability", "value" => "read:secrets"}]
    end

    # TC-40.A1.5 — over the item-count cap is a 422 and nothing is persisted.
    test "a refs list over the item-count cap is 422 and not persisted" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      over =
        for i <- 1..(ChannelPost.refs_max_items() + 1), do: %{"type" => "t", "value" => "#{i}"}

      conn = post_json(raw, %{"project_id" => project.id, "body" => "ok", "refs" => over})
      assert json_response(conn, 422)
      assert Coordination.recent(tenant.id, project.id) == []
    end

    # TC-40.A1.3 — a secret in a ref TYPE is rejected 422, nothing persisted.
    test "a secret in a ref type is rejected 422 and not persisted" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      refs = [%{"type" => "lc_" <> String.duplicate("a", 30), "value" => "x"}]
      conn = post_json(raw, %{"project_id" => project.id, "body" => "ok", "refs" => refs})
      assert json_response(conn, 422)
      assert Coordination.recent(tenant.id, project.id) == []
    end

    # TC-40.A1.4 — a secret in a ref LABEL is rejected 422, nothing persisted.
    test "a secret in a ref label is rejected 422 and not persisted" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      refs = [%{"type" => "file", "value" => "x", "label" => "sk-" <> String.duplicate("a", 30)}]
      conn = post_json(raw, %{"project_id" => project.id, "body" => "ok", "refs" => refs})
      assert json_response(conn, 422)
      assert Coordination.recent(tenant.id, project.id) == []
    end

    # TC-40.A1.6 — malformed refs items are a 422 changeset error, never a 500.
    test "malformed refs items are 422, not 500" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      # missing `type`
      c1 =
        post_json(raw, %{
          "project_id" => project.id,
          "body" => "ok",
          "refs" => [%{"value" => "x"}]
        })

      assert json_response(c1, 422)

      # items not maps
      c2 = post_json(raw, %{"project_id" => project.id, "body" => "ok", "refs" => ["a", "b"]})
      assert json_response(c2, 422)

      # non-list refs
      c3 =
        post_json(raw, %{"project_id" => project.id, "body" => "ok", "refs" => %{"file" => "x"}})

      assert json_response(c3, 422)

      assert Coordination.recent(tenant.id, project.id) == []
    end

    # TC-40.A5.1 — advisory addressing round-trips on both the write and the read.
    test "post with to_host + to_capability -> 201, and both surface on the read" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      conn =
        post_json(raw, %{
          "project_id" => project.id,
          "body" => "beelink -> mac-mini for fly auth",
          "to_host" => "mac-mini",
          "to_capability" => "fly-auth"
        })

      assert %{"post" => post} = json_response(conn, 201)
      assert post["to_host"] == "mac-mini"
      assert post["to_capability"] == "fly-auth"

      read = authed_conn(raw) |> get(@path, %{"project_id" => project.id})
      assert %{"data" => [read_post]} = json_response(read, 200)
      assert read_post["to_host"] == "mac-mini"
      assert read_post["to_capability"] == "fly-auth"
    end

    # TC-40.A5.2 — no addressing -> 201, both NULL, visible on plain channel_recent.
    test "post with no to_host/to_capability -> 201, both null, visible on channel_recent" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      conn = post_json(raw, %{"project_id" => project.id, "body" => "broadcast"})

      assert %{"post" => post} = json_response(conn, 201)
      assert is_nil(post["to_host"])
      assert is_nil(post["to_capability"])

      read = authed_conn(raw) |> get(@path, %{"project_id" => project.id})
      assert %{"data" => [read_post]} = json_response(read, 200)
      assert read_post["body_preview"] == "broadcast"
      assert is_nil(read_post["to_host"])
      assert is_nil(read_post["to_capability"])
    end

    # TC-40.A5.3 — a secret in to_capability is rejected 422, nothing persisted.
    test "a secret in to_capability is rejected 422 and not persisted" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      conn =
        post_json(raw, %{
          "project_id" => project.id,
          "body" => "ok",
          "to_capability" => "ghp_ABCDEFGHIJKLMNOPQRST"
        })

      assert json_response(conn, 422)
      assert Coordination.recent(tenant.id, project.id) == []
    end

    # TC-40.A5.4 — addressing is NOT authorization: a post addressed to_host a
    # DIFFERENT machine is still visible to the whole tenant channel when read by a
    # DIFFERENT agent. to_host labels the intended target; it never restricts who
    # can READ (the only authz boundary is the verified key's tenant). This is the
    # AC-40.A5.3 "no authz branch on to_host/to_capability" proof at the integration
    # level: a spoofed address does not change read visibility.
    test "a post addressed to another host is still visible to a different agent in the tenant" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw_a, _key_a, _agent_a} = member_agent_key(tenant, project)
      {raw_b, _key_b, _agent_b} = member_agent_key(tenant, project)

      conn =
        post_json(raw_a, %{
          "project_id" => project.id,
          "body" => "addressed elsewhere",
          "to_host" => "some-other-host"
        })

      assert json_response(conn, 201)

      # A DIFFERENT agent in the SAME tenant reads the channel: the post IS visible,
      # to_host did not restrict read visibility.
      read = authed_conn(raw_b) |> get(@path, %{"project_id" => project.id})
      assert %{"data" => [read_post]} = json_response(read, 200)
      assert read_post["body_preview"] == "addressed elsewhere"
      assert read_post["to_host"] == "some-other-host"
    end

    # TC-39.2.2
    test "agent_id/tenant_id in the body are ignored (server-stamped from the key)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = member_agent_key(tenant, project)

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

    # TC-39.2.3b — the cross-tenant/not-found 422 emits the :ownership_rejected
    # security signal (AC-39.2.9 enumeration-scan detector). Without this the
    # detector could be silently dropped and the suite would still pass.
    test "a cross-tenant project 422 emits the ownership_rejected security signal" do
      tenant = fixture(:tenant)
      other = fixture(:tenant)
      foreign = fixture(:project, %{tenant_id: other.id})
      {raw, _key, _agent} = agent_key(tenant)

      handler_id = "coord-ownership-#{System.unique_integer([:positive])}"
      test_pid = self()
      tenant_id = tenant.id

      :telemetry.attach(
        handler_id,
        [:loopctl, :coordination, :ownership_rejected],
        fn _event, measurements, meta, _cfg ->
          if meta[:tenant_id] == tenant_id,
            do: send(test_pid, {:ownership_rejected, measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      log =
        capture_log(fn ->
          conn = post_json(raw, %{"project_id" => foreign.id, "body" => "x"})
          assert json_response(conn, 422)
        end)

      assert log =~ "ownership_rejected"
      # A non-rate-limit event carries NO `limit_kind` — its log line must not emit
      # a dangling `limit_kind=` token (the discriminator is write/read-cap only).
      refute log =~ "limit_kind="
      assert_receive {:ownership_rejected, %{count: 1}, meta}
      assert meta.project_id == foreign.id
    end

    # TC-39.2.4
    test "keyed post upserts within a session (200, same id) and is distinct across sessions (201)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

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

    # AC-39.2.2 (defense-in-depth) — a key whose server-stamped agent_id belongs to
    # another tenant (a misconfigured key; the agent FKs are non-composite) is a 403
    # agent_identity_required IDENTITY fault, NOT a 422 project probe.
    test "a key whose agent belongs to another tenant -> 403 agent_identity_required, no row" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      other = fixture(:tenant)
      foreign_agent = fixture(:agent, %{tenant_id: other.id})

      {raw, _key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: foreign_agent.id})

      log =
        capture_log(fn ->
          conn = post_json(raw, %{"project_id" => project.id, "body" => "x"})

          assert %{"error" => %{"code" => "agent_identity_required", "status" => 403}} =
                   json_response(conn, 403)
        end)

      assert AdminRepo.aggregate(ChannelPost, :count, :id) == 0
      assert log =~ "agent_identity_required"
    end

    # AC-39.2.8 — a per-write cap stored as a JSON STRING must still enforce. Without
    # coercion the string flows to the limiter verbatim, where Elixir term ordering
    # (int < binary) never denies (Hammer) or the is_integer guard raises and is
    # swallowed to fail-open (Postgres) — either way silently neutering the cap.
    test "a coordination write cap stored as a STRING is coerced and still enforces (429)" do
      stub_counting_limiter()
      tenant = fixture(:tenant, %{settings: %{"channel_post_write_limit_per_minute" => "3"}})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      for _ <- 1..3 do
        conn = post_json(raw, %{"project_id" => project.id, "body" => "x"})
        assert conn.status in [200, 201]
      end

      conn = post_json(raw, %{"project_id" => project.id, "body" => "x"})
      assert %{"error" => %{"status" => 429}} = json_response(conn, 429)
    end

    # AC-39.2.9 — a rate-limiter fault must fail OPEN (write allowed) but stay
    # OBSERVABLE via the shared throttled FailOpenLog, never be silently swallowed.
    test "a rate-limiter fault fails open (write allowed) and is logged, not swallowed" do
      stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window, _limit ->
        raise "limiter boom"
      end)

      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      log =
        capture_log(fn ->
          conn = post_json(raw, %{"project_id" => project.id, "body" => "x"})
          # Fail-open: the write still lands despite the limiter fault.
          assert conn.status in [200, 201]
        end)

      assert log =~ "RateLimiter fail-open"
      assert log =~ "channel_post_write:key"
    end

    # TC-39.2.6
    test "over-cap writes are 429 with Retry-After and emit a security-event log" do
      stub_counting_limiter()
      tenant = fixture(:tenant, %{settings: %{"channel_post_write_limit_per_minute" => 3}})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

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
      # The signal carries a write discriminator so an external telemetry/log
      # consumer can tell write flooding from read scraping (US-40.D5).
      assert log =~ "limit_kind=write"
    end

    # AC-39.2.6 — a denylist hit / oversized body is a 422 (validation), not persisted.
    test "an oversized body is rejected 422 and not persisted" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      conn =
        post_json(raw, %{"project_id" => project.id, "body" => String.duplicate("a", 16_385)})

      assert json_response(conn, 422)
      assert AdminRepo.aggregate(ChannelPost, :count, :id) == 0
    end

    # AC-39.2.9 — a denylist hit on the real HTTP write path (post/3 -> run_post ->
    # tap_secret_blocked) emits the secret_blocked signal + structured log at
    # rejection time. Previously only create_post/4 exercised this; a regression
    # dropping the HTTP-path emission would otherwise pass the suite.
    test "a secret-shaped body is rejected 422 and emits the secret_blocked security signal" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      handler_id = "coord-secret-http-#{System.unique_integer([:positive])}"
      test_pid = self()
      tenant_id = tenant.id

      :telemetry.attach(
        handler_id,
        [:loopctl, :coordination, :secret_blocked],
        fn _event, measurements, meta, _cfg ->
          if meta[:tenant_id] == tenant_id,
            do: send(test_pid, {:secret_blocked, measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      log =
        capture_log(fn ->
          conn =
            post_json(raw, %{
              "project_id" => project.id,
              "body" => "sk-" <> String.duplicate("a", 30)
            })

          assert json_response(conn, 422)
        end)

      assert log =~ "coordination denylist hit"
      assert_receive {:secret_blocked, %{count: 1}, %{field: :body}}
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

    # US-40.D3 — writes are scoped to the caller's OWN project (membership),
    # default-deny cross-project posting. Before this, any tenant agent key could
    # post into any project channel in the tenant, and that body auto-injects into
    # every peer session on the repo — a tenant-wide prompt injector. These prove
    # the server enforces write-to-own-project and that "not a member", "not your
    # tenant", and "does not exist" all collapse to ONE byte-identical 422.

    # TC-40.D3.1 + AC-40.D3.3: a member of P1 posts to P1 -> 201, while a SECOND
    # project P2 in the SAME tenant that the agent is NOT a member of is rejected.
    test "a member posts to its own project (201) but not to a sibling project it is not in (422)" do
      tenant = fixture(:tenant)
      p1 = fixture(:project, %{tenant_id: tenant.id})
      p2 = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, p1)

      # P1 (the agent's own project) works.
      own = post_json(raw, %{"project_id" => p1.id, "body" => "on my project"})
      assert %{"post" => _} = json_response(own, 201)

      # P2 (same tenant, not a member) is denied — cross-project default-deny.
      sibling = post_json(raw, %{"project_id" => p2.id, "body" => "cross-project injection"})
      assert json_response(sibling, 422)

      # Nothing persisted for P2.
      assert AdminRepo.aggregate(
               from(p in ChannelPost, where: p.project_id == ^p2.id),
               :count,
               :id
             ) == 0
    end

    # TC-40.D3.2: a non-member post to a same-tenant project is byte-identical to
    # the cross-tenant 422, fires :ownership_rejected, and persists nothing.
    test "a non-member cross-project 422 is byte-identical to cross-tenant + fires ownership_rejected" do
      tenant = fixture(:tenant)
      own_project = fixture(:project, %{tenant_id: tenant.id})
      sibling = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, own_project)

      # A project in ANOTHER tenant, for the byte-identical baseline.
      other = fixture(:tenant)
      foreign = fixture(:project, %{tenant_id: other.id})

      handler_id = "coord-d3-ownership-#{System.unique_integer([:positive])}"
      test_pid = self()
      tenant_id = tenant.id

      :telemetry.attach(
        handler_id,
        [:loopctl, :coordination, :ownership_rejected],
        fn _event, measurements, meta, _cfg ->
          if meta[:tenant_id] == tenant_id,
            do: send(test_pid, {:ownership_rejected, measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      cross_project_body =
        post_json(raw, %{"project_id" => sibling.id, "body" => "x"}) |> json_response(422)

      cross_tenant_body =
        post_json(raw, %{"project_id" => foreign.id, "body" => "x"}) |> json_response(422)

      # No oracle: the cross-PROJECT body equals the cross-TENANT body.
      assert cross_project_body == cross_tenant_body

      # The injector is observable: :ownership_rejected fired for the cross-project
      # attempt (referencing the sibling project id).
      assert_receive {:ownership_rejected, %{count: 1}, %{project_id: sibling_id}}
      assert sibling_id == sibling.id

      # Nothing persisted for the sibling project.
      assert AdminRepo.aggregate(
               from(p in ChannelPost, where: p.project_id == ^sibling.id),
               :count,
               :id
             ) == 0
    end

    # TC-40.D3.3: a project in another tenant -> 422, identical body (regression
    # guard — reads/cross-tenant posture unchanged by the membership addition).
    test "a project in another tenant is still 422 (regression guard)" do
      tenant = fixture(:tenant)
      own_project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, own_project)

      other = fixture(:tenant)
      foreign = fixture(:project, %{tenant_id: other.id})

      body =
        post_json(raw, %{"project_id" => foreign.id, "body" => "x"}) |> json_response(422)

      # Same byte-identical ownership message the cross-tenant case always returned.
      assert body["error"]["message"] ==
               "project_id does not exist or does not belong to your tenant"

      assert AdminRepo.aggregate(ChannelPost, :count, :id) == 0
    end
  end

  describe "GET /api/v1/channel/posts (channel_recent)" do
    # Seed a live post with a controlled inserted_at/updated_at for deterministic
    # ordering + since deltas (create_post always stamps "now").
    defp seed_post(tenant, project, agent_id, body, at) do
      {:ok, post} =
        Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => body})

      {:ok, post} =
        post
        |> Ecto.Changeset.change(inserted_at: at, updated_at: at)
        |> AdminRepo.update()

      post
    end

    # TC-39.3.1
    test "3 live posts t1<t2<t3 -> data has 3, ordered t3,t2,t1" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = agent_key(tenant)

      base = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      seed_post(tenant, project, agent.id, "one", DateTime.add(base, -300, :second))
      seed_post(tenant, project, agent.id, "two", DateTime.add(base, -200, :second))
      seed_post(tenant, project, agent.id, "three", DateTime.add(base, -100, :second))

      conn = authed_conn(raw) |> get(@path, %{"project_id" => project.id})
      assert %{"data" => data, "meta" => meta} = json_response(conn, 200)

      assert Enum.map(data, & &1["body_preview"]) == ["three", "two", "one"]
      # Short bodies are returned verbatim in body_preview, not truncated (AC-40.D1.1).
      assert Enum.all?(data, &(&1["truncated"] == false))
      assert meta["count"] == 3
      assert meta["limit"] == 25

      # AC-39.3.5 / AC-40.D1.1: the exact read field set, and only that set — `body`
      # is now `body_preview` + `truncated` (bounded read model).
      first = hd(data)

      assert Map.keys(first) |> Enum.sort() ==
               ~w(agent_id body_preview host id inserted_at key refs session_id to_capability to_host truncated updated_at)

      assert first["agent_id"] == agent.id
    end

    # TC-39.3.2
    test "one expired + one live -> only the live post" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = agent_key(tenant)

      {:ok, live} =
        Coordination.create_post(tenant.id, project.id, agent.id, %{"body" => "live"})

      {:ok, expired} =
        Coordination.create_post(tenant.id, project.id, agent.id, %{"body" => "expired"})

      # Force the second post's expires_at into the past (an expired-but-not-swept row).
      {:ok, _} =
        expired
        |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
        |> AdminRepo.update()

      conn = authed_conn(raw) |> get(@path, %{"project_id" => project.id})
      assert %{"data" => [post]} = json_response(conn, 200)
      assert post["id"] == live.id
      assert post["body_preview"] == "live"
    end

    # TC-39.3.3
    test "posts at t1 and t3; since=t2 -> only t3" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = agent_key(tenant)

      base = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      t2 = DateTime.add(base, -200, :second)
      seed_post(tenant, project, agent.id, "old", DateTime.add(base, -300, :second))
      seed_post(tenant, project, agent.id, "new", DateTime.add(base, -100, :second))

      conn =
        authed_conn(raw)
        |> get(@path, %{"project_id" => project.id, "since" => DateTime.to_iso8601(t2)})

      assert %{"data" => [post]} = json_response(conn, 200)
      assert post["body_preview"] == "new"
    end

    # TC-39.3.4 — oracle-safety: cross-tenant AND nonexistent both 200 empty,
    # byte-identical to each other (and to an owned-but-empty channel).
    test "cross-tenant AND nonexistent project_id both 200 with an identical empty envelope" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant)

      other = fixture(:tenant)
      foreign = fixture(:project, %{tenant_id: other.id})

      cross = authed_conn(raw) |> get(@path, %{"project_id" => foreign.id})
      missing = authed_conn(raw) |> get(@path, %{"project_id" => Ecto.UUID.generate()})

      cross_body = json_response(cross, 200)
      missing_body = json_response(missing, 200)

      assert cross_body == %{
               "data" => [],
               "meta" => %{"limit" => 25, "count" => 0, "has_more" => false}
             }

      assert cross_body == missing_body

      # And identical to an owned-but-empty project of the caller's own tenant.
      own_empty = fixture(:project, %{tenant_id: tenant.id})
      owned = authed_conn(raw) |> get(@path, %{"project_id" => own_empty.id})
      assert json_response(owned, 200) == cross_body
    end

    # TC-39.3.4 (edge): a NON-UUID and a MISSING project_id take the same
    # oracle-safe path — `recent/3`'s `valid_uuid?` guard short-circuits to `[]`,
    # so `index/2` returns the byte-identical empty envelope, never a 500 or an
    # Ecto.Query.CastError. Locks the uniform-empty contract at the HTTP boundary
    # so a future refactor of the guard can't silently regress it.
    test "a non-UUID project_id returns 200 with the identical empty envelope" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant)

      conn = authed_conn(raw) |> get(@path, %{"project_id" => "garbage-not-a-uuid"})

      assert json_response(conn, 200) == %{
               "data" => [],
               "meta" => %{"limit" => 25, "count" => 0, "has_more" => false}
             }
    end

    test "a missing project_id returns 200 with the identical empty envelope" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant)

      conn = authed_conn(raw) |> get(@path, %{})

      assert json_response(conn, 200) == %{
               "data" => [],
               "meta" => %{"limit" => 25, "count" => 0, "has_more" => false}
             }
    end

    # TC-39.3.5
    test "150 live posts, limit=1000 -> exactly 100 returned (clamped, not a 400)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = agent_key(tenant)

      for n <- 1..150 do
        {:ok, _} =
          Coordination.create_post(tenant.id, project.id, agent.id, %{"body" => "p#{n}"})
      end

      conn = authed_conn(raw) |> get(@path, %{"project_id" => project.id, "limit" => "1000"})
      assert %{"data" => data, "meta" => meta} = json_response(conn, 200)
      assert length(data) == 100
      assert meta["limit"] == 100
      assert meta["count"] == 100
      # 150 live posts but only 100 returned -> the envelope tells the caller the
      # page was truncated (honest signal, not left to infer from count == limit).
      assert meta["has_more"] == true
    end

    test "another tenant's posts are never visible (tenant isolation)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = agent_key(tenant)

      {:ok, _} =
        Coordination.create_post(tenant.id, project.id, agent.id, %{"body" => "mine"})

      other = fixture(:tenant)
      other_project = fixture(:project, %{tenant_id: other.id})
      other_agent = fixture(:agent, %{tenant_id: other.id})

      {:ok, _} =
        Coordination.create_post(other.id, other_project.id, other_agent.id, %{
          "body" => "theirs"
        })

      # The caller sees only its own post on its own channel...
      conn = authed_conn(raw) |> get(@path, %{"project_id" => project.id})
      assert %{"data" => [post]} = json_response(conn, 200)
      assert post["body_preview"] == "mine"

      # ...and gets an empty list for the other tenant's channel (oracle-safe).
      cross = authed_conn(raw) |> get(@path, %{"project_id" => other_project.id})
      assert %{"data" => []} = json_response(cross, 200)
    end

    test "the read requires agent role (an unauthenticated caller cannot read)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        build_conn()
        |> put_req_header("x-loopctl-last-known-sth", @sth_header)
        |> get(@path, %{"project_id" => project.id})

      assert conn.status in [401, 403]
    end

    # TC-40.D1.1 — a 16KB body is returned as a bounded body_preview (<= 512 bytes)
    # with truncated=true; the FULL body is never present in the list response.
    test "a 16KB-body post is listed as a bounded body_preview with truncated=true, full body absent" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = agent_key(tenant)

      big = String.duplicate("a", 16_384)
      {:ok, _} = Coordination.create_post(tenant.id, project.id, agent.id, %{"body" => big})

      conn = authed_conn(raw) |> get(@path, %{"project_id" => project.id})
      assert %{"data" => [post]} = json_response(conn, 200)

      preview = post["body_preview"]
      assert byte_size(preview) <= Coordination.preview_bytes()
      assert post["truncated"] == true
      # The full 16KB body is not present anywhere in the response payload.
      refute post["body"]
      refute String.contains?(Jason.encode!(post), big)
      # The preview is a genuine prefix of the body.
      assert String.starts_with?(big, preview)
    end
  end

  describe "GET /api/v1/channel/posts/:id (full body, US-40.D1)" do
    defp show_path(id), do: "#{@path}/#{id}"

    # TC-40.D1.2 — an owned post → 200 with the FULL body.
    test "an owned post returns 200 with the full body" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = agent_key(tenant)

      big = String.duplicate("z", 16_384)

      {:ok, post} =
        Coordination.create_post(tenant.id, project.id, agent.id, %{"body" => big})

      conn = authed_conn(raw) |> get(show_path(post.id))
      assert %{"post" => body} = json_response(conn, 200)
      assert body["id"] == post.id
      assert body["agent_id"] == agent.id
      # The FULL body is served (not a bounded preview).
      assert body["body"] == big
      assert byte_size(body["body"]) == 16_384

      # Read-model discipline (US-40.D1): the by-id read is the full-body
      # COUNTERPART to the list read, NOT the write-echo resource. It carries the
      # SAME narrowed field set as channel_post_json/1 (plus verbatim body) and
      # deliberately does NOT re-widen to tenant_id / project_id / expires_at.
      assert Map.keys(body) |> Enum.sort() ==
               ~w(agent_id body host id inserted_at key refs session_id to_capability to_host updated_at)

      refute Map.has_key?(body, "tenant_id")
      refute Map.has_key?(body, "project_id")
      refute Map.has_key?(body, "expires_at")
      refute Map.has_key?(body, "body_preview")
      refute Map.has_key?(body, "truncated")
    end

    # TC-40.D1.3 — a post in ANOTHER tenant → 404, byte-identical to a nonexistent id.
    test "a foreign-tenant id and a nonexistent id both return a byte-identical 404 (no oracle)" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant)

      other = fixture(:tenant)
      other_project = fixture(:project, %{tenant_id: other.id})
      other_agent = fixture(:agent, %{tenant_id: other.id})

      {:ok, foreign} =
        Coordination.create_post(other.id, other_project.id, other_agent.id, %{
          "body" => "theirs"
        })

      cross = authed_conn(raw) |> get(show_path(foreign.id))
      missing = authed_conn(raw) |> get(show_path(Ecto.UUID.generate()))

      cross_body = json_response(cross, 404)
      missing_body = json_response(missing, 404)

      assert cross_body == %{"error" => %{"status" => 404, "message" => "Not found"}}
      assert cross_body == missing_body
    end

    # TC-40.D1.4 — a malformed (non-UUID) id → clean 404, never a 500 CastError,
    # byte-identical to the nonexistent-id 404.
    test "a malformed (non-UUID) id returns 404, not a 500, identical to a nonexistent id" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant)

      malformed = authed_conn(raw) |> get(show_path("not-a-uuid"))
      missing = authed_conn(raw) |> get(show_path(Ecto.UUID.generate()))

      assert json_response(malformed, 404) == %{
               "error" => %{"status" => 404, "message" => "Not found"}
             }

      assert json_response(malformed, 404) == json_response(missing, 404)
    end

    test "the full-body read requires agent role (an unauthenticated caller cannot read)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {_raw, _key, agent} = agent_key(tenant)

      {:ok, post} =
        Coordination.create_post(tenant.id, project.id, agent.id, %{"body" => "x"})

      conn =
        build_conn()
        |> put_req_header("x-loopctl-last-known-sth", @sth_header)
        |> get(show_path(post.id))

      assert conn.status in [401, 403]
    end

    # AC-40.D1.4 — the full-body :show read must be rate-limited. It is covered by
    # the generic per-key limiter of the :authenticated pipeline (NOT the tighter
    # write cap, which guards writes only). This asserts that guarantee actually
    # holds for :show: once the per-key RPM budget is exhausted, further reads are
    # 429 with a Retry-After, exactly like every other authenticated read.
    test "over-cap :show reads are 429 with Retry-After (pipeline limiter applies)" do
      stub_counting_limiter()
      tenant = fixture(:tenant, %{settings: %{"rate_limit_requests_per_minute" => 2}})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = agent_key(tenant)

      {:ok, post} =
        Coordination.create_post(tenant.id, project.id, agent.id, %{"body" => "readable"})

      # First 2 reads are within the per-key cap.
      for _ <- 1..2 do
        conn = authed_conn(raw) |> get(show_path(post.id))
        assert conn.status == 200
      end

      # The 3rd read trips the per-key limiter -> 429 with a Retry-After.
      conn = authed_conn(raw) |> get(show_path(post.id))
      assert %{"error" => %{"status" => 429}} = json_response(conn, 429)
      assert [retry] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry) >= 1
    end
  end

  describe "DELETE /api/v1/channel/posts/:id" do
    defp delete_path(id), do: "#{@path}/#{id}"

    defp seed_channel_post(tenant, project, agent_id, body \\ "leaked secret") do
      {:ok, post} =
        Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => body})

      post
    end

    # TC-39.7.1 + AC-39.7.5 (end to end): deletes → 204, gone from channel_recent.
    test "an agent deletes a post in its tenant -> 204 and it is gone from channel_recent" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = agent_key(tenant)
      post = seed_channel_post(tenant, project, agent.id)

      conn = authed_conn(raw) |> delete(delete_path(post.id))
      assert response(conn, 204) == ""

      # AC-39.7.5: no longer surfaced by channel_recent.
      read = authed_conn(raw) |> get(@path, %{"project_id" => project.id})
      assert %{"data" => data} = json_response(read, 200)
      refute Enum.any?(data, &(&1["id"] == post.id))

      # AC-39.7.3: the deletion is audited even though the row is gone.
      entry =
        AdminRepo.one!(
          from(a in AuditLog,
            where:
              a.tenant_id == ^tenant.id and a.entity_type == "channel_post" and
                a.entity_id == ^post.id and a.action == "deleted"
          )
        )

      assert entry.action == "deleted"
    end

    # TC-40.D2.2: a non-author agent B (role :agent) may NOT delete agent A's post.
    test "agent B (role :agent) deleting agent A's post -> 404 (byte-identical to nonexistent), A's post untouched" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {_raw_a, _key_a, agent_a} = agent_key(tenant)
      {raw_b, _key_b, _agent_b} = agent_key(tenant)

      post = seed_channel_post(tenant, project, agent_a.id, "from A")

      # US-40.D2 kills the censor-and-replace vector: a non-author agent gets a 404
      # byte-identical to the nonexistent-post 404 (no existence oracle).
      cross = authed_conn(raw_b) |> delete(delete_path(post.id))
      nonexistent = authed_conn(raw_b) |> delete(delete_path(Ecto.UUID.generate()))

      assert cross.status == 404
      assert nonexistent.status == 404
      assert cross.resp_body == nonexistent.resp_body

      # A's post is untouched, and no "deleted" audit row was written.
      assert %ChannelPost{} = AdminRepo.get(ChannelPost, post.id)

      assert AdminRepo.aggregate(
               from(a in AuditLog,
                 where:
                   a.entity_type == "channel_post" and a.entity_id == ^post.id and
                     a.action == "deleted"
               ),
               :count,
               :id
             ) == 0
    end

    # TC-40.D2.3: an elevated (role :user) caller CAN delete another agent's post.
    test "a role :user caller deleting agent A's post -> 204, audit actor is the elevated key" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {_raw_a, _key_a, agent_a} = agent_key(tenant)
      # An elevated (>= :user) operator key — still carries an agent identity so it
      # is the audit actor.
      {raw_user, key_user, elevated_agent} = agent_key(tenant, %{role: :user})

      post = seed_channel_post(tenant, project, agent_a.id, "from A")

      conn = authed_conn(raw_user) |> delete(delete_path(post.id))
      assert response(conn, 204) == ""

      entry =
        AdminRepo.one!(
          from(a in AuditLog,
            where:
              a.tenant_id == ^tenant.id and a.entity_type == "channel_post" and
                a.entity_id == ^post.id and a.action == "deleted"
          )
        )

      # The elevated deleting key is the audit actor — not the post's author (A).
      assert entry.actor_id == key_user.id
      assert entry.metadata["deleted_post_agent_id"] == agent_a.id
      assert entry.metadata["deleted_by_agent_id"] == elevated_agent.id
    end

    # TC-39.7.3: cross-tenant delete → 404, the other tenant's post still exists.
    test "a cross-tenant delete returns 404 and the other tenant's post still exists" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant)

      other = fixture(:tenant)
      other_project = fixture(:project, %{tenant_id: other.id})
      other_agent = fixture(:agent, %{tenant_id: other.id})
      foreign_post = seed_channel_post(other, other_project, other_agent.id, "theirs")

      conn = authed_conn(raw) |> delete(delete_path(foreign_post.id))
      assert json_response(conn, 404)

      # The foreign row is untouched.
      assert %ChannelPost{} = AdminRepo.get(ChannelPost, foreign_post.id)
    end

    # TC-39.7.4: nonexistent random UUID → 404, body byte-identical to cross-tenant.
    test "a nonexistent random UUID returns 404 with a body byte-identical to the cross-tenant 404" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant)

      other = fixture(:tenant)
      other_project = fixture(:project, %{tenant_id: other.id})
      other_agent = fixture(:agent, %{tenant_id: other.id})
      foreign_post = seed_channel_post(other, other_project, other_agent.id, "theirs")

      cross = authed_conn(raw) |> delete(delete_path(foreign_post.id))
      nonexistent = authed_conn(raw) |> delete(delete_path(Ecto.UUID.generate()))

      assert cross.status == 404
      assert nonexistent.status == 404
      # No existence oracle: the two 404 bodies are byte-identical.
      assert cross.resp_body == nonexistent.resp_body
    end

    test "the route requires agent role (an unauthenticated caller cannot delete)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {_raw, _key, agent} = agent_key(tenant)
      post = seed_channel_post(tenant, project, agent.id)

      conn =
        build_conn()
        |> put_req_header("x-loopctl-last-known-sth", @sth_header)
        |> delete(delete_path(post.id))

      assert conn.status in [401, 403]
      # The post is untouched by the rejected request.
      assert %ChannelPost{} = AdminRepo.get(ChannelPost, post.id)
    end
  end

  describe "read rate limiting (US-40.D5)" do
    # TC-40.D5.1 — a burst of :index reads past the DEDICATED read cap gets 429 with
    # a Retry-After and emits the coordination :rate_limited signal, on a bucket
    # SEPARATE from the write cap. The read cap (3) trips at a LOWER count than the
    # pipeline per-key cap (default 300), so the coordination signal fires instead
    # of being shadowed by an anonymous pipeline 429 (independence/observability).
    test "an :index read burst past the read cap is 429 with Retry-After + :rate_limited signal" do
      counts = stub_counting_limiter()
      tenant = fixture(:tenant, %{settings: %{"channel_post_read_limit_per_minute" => 3}})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = agent_key(tenant)

      # First 3 reads are within the per-read cap.
      for _ <- 1..3 do
        conn = authed_conn(raw) |> get(@path, %{"project_id" => project.id})
        assert conn.status == 200
      end

      log =
        capture_log(fn ->
          conn = authed_conn(raw) |> get(@path, %{"project_id" => project.id})

          assert %{"error" => %{"status" => 429}} = json_response(conn, 429)
          assert [retry] = get_resp_header(conn, "retry-after")
          assert String.to_integer(retry) >= 1
        end)

      assert log =~ "rate_limited"
      # The signal carries a READ discriminator so an external telemetry/log
      # consumer can tell read scraping from write flooding (US-40.D5) — the two
      # trips are no longer an indistinguishable :rate_limited shape.
      assert log =~ "limit_kind=read"

      # The trip was counted on the READ bucket, distinct from the write bucket —
      # read and write abuse are independently observable (US-40.D5 technical note).
      buckets = Agent.get(counts, &Map.keys/1)
      assert Enum.any?(buckets, &String.starts_with?(&1, "channel_post_read:key"))
      refute Enum.any?(buckets, &String.starts_with?(&1, "channel_post_write:key"))
    end

    # TC-40.D5.2 — the full-body :show read is behind the SAME dedicated read cap,
    # not only the pipeline limiter: a burst of by-id reads trips at the read cap.
    test "GET /:id is rate-limited by the dedicated read cap too" do
      stub_counting_limiter()
      tenant = fixture(:tenant, %{settings: %{"channel_post_read_limit_per_minute" => 3}})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = agent_key(tenant)

      {:ok, post} = Coordination.create_post(tenant.id, project.id, agent.id, %{"body" => "hi"})

      for _ <- 1..3 do
        conn = authed_conn(raw) |> get(show_path(post.id))
        assert conn.status == 200
      end

      conn = authed_conn(raw) |> get(show_path(post.id))
      assert %{"error" => %{"status" => 429}} = json_response(conn, 429)
      assert [retry] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry) >= 1
    end

    # TC-40.D5.3 — a read-path limiter fault fails OPEN (read allowed) but stays
    # OBSERVABLE via the shared throttled FailOpenLog on the read bucket family,
    # never silently swallowed (full parity with the write path).
    test "a limiter fault on the read path fails open (read allowed) and is logged" do
      stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window, _limit ->
        raise "limiter boom"
      end)

      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = agent_key(tenant)

      log =
        capture_log(fn ->
          conn = authed_conn(raw) |> get(@path, %{"project_id" => project.id})
          # Fail-open: the read still lands despite the limiter fault.
          assert conn.status == 200
        end)

      assert log =~ "RateLimiter fail-open"
      assert log =~ "channel_post_read:key"
    end

    # TC-40.D5.4 — a normal read cadence under the cap is unaffected: backward
    # compatible with US-39.3 / US-40.C2 (reads behave exactly as before the cap).
    test "a normal read cadence under the cap is unaffected (all 200, no 429)" do
      stub_counting_limiter()
      tenant = fixture(:tenant, %{settings: %{"channel_post_read_limit_per_minute" => 10}})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = agent_key(tenant)

      for _ <- 1..5 do
        conn = authed_conn(raw) |> get(@path, %{"project_id" => project.id})
        assert conn.status == 200
        assert get_resp_header(conn, "retry-after") == []
      end
    end

    # AC-40.D5.3 — the coordination read cap is CLAMPED below the tenant's live
    # pipeline per-key cap (read_limit/1's min/2). A tenant misconfiguring the read
    # cap ABOVE the pipeline cap must NOT leave read trips shadowed by an anonymous
    # pipeline 429: the effective read cap is the pipeline value, not the configured
    # (larger) read value. Assert the EFFECTIVE limit the controller hands the read
    # bucket, independent of plug ordering (parity with write_limit/1's clamp).
    test "AC-40.D5.3: a read cap set ABOVE the pipeline cap is clamped to the pipeline value" do
      {:ok, limits} = Agent.start_link(fn -> %{} end)

      stub(Loopctl.MockRateLimiter, :check_rate, fn bucket, _window_ms, limit ->
        Agent.update(limits, &Map.put(&1, bucket, limit))
        {:allow, 1}
      end)

      # Read cap (100) deliberately set ABOVE the pipeline per-key cap (3).
      tenant =
        fixture(:tenant, %{
          settings: %{
            "channel_post_read_limit_per_minute" => 100,
            "rate_limit_requests_per_minute" => 3
          }
        })

      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = agent_key(tenant)

      conn = authed_conn(raw) |> get(@path, %{"project_id" => project.id})
      assert conn.status == 200

      read_bucket =
        limits
        |> Agent.get(&Map.keys/1)
        |> Enum.find(&String.starts_with?(&1, "channel_post_read:key"))

      # Effective cap clamped to the pipeline value (3), NOT the configured 100.
      assert Agent.get(limits, &Map.get(&1, read_bucket)) == 3
    end

    # AC-40.D5.3 — a per-read cap stored as a JSON STRING must still enforce. Without
    # coercion the string flows to the limiter verbatim, where Elixir term ordering
    # (int < binary) never denies (Hammer) or the is_integer guard raises and is
    # swallowed to fail-open (Postgres) — either way silently neutering the read cap.
    # Mirrors the write-path regression test ("...write cap stored as a STRING...").
    test "a coordination read cap stored as a STRING is coerced and still enforces (429)" do
      stub_counting_limiter()
      tenant = fixture(:tenant, %{settings: %{"channel_post_read_limit_per_minute" => "3"}})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = agent_key(tenant)

      for _ <- 1..3 do
        conn = authed_conn(raw) |> get(@path, %{"project_id" => project.id})
        assert conn.status == 200
      end

      conn = authed_conn(raw) |> get(@path, %{"project_id" => project.id})
      assert %{"error" => %{"status" => 429}} = json_response(conn, 429)
    end

    # AC-40.D5.2 — the read response is BOUNDED BY CONSTRUCTION; this story adds the
    # limiter and ASSERTS the bounds already hold. The list clamps `limit` to 100
    # (@max_recent_limit) and returns bounded previews (not full bodies).
    test "AC-40.D5.2: :index clamps limit to 100 and returns bounded previews, not full bodies" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = agent_key(tenant)

      big = String.duplicate("a", 16_384)
      {:ok, _} = Coordination.create_post(tenant.id, project.id, agent.id, %{"body" => big})

      conn = authed_conn(raw) |> get(@path, %{"project_id" => project.id, "limit" => "1000"})
      assert %{"data" => [post], "meta" => meta} = json_response(conn, 200)

      # `limit` clamped to the @max_recent_limit of 100 (list bounded by row count).
      assert meta["limit"] == 100
      # Bounded preview, not the full (up to 16KB) body.
      assert byte_size(post["body_preview"]) <= Coordination.preview_bytes()
      assert post["truncated"] == true
      refute Map.has_key?(post, "body")
    end

    # AC-40.D5.2 — the single-post read returns exactly one post whose body is
    # inherently bounded by @body_max_length (16KB, channel_post.ex).
    test "AC-40.D5.2: GET /:id returns exactly one post whose body is <= 16KB" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = agent_key(tenant)

      big = String.duplicate("b", 16_384)
      {:ok, post} = Coordination.create_post(tenant.id, project.id, agent.id, %{"body" => big})

      conn = authed_conn(raw) |> get(show_path(post.id))
      assert %{"post" => body} = json_response(conn, 200)
      assert byte_size(body["body"]) <= 16_384
    end
  end
end
