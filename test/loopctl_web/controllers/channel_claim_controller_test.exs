defmodule LoopctlWeb.ChannelClaimControllerTest do
  @moduledoc """
  US-40.B1 — the coordination-bus CLAIM endpoints:
  `POST /api/v1/channel/claims` (claim), `/done`, `/release`, and the #707
  non-destructive read `GET /api/v1/channel/claims`.

  Auth resolution and the claim writes both run through `Loopctl.AdminRepo` (one
  sandbox connection), so this stays `async: true`.
  """
  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Loopctl.Coordination

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

  defp get_json(raw, path, params), do: authed_conn(raw) |> get(path, params)

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

  describe "the session discriminator over HTTP (issue #779)" do
    test "a fresh claim is 201 created; the SAME session re-claiming is 200 already_held with the ORIGINAL claimed_at" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      first =
        raw
        |> post_json(@claim_path, %{
          project_id: project.id,
          ref: "handoff:repo#488",
          session_id: "session-minis",
          host: "minis"
        })
        |> json_response(201)

      assert first["created"] == true
      assert first["already_held"] == false
      assert first["same_session"] == true
      assert first["claim"]["claimed_by_session"] == "session-minis"
      assert first["claim"]["claimed_by_host"] == "minis"

      again =
        raw
        |> post_json(@claim_path, %{
          project_id: project.id,
          ref: "handoff:repo#488",
          session_id: "session-minis"
        })
        |> json_response(200)

      assert again["created"] == false
      assert again["already_held"] == true
      assert again["same_session"] == true
      assert again["claim"]["claimed_at"] == first["claim"]["claimed_at"]
    end

    # THE INCIDENT, end to end (KB b447b16b): one agent key, two machines.
    test "a PEER SESSION's re-claim is 200 already_held with same_session false and the peer's stamp" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      first =
        raw
        |> post_json(@claim_path, %{
          project_id: project.id,
          ref: "handoff:repo#488",
          session_id: "session-minis",
          host: "minis"
        })
        |> json_response(201)

      peer =
        raw
        |> post_json(@claim_path, %{
          project_id: project.id,
          ref: "handoff:repo#488",
          session_id: "session-mac-mini",
          host: "mac-mini"
        })
        |> json_response(200)

      assert peer["already_held"] == true
      assert peer["created"] == false
      assert peer["same_session"] == false
      assert peer["claim"]["claimed_by_session"] == "session-minis"
      assert peer["claim"]["claimed_by_host"] == "minis"
      assert peer["claim"]["claimed_at"] == first["claim"]["claimed_at"]
    end

    test "done and release from a PEER SESSION are 409 claim_session_mismatch and change nothing" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      assert raw
             |> post_json(@claim_path, %{
               project_id: project.id,
               ref: "r",
               session_id: "session-a"
             })
             |> json_response(201)

      for path <- [@done_path, @release_path] do
        body =
          raw
          |> post_json(path, %{project_id: project.id, ref: "r", session_id: "session-b"})
          |> json_response(409)

        assert body["error"]["code"] == "claim_session_mismatch"
      end

      # Still open, still there — the release did not delete the peer's live claim.
      assert [%{"done" => false, "claimed_by_session" => "session-a"}] =
               raw
               |> get_json(@claim_path, %{project_id: project.id, ref: "r"})
               |> json_response(200)
               |> Map.fetch!("claims")
    end

    test "force: true lets a restarted session finish its own work in one call" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      assert raw
             |> post_json(@claim_path, %{
               project_id: project.id,
               ref: "r",
               session_id: "session-before-crash"
             })
             |> json_response(201)

      body =
        raw
        |> post_json(@done_path, %{
          project_id: project.id,
          ref: "r",
          session_id: "session-after-relaunch",
          force: true
        })
        |> json_response(200)

      assert body["claim"]["done_at"]
    end

    test "force is only the boolean true or the string 'true' — 'false' does NOT bypass the guard" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      assert raw
             |> post_json(@claim_path, %{
               project_id: project.id,
               ref: "r",
               session_id: "session-a"
             })
             |> json_response(201)

      for force <- ["false", "0", "no"] do
        body =
          raw
          |> post_json(@done_path, %{
            project_id: project.id,
            ref: "r",
            session_id: "session-b",
            force: force
          })
          |> json_response(409)

        assert body["error"]["code"] == "claim_session_mismatch"
      end

      # The POSITIVE half of the title, which nothing else covers: a form/query client
      # sends the STRING "true", and without this clause it silently loses its override
      # and gets a 409 it cannot clear.
      body =
        raw
        |> post_json(@done_path, %{
          project_id: project.id,
          ref: "r",
          session_id: "session-b",
          force: "true"
        })
        |> json_response(200)

      assert body["claim"]["done_at"]
    end

    test "a cross-tenant claim still 404s — the session 409 is never an existence oracle" do
      tenant_a = fixture(:tenant, %{trust_tier: :agent_rooted})
      project_a = fixture(:project, %{tenant_id: tenant_a.id})
      {raw_a, _k, _a} = member_agent_key(tenant_a, project_a)

      tenant_b = fixture(:tenant, %{trust_tier: :agent_rooted})
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      {raw_b, _k2, _b} = member_agent_key(tenant_b, project_b)

      assert raw_b
             |> post_json(@claim_path, %{
               project_id: project_b.id,
               ref: "handoff:shared#1",
               session_id: "session-b"
             })
             |> json_response(201)

      assert raw_a
             |> post_json(@release_path, %{
               project_id: project_b.id,
               ref: "handoff:shared#1",
               session_id: "session-b"
             })
             |> json_response(404)
    end

    test "#779: a NUL byte in session_id on done/release is a 422, never a 500" do
      # The claim path already answered 422 for this; done/release wrote the raw value
      # into the audit entry's jsonb metadata, where Postgres refuses the escape Jason
      # emits for a NUL byte (22P05) and the request 500'd. The trigger needs no
      # stamped claim: an UNDISCRIMINABLE row passes the guard and reaches the audit.
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      assert raw
             |> post_json(@claim_path, %{project_id: project.id, ref: "r"})
             |> json_response(201)

      for path <- [@done_path, @release_path] do
        body =
          raw
          |> post_json(path, %{
            project_id: project.id,
            ref: "r",
            session_id: "x" <> <<0>> <> "y"
          })
          |> json_response(422)

        # Keyed on the parameter the caller SENT. done/release write no
        # `claimed_by_session` column, so naming it told the client a field it does not
        # have is invalid — unmappable back to its own request.
        assert Map.has_key?(body["error"]["details"], "session_id")
        refute Map.has_key?(body["error"]["details"], "claimed_by_session")
      end

      # And the claim survived both refusals.
      assert raw
             |> post_json(@done_path, %{project_id: project.id, ref: "r"})
             |> json_response(200)
    end

    test "#779: an invalid-UTF-8 session_id on done/release is a 422, never a raw 500" do
      # The sibling of the NUL byte, reachable through the endpoint's :urlencoded parser
      # (it URL-decodes to a raw binary with no encoding check). Every guard on this value
      # is byte-oriented, so it passed all of them and then raised Jason.EncodeError on
      # the audit metadata jsonb / Postgres 22021 on the claim path's text column.
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      assert raw
             |> post_json(@claim_path, %{project_id: project.id, ref: "r"})
             |> json_response(201)

      for path <- [@done_path, @release_path] do
        assert raw
               |> post_json(path, %{
                 project_id: project.id,
                 ref: "r",
                 session_id: <<"sess-", 0xFF>>
               })
               |> json_response(422)
      end

      assert raw
             |> post_json(@done_path, %{project_id: project.id, ref: "r"})
             |> json_response(200)
    end

    test "releasing an already-DONE claim is 409 already_claimed, not a 500" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      assert raw
             |> post_json(@claim_path, %{
               project_id: project.id,
               ref: "r",
               session_id: "session-a"
             })
             |> json_response(201)

      assert raw
             |> post_json(@done_path, %{project_id: project.id, ref: "r", session_id: "session-a"})
             |> json_response(200)

      body =
        raw
        |> post_json(@release_path, %{
          project_id: project.id,
          ref: "r",
          session_id: "session-a"
        })
        |> json_response(409)

      assert body["error"]["code"] == "already_claimed"
    end

    test "the read reports same_session, and null when either side is unstamped" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      assert raw
             |> post_json(@claim_path, %{
               project_id: project.id,
               ref: "r",
               session_id: "session-a",
               host: "minis"
             })
             |> json_response(201)

      assert [%{"same_session" => true, "claimed_by_host" => "minis"}] =
               raw
               |> get_json(@claim_path, %{
                 project_id: project.id,
                 ref: "r",
                 session_id: "session-a"
               })
               |> json_response(200)
               |> Map.fetch!("claims")

      assert [%{"same_session" => false}] =
               raw
               |> get_json(@claim_path, %{
                 project_id: project.id,
                 ref: "r",
                 session_id: "session-b"
               })
               |> json_response(200)
               |> Map.fetch!("claims")

      # No session on the request: UNDISCRIMINABLE, reported as null rather than false.
      assert [%{"same_session" => nil}] =
               raw
               |> get_json(@claim_path, %{project_id: project.id, ref: "r"})
               |> json_response(200)
               |> Map.fetch!("claims")
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

  describe "GET /api/v1/channel/claims (#707)" do
    test "reports a claimed ref without writing anything — the point of the endpoint" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = member_agent_key(tenant, project)

      assert %{"claim" => %{"id" => claim_id}} =
               raw
               |> post_json(@claim_path, %{project_id: project.id, ref: "handoff:repo#812"})
               |> json_response(201)

      body = raw |> get_json(@claim_path, %{project_id: project.id}) |> json_response(200)

      assert [listed] = body["claims"]
      assert listed["id"] == claim_id
      assert listed["ref"] == "handoff:repo#812"
      assert listed["claimant_agent_id"] == agent.id
      assert listed["done"] == false
      assert body["meta"]["count"] == 1
      assert body["meta"]["overflow"] == false

      # The read did not disturb the claim: the owner can still release it, which it
      # could not do if the read had consumed or rewritten the row.
      assert raw
             |> post_json(@release_path, %{project_id: project.id, ref: "handoff:repo#812"})
             |> json_response(200)
    end

    test "an unclaimed ref is an empty list — the answer that used to require a probe" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      body =
        raw
        |> get_json(@claim_path, %{project_id: project.id, ref: "handoff:repo#never"})
        |> json_response(200)

      assert body["claims"] == []
      assert body["meta"]["count"] == 0
    end

    test "a PEER SESSION's claim is visible to the reader, and reading leaves it intact" do
      # The #707 shape: two sessions, ONE agent key. Before this endpoint the only way
      # for the second session to learn the ref was taken was to claim it — which, being
      # idempotent for the owning agent, handed back the peer's claim, and the tidy-up
      # release then deleted it.
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      assert %{"claim" => %{"id" => claim_id}} =
               raw
               |> post_json(@claim_path, %{project_id: project.id, ref: "handoff:repo#813"})
               |> json_response(201)

      body =
        raw
        |> get_json(@claim_path, %{project_id: project.id, ref: "handoff:repo#813"})
        |> json_response(200)

      assert [%{"id" => ^claim_id}] = body["claims"]

      # Still there after the read.
      assert [%{"id" => ^claim_id}] =
               raw
               |> get_json(@claim_path, %{project_id: project.id})
               |> json_response(200)
               |> Map.fetch!("claims")
    end

    test "another tenant's project returns an empty page, never a 404 and never its rows" do
      tenant_a = fixture(:tenant, %{trust_tier: :agent_rooted})
      project_a = fixture(:project, %{tenant_id: tenant_a.id})
      {raw_a, _k, _a} = member_agent_key(tenant_a, project_a)

      tenant_b = fixture(:tenant, %{trust_tier: :agent_rooted})
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      {raw_b, _k2, _b} = member_agent_key(tenant_b, project_b)

      assert raw_b
             |> post_json(@claim_path, %{project_id: project_b.id, ref: "handoff:shared#1"})
             |> json_response(201)

      body = raw_a |> get_json(@claim_path, %{project_id: project_b.id}) |> json_response(200)
      assert body["claims"] == []
    end

    test "a missing or malformed project_id is refused, never answered as 'all free'" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      # An empty page is documented as "that ref is claimable", so a caller that simply
      # omitted project_id (the MCP client only sets it when present) must not be told
      # every ref is free. A syntactically invalid id leaks no existence oracle.
      assert raw |> get_json(@claim_path, %{project_id: "not-a-uuid"}) |> json_response(422)
      assert raw |> get_json(@claim_path, %{}) |> json_response(422)
    end

    test "an expired-but-unswept claim is listed with expired: true — not reported free" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      assert raw
             |> post_json(@claim_path, %{project_id: project.id, ref: "handoff:repo#814"})
             |> json_response(201)

      Loopctl.AdminRepo.update_all(
        from(c in Loopctl.Coordination.ChannelClaim, where: c.tenant_id == ^tenant.id),
        set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -5, :second)]
      )

      body =
        raw
        |> get_json(@claim_path, %{project_id: project.id, ref: "handoff:repo#814"})
        |> json_response(200)

      assert [%{"expired" => true, "done" => false}] = body["claims"]

      # And the write agrees: this ref is NOT claimable, which is why the read lists it.
      assert raw
             |> post_json(@claim_path, %{project_id: project.id, ref: "handoff:repo#814"})
             |> json_response(409)
    end

    test "a malformed ref is refused, not answered with the whole channel and not a 500" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      assert raw
             |> post_json(@claim_path, %{project_id: project.id, ref: "handoff:repo#818"})
             |> json_response(201)

      # A NUL byte is valid UTF-8, so Plug forwards it; Postgres refuses to compare it
      # against `text` and would 500 if it reached the query. An empty page is no answer
      # either — it reads as "nothing holds this ref", and the WRITE refuses these with
      # a 422, so the read must not report them free.
      for bad <- [<<"handoff:", 0, "x">>, "", "   ", String.duplicate("x", 513)] do
        assert raw
               |> get_json(@claim_path, %{project_id: project.id, ref: bad})
               |> json_response(422)
      end
    end

    test "the cap is reported rather than silently applied" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      for n <- 1..3 do
        assert raw
               |> post_json(@claim_path, %{project_id: project.id, ref: "handoff:repo##{n}"})
               |> json_response(201)
      end

      body =
        raw |> get_json(@claim_path, %{project_id: project.id, limit: "2"}) |> json_response(200)

      assert length(body["claims"]) == 2
      assert body["meta"]["overflow"] == true
      assert body["meta"]["limit"] == 2
    end
  end

  describe "the 409 is split by cause (#707 follow-up)" do
    test "an expired-but-unswept lease -> 409 claim_lease_expired with a retry-after" do
      # The one 409 on this surface where the old unconditional "move on to other work"
      # was wrong: the row is a husk awaiting the sweeper, so the ref is about to be free.
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      assert %{"claim" => %{"id" => claim_id}} =
               raw
               |> post_json(@claim_path, %{project_id: project.id, ref: "handoff:expired"})
               |> json_response(201)

      Loopctl.AdminRepo.update_all(
        from(c in Loopctl.Coordination.ChannelClaim, where: c.id == ^claim_id),
        set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -5, :second)]
      )

      conn = post_json(raw, @claim_path, %{project_id: project.id, ref: "handoff:expired"})
      body = json_response(conn, 409)

      assert body["error"]["code"] == "claim_lease_expired"
      assert body["error"]["message"] =~ "retry THIS ref"
      assert [_] = get_resp_header(conn, "retry-after")
    end

    test "a caller at its claim budget -> 409 claim_budget_exhausted, and the ref is free" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, _agent} = member_agent_key(tenant, project)

      for n <- 1..Coordination.max_concurrent_open_claims() do
        assert raw
               |> post_json(@claim_path, %{project_id: project.id, ref: "handoff:b##{n}"})
               |> json_response(201)
      end

      body =
        raw
        |> post_json(@claim_path, %{project_id: project.id, ref: "handoff:untouched"})
        |> json_response(409)

      assert body["error"]["code"] == "claim_budget_exhausted"

      # The distinction is load-bearing, not cosmetic: a DIFFERENT agent takes the very
      # ref the first was refused, which is why reporting this as already_claimed made
      # the caller record a free ref as taken.
      {raw_b, _k, _a} = member_agent_key(tenant, project)

      assert raw_b
             |> post_json(@claim_path, %{project_id: project.id, ref: "handoff:untouched"})
             |> json_response(201)
    end
  end
end
