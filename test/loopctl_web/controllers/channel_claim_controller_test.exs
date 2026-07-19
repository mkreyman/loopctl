defmodule LoopctlWeb.ChannelClaimControllerTest do
  @moduledoc """
  US-40.B1 — the coordination-bus CLAIM endpoints:
  `POST /api/v1/channel/claims` (claim), `/done`, `/release`.

  Auth resolution and the claim writes both run through `Loopctl.AdminRepo` (one
  sandbox connection), so this stays `async: true`.
  """
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  @claim_path "/api/v1/channel/claims"
  @done_path "/api/v1/channel/claims/done"
  @release_path "/api/v1/channel/claims/release"
  @sth_header "0:AAAAAAAAAAAAAAAAAAAAAA"

  defp agent_key(tenant, attrs \\ %{}) do
    agent = fixture(:agent, %{tenant_id: tenant.id})

    {raw, key} =
      fixture(
        :api_key,
        Map.merge(%{tenant_id: tenant.id, role: :agent, agent_id: agent.id}, attrs)
      )

    {raw, key, agent}
  end

  # An agent key whose agent is a writable MEMBER of `project` (US-40.D3 gate).
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

  defp post_json(raw, path, params), do: authed_conn(raw) |> post(path, params)

  describe "POST /api/v1/channel/claims" do
    test "a member agent claims a ref -> 201 with the claim" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = member_agent_key(tenant, project)

      conn = post_json(raw, @claim_path, %{project_id: project.id, ref: "handoff:repo#812"})

      body = json_response(conn, 201)
      assert body["claim"]["ref"] == "handoff:repo#812"
      assert body["claim"]["claimant_agent_id"] == agent.id
      assert body["claim"]["tenant_id"] == tenant.id
    end

    test "a second agent claiming the same ref -> 409 already_claimed" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw_a, _k, _a} = member_agent_key(tenant, project)
      {raw_b, _k2, _b} = member_agent_key(tenant, project)

      assert post_json(raw_a, @claim_path, %{project_id: project.id, ref: "r"})
             |> json_response(201)

      conn = post_json(raw_b, @claim_path, %{project_id: project.id, ref: "r"})
      body = json_response(conn, 409)
      assert body["error"]["code"] == "already_claimed"
    end

    test "a non-member agent claim -> 422 ownership_rejected (no oracle)" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = agent_key(tenant)

      conn = post_json(raw, @claim_path, %{project_id: project.id, ref: "r"})
      assert json_response(conn, 422)
    end

    test "a cross-tenant project claim -> 422 (byte-identical to non-member)" do
      tenant_a = fixture(:tenant, %{trust_tier: :agent_rooted})
      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      {raw, _key, _agent} = agent_key(tenant_a)

      conn = post_json(raw, @claim_path, %{project_id: project_b.id, ref: "r"})
      assert json_response(conn, 422)
    end
  end

  describe "POST /api/v1/channel/claims/done and /release" do
    test "claimant marks done -> 200 with done_at set" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      assert post_json(raw, @claim_path, %{project_id: project.id, ref: "r"})
             |> json_response(201)

      conn = post_json(raw, @done_path, %{project_id: project.id, ref: "r"})
      body = json_response(conn, 200)
      assert body["claim"]["done_at"]
    end

    test "a non-owner's done/release -> 404 (byte-identical to missing)" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw_a, _k, _a} = member_agent_key(tenant, project)
      {raw_b, _k2, _b} = member_agent_key(tenant, project)

      assert post_json(raw_a, @claim_path, %{project_id: project.id, ref: "r"})
             |> json_response(201)

      assert post_json(raw_b, @done_path, %{project_id: project.id, ref: "r"})
             |> json_response(404)

      assert post_json(raw_b, @release_path, %{project_id: project.id, ref: "r"})
             |> json_response(404)
    end

    test "release reopens the ref for another agent" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw_a, _k, _a} = member_agent_key(tenant, project)
      {raw_b, _k2, _b} = member_agent_key(tenant, project)

      assert post_json(raw_a, @claim_path, %{project_id: project.id, ref: "r"})
             |> json_response(201)

      assert post_json(raw_a, @release_path, %{project_id: project.id, ref: "r"})
             |> json_response(200)

      # B can now claim the reopened ref.
      assert post_json(raw_b, @claim_path, %{project_id: project.id, ref: "r"})
             |> json_response(201)
    end
  end

  describe "agent identity requirement" do
    test "a key with no agent identity -> 403 agent_identity_required" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn = post_json(raw, @claim_path, %{project_id: project.id, ref: "r"})
      body = json_response(conn, 403)
      assert body["error"]["code"] == "agent_identity_required"
    end
  end
end
