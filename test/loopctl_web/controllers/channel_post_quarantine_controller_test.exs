defmodule LoopctlWeb.ChannelPostQuarantineControllerTest do
  @moduledoc """
  The OPERATOR quarantine surface (issue #499):

    * `GET /api/v1/channel/posts/quarantined` — the ONLY read that resolves posts the
      retroactive secret rescan flagged;
    * `POST /api/v1/channel/posts/:id/release` — the non-destructive exoneration path.

  Both are `role: :user` — an agent must never be able to read back, or resurrect, a
  quarantined credential.
  """

  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.Workers.ChannelPostRescanWorker

  @sth_header "0:AAAAAAAAAAAAAAAAAAAAAA"
  @secret "lc_abcdefghijklmnopqrstuvwxyz012345"
  @list_path "/api/v1/channel/posts/quarantined"

  defp authed_conn(raw) do
    build_conn()
    |> put_req_header("x-loopctl-last-known-sth", @sth_header)
    |> put_req_header("authorization", "Bearer #{raw}")
  end

  defp key_for(tenant, role) do
    agent = fixture(:agent, %{tenant_id: tenant.id})

    {raw, _key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: role, agent_id: agent.id})

    raw
  end

  setup do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    agent = fixture(:agent, %{tenant_id: tenant.id})

    # A post written BEFORE the pattern existed (the write-time gate would reject it),
    # then quarantined by the rescan.
    post =
      %ChannelPost{
        tenant_id: tenant.id,
        project_id: project.id,
        agent_id: agent.id,
        body: "here is the key #{@secret}",
        expires_at: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
      }
      |> AdminRepo.insert!()

    assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

    %{tenant: tenant, project: project, post: post}
  end

  describe "GET /channel/posts/quarantined" do
    test "a user key sees the flagged rows with full bodies", %{tenant: tenant, post: post} do
      body =
        tenant
        |> key_for(:user)
        |> authed_conn()
        |> get(@list_path)
        |> json_response(200)

      assert [row] = body["data"]
      assert row["id"] == post.id
      assert row["body"] =~ @secret
      assert row["quarantine_reason"] == "secret_denylist: body"
      assert body["meta"]["count"] == 1
    end

    # The reason names a FIELD; a payload omitting that field leaves the operator unable
    # to judge true vs false positive on the one endpoint that resolves these rows.
    test "returns EVERY scanned field, so any quarantine reason is reviewable", %{
      tenant: tenant,
      project: project
    } do
      agent = fixture(:agent, %{tenant_id: tenant.id})

      %ChannelPost{
        tenant_id: tenant.id,
        project_id: project.id,
        agent_id: agent.id,
        body: "ordinary chatter",
        to_capability: "cap-#{@secret}",
        to_host: "peer-box",
        idempotency_key: "tok-review",
        expires_at: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
      }
      |> AdminRepo.insert!()

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      row =
        tenant
        |> key_for(:user)
        |> authed_conn()
        |> get(@list_path)
        |> json_response(200)
        |> Map.fetch!("data")
        |> Enum.find(&(&1["quarantine_reason"] == "secret_denylist: to_capability"))

      assert row["to_capability"] =~ @secret
      assert row["to_host"] == "peer-box"
      assert row["idempotency_key"] == "tok-review"
    end

    # meta.limit must report the CLAMPED bound the context applied, never the request.
    test "meta.limit reports the clamped value, not the requested one", %{tenant: tenant} do
      raw = key_for(tenant, :user)

      for {requested, reported} <- [{"1000", 100}, {"0", 25}, {"-5", 25}, {"10", 10}] do
        body =
          raw
          |> authed_conn()
          |> get(@list_path, %{"limit" => requested})
          |> json_response(200)

        assert body["meta"]["limit"] == reported
      end
    end

    test "an agent key is 403'd — quarantined credentials are not agent-readable", %{
      tenant: tenant
    } do
      assert tenant
             |> key_for(:agent)
             |> authed_conn()
             |> get(@list_path)
             |> json_response(403)
    end

    test "the static path is not shadowed by the :id show route", %{tenant: tenant} do
      # GET /channel/posts/:id is agent-role; if `quarantined` were captured as an id,
      # an agent key would get a 404 here instead of the 403 above.
      assert tenant |> key_for(:user) |> authed_conn() |> get(@list_path) |> json_response(200)
    end

    test "is tenant-scoped", %{tenant: _tenant} do
      other = fixture(:tenant)

      body =
        other
        |> key_for(:user)
        |> authed_conn()
        |> get(@list_path)
        |> json_response(200)

      assert body["data"] == []
    end
  end

  describe "POST /channel/posts with a quarantined idempotency token" do
    test "returns an explicit 422, never a false deduplicated success", %{
      tenant: tenant,
      project: project
    } do
      agent = fixture(:agent, %{tenant_id: tenant.id})

      fixture(:story, %{
        tenant_id: tenant.id,
        project_id: project.id,
        assigned_agent_id: agent.id,
        agent_status: :assigned
      })

      {raw, _key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      %ChannelPost{
        tenant_id: tenant.id,
        project_id: project.id,
        agent_id: agent.id,
        idempotency_key: "tok-http-499",
        body: "leak #{@secret}",
        expires_at: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
      }
      |> AdminRepo.insert!()

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      body =
        raw
        |> authed_conn()
        |> post("/api/v1/channel/posts", %{
          "project_id" => project.id,
          "body" => "clean retry under the same token",
          "idempotency_key" => "tok-http-499"
        })
        |> json_response(422)

      assert inspect(body) =~ "quarantined"
      refute inspect(body) =~ @secret
    end
  end

  describe "POST /channel/posts/:id/release" do
    test "a user key releases the post and it becomes readable again", %{
      tenant: tenant,
      post: post
    } do
      raw = key_for(tenant, :user)

      body =
        raw
        |> authed_conn()
        |> post("/api/v1/channel/posts/#{post.id}/release")
        |> json_response(200)

      assert body["released"] == true
      assert body["post"]["id"] == post.id

      # Gone from the review list, back on the channel.
      assert raw |> authed_conn() |> get(@list_path) |> json_response(200) |> Map.get("data") ==
               []

      reloaded = AdminRepo.get(ChannelPost, post.id)
      assert is_nil(reloaded.quarantined_at)
      assert %DateTime{} = reloaded.quarantine_released_at
    end

    test "an agent key cannot un-hide a quarantined post", %{tenant: tenant, post: post} do
      assert tenant
             |> key_for(:agent)
             |> authed_conn()
             |> post("/api/v1/channel/posts/#{post.id}/release")
             |> json_response(403)

      assert %DateTime{} = AdminRepo.get(ChannelPost, post.id).quarantined_at
    end

    test "an unknown or foreign-tenant id is a 404", %{tenant: tenant, post: post} do
      raw = key_for(tenant, :user)

      assert raw
             |> authed_conn()
             |> post("/api/v1/channel/posts/#{Ecto.UUID.generate()}/release")
             |> json_response(404)

      other = fixture(:tenant)

      assert other
             |> key_for(:user)
             |> authed_conn()
             |> post("/api/v1/channel/posts/#{post.id}/release")
             |> json_response(404)
    end
  end
end
