defmodule LoopctlWeb.ChannelLockControllerTest do
  @moduledoc """
  US-40.4 — the ADVISORY file soft-lock endpoints:
  `POST /api/v1/channel/locks`, `POST /api/v1/channel/locks/release`, and
  `GET /api/v1/channel/locks`.

  Advisory: a lock NEVER blocks a caller — two sessions may hold one on the same
  file and both are surfaced. NOT the exactly-once handoff claim
  (`/api/v1/channel/claims`, covered by `channel_claim_controller_test.exs`).
  """
  use LoopctlWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  setup :verify_on_exit!

  @path "/api/v1/channel/locks"
  @release_path "/api/v1/channel/locks/release"
  @sth_header "0:AAAAAAAAAAAAAAAAAAAAAA"
  @target "lib/foo.ex"

  defp agent_key(tenant) do
    agent = fixture(:agent, %{tenant_id: tenant.id})

    {raw, key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

    {raw, key, agent}
  end

  defp member_agent_key(tenant, project) do
    {raw, key, agent} = agent_key(tenant)

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

  defp post_json(raw, path, params), do: authed_conn(raw) |> post(path, params)

  # Stateful counting stub for the DI-resolved rate limiter (config/test.exs maps
  # `:rate_limiter` to Loopctl.MockRateLimiter, whose default stub always allows).
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

  defp setup_member do
    tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
    project = fixture(:project, %{tenant_id: tenant.id})
    {raw, _key, agent} = member_agent_key(tenant, project)
    %{tenant: tenant, project: project, raw: raw, agent: agent}
  end

  describe "POST /api/v1/channel/locks" do
    test "a member agent takes a lock -> 201 with the advisory contract in meta" do
      %{project: project, raw: raw, agent: agent} = setup_member()

      conn =
        post_json(raw, @path, %{
          "project_id" => project.id,
          "target" => @target,
          "session_id" => "sess-a",
          "ttl_seconds" => 600
        })

      body = json_response(conn, 201)
      assert body["created"] == true
      assert body["lock"]["target"] == @target
      assert body["lock"]["key"] == "claim:#{@target}"
      assert body["lock"]["agent_id"] == agent.id
      assert body["lock"]["refs"] == [%{"type" => "file", "value" => @target}]
      # ADVISORY is part of the response contract — a client must never infer
      # exclusivity from a 201.
      assert body["meta"]["advisory"] == true
      assert body["meta"]["blocking"] == false
    end

    # Review #451: a session-less lock would be neither refreshable nor releasable,
    # so it is rejected rather than rescued with a server-minted surrogate slot.
    test "a lock write with no session_id -> 422 (never a surrogate slot)" do
      %{project: project, raw: raw} = setup_member()

      body =
        raw
        |> post_json(@path, %{"project_id" => project.id, "target" => @target})
        |> json_response(422)

      assert body["error"]["message"] =~ "session_id is required"

      listing =
        authed_conn(raw)
        |> get(@path, %{"project_id" => project.id})
        |> json_response(200)

      assert listing["locks"] == []
    end

    # Review #451 (AC-40.4.2): a lock must be DISTINCT on channel_recent, not just
    # present under a key a consumer has to re-parse.
    test "the lock is marked DISTINCTLY on channel_recent (lock / lock_target / expires_at)" do
      %{project: project, raw: raw} = setup_member()

      lock =
        raw
        |> post_json(@path, %{
          "project_id" => project.id,
          "target" => @target,
          "session_id" => "sess-a"
        })
        |> json_response(201)

      raw
      |> post_json("/api/v1/channel/posts", %{
        "project_id" => project.id,
        "body" => "an ordinary coordination post",
        "session_id" => "sess-a"
      })
      |> json_response(201)

      rows =
        authed_conn(raw)
        |> get("/api/v1/channel/posts", %{"project_id" => project.id})
        |> json_response(200)
        |> Map.fetch!("data")

      lock_row = Enum.find(rows, &(&1["id"] == lock["lock"]["id"]))
      assert lock_row["lock"] == true
      assert lock_row["lock_target"] == @target
      assert lock_row["expires_at"]

      plain_row = Enum.find(rows, &(&1["id"] != lock["lock"]["id"]))
      assert plain_row["lock"] == false
      assert plain_row["lock_target"] == nil
    end

    # Review #451 (high): `claim:` is a RESERVED namespace on the generic post
    # path — otherwise an ordinary keyed post silently got a 900s TTL and appeared
    # as a bogus file lock.
    test "an ordinary post using the reserved claim: key prefix -> 422" do
      %{project: project, raw: raw} = setup_member()

      body =
        raw
        |> post_json("/api/v1/channel/posts", %{
          "project_id" => project.id,
          "body" => "ordinary keyed working state",
          "key" => "claim:story-812",
          "session_id" => "sess-a"
        })
        |> json_response(422)

      assert body["error"]["message"] =~ "reserved"

      listing =
        authed_conn(raw)
        |> get(@path, %{"project_id" => project.id})
        |> json_response(200)

      assert listing["locks"] == []
    end

    test "the same session re-locking the same target -> 200 (slot refreshed in place)" do
      %{project: project, raw: raw} = setup_member()

      params = %{"project_id" => project.id, "target" => @target, "session_id" => "sess-a"}
      first = post_json(raw, @path, params) |> json_response(201)
      second = post_json(raw, @path, params) |> json_response(200)

      assert second["lock"]["id"] == first["lock"]["id"]
      assert second["created"] == false
    end

    test "a SECOND session locking the same file is NOT blocked -> 201, both surface" do
      %{project: project, raw: raw} = setup_member()

      a =
        post_json(raw, @path, %{
          "project_id" => project.id,
          "target" => @target,
          "session_id" => "sess-a"
        })
        |> json_response(201)

      b =
        post_json(raw, @path, %{
          "project_id" => project.id,
          "target" => @target,
          "session_id" => "sess-b"
        })
        |> json_response(201)

      refute a["lock"]["id"] == b["lock"]["id"]

      listing =
        authed_conn(raw)
        |> get(@path, %{"project_id" => project.id})
        |> json_response(200)

      ids = Enum.map(listing["locks"], & &1["id"])
      assert a["lock"]["id"] in ids
      assert b["lock"]["id"] in ids
    end

    test "a cross-PROJECT (non-member) lock -> 422, byte-identical to a cross-tenant one" do
      %{raw: raw, tenant: tenant} = setup_member()
      sibling = fixture(:project, %{tenant_id: tenant.id})
      other_tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      foreign = fixture(:project, %{tenant_id: other_tenant.id})

      non_member =
        post_json(raw, @path, %{"project_id" => sibling.id, "target" => @target})
        |> json_response(422)

      cross_tenant =
        post_json(raw, @path, %{"project_id" => foreign.id, "target" => @target})
        |> json_response(422)

      missing =
        post_json(raw, @path, %{"project_id" => Ecto.UUID.generate(), "target" => @target})
        |> json_response(422)

      assert non_member == cross_tenant
      assert non_member == missing
    end

    test "a blank / oversized target -> 422 with the target message (not an ownership signal)" do
      %{project: project, raw: raw} = setup_member()

      blank =
        post_json(raw, @path, %{"project_id" => project.id, "target" => "  "})
        |> json_response(422)

      assert blank["error"]["message"] =~ "target"

      oversized =
        post_json(raw, @path, %{
          "project_id" => project.id,
          "target" => String.duplicate("a", 500)
        })
        |> json_response(422)

      assert oversized == blank
    end

    test "a key with no agent identity -> 403 agent_identity_required" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      body =
        post_json(raw, @path, %{"project_id" => project.id, "target" => @target})
        |> json_response(403)

      assert body["error"]["code"] == "agent_identity_required"
    end

    test "over-cap lock writes are 429 with Retry-After and a :rate_limited signal" do
      stub_counting_limiter()
      tenant = fixture(:tenant, %{settings: %{"channel_lock_limit_per_minute" => 2}})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      for n <- 1..2 do
        conn =
          post_json(raw, @path, %{
            "project_id" => project.id,
            "target" => "lib/f#{n}.ex",
            "session_id" => "sess-a"
          })

        assert conn.status in [200, 201]
      end

      log =
        capture_log(fn ->
          conn =
            post_json(raw, @path, %{"project_id" => project.id, "target" => "lib/over.ex"})

          assert %{"error" => %{"status" => 429}} = json_response(conn, 429)
          assert [retry] = get_resp_header(conn, "retry-after")
          assert String.to_integer(retry) >= 1
        end)

      assert log =~ "rate_limited"
      assert log =~ "limit_kind=lock"
    end
  end

  describe "POST /api/v1/channel/locks/release" do
    test "releases the caller's own lock -> 200; it stops surfacing" do
      %{project: project, raw: raw} = setup_member()

      params = %{"project_id" => project.id, "target" => @target, "session_id" => "sess-a"}
      created = post_json(raw, @path, params) |> json_response(201)

      released = post_json(raw, @release_path, params) |> json_response(200)
      assert released["released"] == true
      assert released["lock"]["id"] == created["lock"]["id"]

      listing =
        authed_conn(raw)
        |> get(@path, %{"project_id" => project.id})
        |> json_response(200)

      assert listing["locks"] == []
    end

    test "another session's / nonexistent / cross-tenant release -> byte-identical 404" do
      %{project: project, raw: raw} = setup_member()
      other = setup_member()

      post_json(raw, @path, %{
        "project_id" => project.id,
        "target" => @target,
        "session_id" => "sess-a"
      })
      |> json_response(201)

      wrong_session =
        post_json(raw, @release_path, %{
          "project_id" => project.id,
          "target" => @target,
          "session_id" => "sess-zzz"
        })
        |> json_response(404)

      never_locked =
        post_json(raw, @release_path, %{
          "project_id" => project.id,
          "target" => "lib/never.ex",
          "session_id" => "sess-a"
        })
        |> json_response(404)

      cross_tenant =
        post_json(other.raw, @release_path, %{
          "project_id" => project.id,
          "target" => @target,
          "session_id" => "sess-a"
        })
        |> json_response(404)

      assert wrong_session == never_locked
      assert wrong_session == cross_tenant
    end
  end

  describe "GET /api/v1/channel/locks" do
    test "returns the documented JSON shape and only claim:-prefixed live posts" do
      %{project: project, raw: raw, agent: agent} = setup_member()

      post_json(raw, @path, %{
        "project_id" => project.id,
        "target" => @target,
        "session_id" => "sess-a"
      })
      |> json_response(201)

      # An ordinary post and a handoff must NOT appear in the lock listing.
      post_json(raw, "/api/v1/channel/posts", %{
        "project_id" => project.id,
        "body" => "just a note"
      })
      |> json_response(201)

      post_json(raw, "/api/v1/channel/posts", %{
        "project_id" => project.id,
        "body" => "handoff body",
        "key" => "handoff:repo#812",
        "session_id" => "sess-a"
      })
      |> json_response(201)

      body =
        authed_conn(raw)
        |> get(@path, %{"project_id" => project.id})
        |> json_response(200)

      assert [lock] = body["locks"]
      assert lock["target"] == @target
      assert lock["key"] == "claim:#{@target}"
      assert lock["agent_id"] == agent.id
      assert lock["session_id"] == "sess-a"
      assert is_binary(lock["expires_at"])
      assert is_binary(lock["body_preview"])
      assert lock["truncated"] == false

      assert body["meta"]["count"] == 1
      assert body["meta"]["advisory"] == true
      assert body["meta"]["overflow"] == false
      assert body["meta"]["limit"] == 100
    end

    test "tenant isolation: another tenant's project id yields an empty set, never a 404" do
      %{project: project, raw: raw} = setup_member()
      other = setup_member()

      post_json(raw, @path, %{
        "project_id" => project.id,
        "target" => @target,
        "session_id" => "sess-a"
      })
      |> json_response(201)

      body =
        authed_conn(other.raw)
        |> get(@path, %{"project_id" => project.id})
        |> json_response(200)

      assert body["locks"] == []
    end

    test "the requested limit is clamped and reported from one source of truth" do
      %{project: project, raw: raw} = setup_member()

      body =
        authed_conn(raw)
        |> get(@path, %{"project_id" => project.id, "limit" => "1000"})
        |> json_response(200)

      assert body["meta"]["limit"] == 200
    end
  end
end
