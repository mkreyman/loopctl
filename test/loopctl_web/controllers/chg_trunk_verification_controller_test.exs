defmodule LoopctlWeb.ChgTrunkVerificationControllerTest do
  @moduledoc """
  US-47.6 over HTTP: the response a chg story's trunk-evidence gate gives on the verify routes —
  the 409 refusals, the 503 `chg_trunk_unevaluated` with its `Retry-After`, and the OpenAPI
  declarations. The decisions are `Loopctl.Changes.TrunkEvidenceTest`'s. Keys are
  dispatch-minted, so the caller's lineage is resolved server-side from the key.
  """

  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.ApiSpec.Messages
  alias Loopctl.Changes.Events
  alias Loopctl.Changes.Signature
  alias Loopctl.Dispatches
  alias Loopctl.MockPullRequestSource
  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  setup do
    %{secret: secret, source: source, root: root} = fixture(:chg_source, %{})
    tenant_id = source.tenant_id
    agent = fn -> fixture(:agent, %{tenant_id: tenant_id, agent_type: :orchestrator}).id end

    {:ok, %{dispatch: loop_root}} =
      Dispatches.create_dispatch(tenant_id, %{role: :orchestrator, agent_id: agent.()})

    impl_agent = fixture(:agent, %{tenant_id: tenant_id, agent_type: :implementer})

    {:ok, %{dispatch: impl}} =
      Dispatches.create_dispatch(tenant_id, %{
        role: :agent,
        agent_id: impl_agent.id,
        parent_dispatch_id: loop_root.id
      })

    {:ok, %{raw_key: orch_key}} =
      Dispatches.create_dispatch(tenant_id, %{
        role: :orchestrator,
        agent_id: agent.(),
        parent_dispatch_id: loop_root.id
      })

    epic = fixture(:epic, %{tenant_id: tenant_id})

    story =
      fixture(:story, %{tenant_id: tenant_id, epic_id: epic.id})
      |> Ecto.Changeset.change(%{
        agent_status: :reported_done,
        reported_done_at: DateTime.add(DateTime.utc_now(), -60, :second),
        assigned_agent_id: impl_agent.id,
        implementer_dispatch_id: impl.id
      })
      |> AdminRepo.update!()

    ctx = %{tenant_id: tenant_id, secret: secret, source: source, root: root, epic: epic}

    :ok = push!(ctx, 1, "submitted", %{sha: sha("a"), data: %{"story_id" => story.id}})
    :ok = push!(ctx, 2, "landed", %{sha: sha("a"), data: %{"merge_sha" => sha("c")}})
    child = fixture(:chg_root_dispatch, %{tenant_id: tenant_id, parent: root})

    {:ok, _} =
      Progress.record_review(
        tenant_id,
        story.id,
        %{"review_type" => "chg", "summary" => "chg review", "commit_sha" => sha("a")},
        reviewer_agent_id: fixture(:agent, %{tenant_id: tenant_id}).id,
        reviewer_lineage: child.lineage_path
      )

    Map.merge(ctx, %{story: story, orch_key: orch_key})
  end

  defp sha(char), do: String.duplicate(char, 40)

  defp push!(ctx, seq, kind, attrs) do
    raw =
      Jason.encode!(
        build(:chg_event, Map.merge(%{change_id: "C1", event_seq: seq, kind: kind}, attrs))
      )

    ts = Integer.to_string(System.os_time(:second))

    assert {:ok, %{outcome: :applied}} =
             Events.receive_push(ctx.source.id, %{
               raw_body: raw,
               timestamp: ts,
               signature: Signature.header(ctx.secret, Signature.delivery_string(ts, raw))
             })

    :ok
  end

  defp verify(conn, ctx) do
    conn
    |> put_req_header("authorization", "Bearer #{ctx.orch_key}")
    |> post(~p"/api/v1/stories/#{ctx.story.id}/verify", %{"summary" => "ok"})
  end

  defp forge(answer),
    do:
      expect(MockPullRequestSource, :contains?, fn _repo, merge_sha, "verified/master" ->
        assert merge_sha == sha("c")
        answer
      end)

  test "202 when the landing is in verified/master", %{conn: conn} = ctx do
    forge({:ok, true})
    assert conn |> verify(ctx) |> json_response(202)
    assert AdminRepo.get!(Story, ctx.story.id).verified_status == :verified
  end

  test "TC-47.6.1: 409 chg_landing_not_trunk_verified", %{conn: conn} = ctx do
    forge({:ok, false})
    %{"error" => error} = conn |> verify(ctx) |> json_response(409)

    assert error["code"] == "chg_landing_not_trunk_verified"
    assert error["message"] == Messages.chg_landing_not_trunk_verified()
    assert AdminRepo.get!(Story, ctx.story.id).verified_status == :unverified
  end

  test "TC-47.6.2: 409 chg_landing_reverted", %{conn: conn} = ctx do
    :ok = push!(ctx, 3, "verified", %{sha: sha("a"), data: %{"sha" => sha("c")}})
    :ok = push!(ctx, 4, "reverted", %{sha: sha("a"), data: %{"landed_sha" => sha("c")}})
    expect(MockPullRequestSource, :contains?, 0, fn _, _, _ -> :unused end)

    %{"error" => error} = conn |> verify(ctx) |> json_response(409)
    assert error["code"] == "chg_landing_reverted"
    assert error["message"] == Messages.chg_landing_reverted()
  end

  test "TC-47.6.3: a slow forge is 503 chg_trunk_unevaluated with Retry-After",
       %{conn: conn} = ctx do
    forge({:error, {:github_unreachable, :timeout}})
    conn = verify(conn, ctx)

    assert %{"error" => error} = json_response(conn, 503)
    assert get_resp_header(conn, "retry-after") == ["30"]
    assert error["code"] == "chg_trunk_unevaluated"
    assert error["decision"] == "unevaluated"
    assert error["reason"] == "forge_unavailable"
    assert error["retry_after_seconds"] == 30
    assert error["message"] == Messages.chg_trunk_unevaluated()
    assert AdminRepo.get!(Story, ctx.story.id).verified_status == :unverified
  end

  test "a missing verified/master ref is 503 trunk_ref_not_found, with the forge's delay " <>
         "when a rate limit names one",
       %{conn: conn} = ctx do
    forge({:error, {:github_api_error, 404}})

    assert %{"error" => %{"reason" => "trunk_ref_not_found"}} =
             conn |> verify(ctx) |> json_response(503)

    forge({:error, {:github_rate_limited, 403, 240}})
    conn = verify(build_conn(), ctx)
    assert json_response(conn, 503)["error"]["reason"] == "forge_unavailable"
    assert get_resp_header(conn, "retry-after") == ["240"]
  end

  test "backfill forwards the 503 tuple rather than crashing on it", %{conn: conn} = ctx do
    pending =
      fixture(:story, %{tenant_id: ctx.tenant_id, epic_id: ctx.epic.id})
      |> Ecto.Changeset.change(%{agent_status: :reported_done})
      |> AdminRepo.update!()

    c2 = fn seq, kind, attrs ->
      raw =
        Jason.encode!(
          build(:chg_event, Map.merge(%{change_id: "C2", event_seq: seq, kind: kind}, attrs))
        )

      ts = Integer.to_string(System.os_time(:second))

      assert {:ok, %{outcome: :applied}} =
               Events.receive_push(ctx.source.id, %{
                 raw_body: raw,
                 timestamp: ts,
                 signature: Signature.header(ctx.secret, Signature.delivery_string(ts, raw))
               })
    end

    c2.(1, "submitted", %{sha: sha("b"), data: %{"story_id" => pending.id}})
    c2.(2, "landed", %{sha: sha("b"), data: %{"merge_sha" => sha("c")}})

    fixture(:review_record, %{
      tenant_id: ctx.tenant_id,
      story_id: pending.id,
      commit_sha: sha("b"),
      reviewer_dispatch_id:
        fixture(:chg_root_dispatch, %{tenant_id: ctx.tenant_id, parent: ctx.root}).id
    })

    forge({:error, {:github_api_error, 502}})

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{ctx.orch_key}")
      |> post(~p"/api/v1/stories/#{pending.id}/backfill", %{"reason" => "pre-existing"})

    assert json_response(conn, 503)["error"]["code"] == "chg_trunk_unevaluated"
    assert get_resp_header(conn, "retry-after") == ["30"]
  end

  describe "the OpenAPI spec declares each new answer, with its message" do
    @declared [
      {"/api/v1/stories/{id}/verify", 409, &Messages.chg_landing_not_trunk_verified/0},
      {"/api/v1/stories/{id}/verify", 409, &Messages.chg_landing_reverted/0},
      {"/api/v1/stories/{id}/verify", 503, &Messages.chg_trunk_unevaluated/0},
      {"/api/v1/stories/{id}/backfill", 409, &Messages.chg_landing_not_trunk_verified/0},
      {"/api/v1/stories/{id}/backfill", 409, &Messages.chg_landing_reverted/0},
      {"/api/v1/stories/{id}/backfill", 503, &Messages.chg_trunk_unevaluated/0}
    ]

    test "every route, status and message" do
      paths = Loopctl.ApiSpec.spec().paths

      for {path, status, message} <- @declared do
        response = paths[path].post.responses[status]
        assert response, "#{path} does not declare #{status}"
        assert response.description =~ message.(), "#{path} #{status} does not quote the message"
      end
    end

    test "verify-all and the bulk routes name the per-story trunk codes" do
      paths = Loopctl.ApiSpec.spec().paths

      for path <- [
            "/api/v1/epics/{id}/verify-all",
            "/api/v1/stories/bulk/verify",
            "/api/v1/stories/bulk/mark-complete"
          ],
          code <- ~w(chg_landing_not_trunk_verified chg_landing_reverted chg_trunk_unevaluated) do
        assert paths[path].post.description =~ code, "#{path} does not name #{code}"
      end
    end
  end

  test "tenant isolation: another tenant's key cannot reach this story", %{conn: conn} = ctx do
    other = fixture(:tenant)

    {:ok, %{raw_key: other_key}} =
      Dispatches.create_dispatch(other.id, %{
        role: :orchestrator,
        agent_id: fixture(:agent, %{tenant_id: other.id, agent_type: :orchestrator}).id
      })

    expect(MockPullRequestSource, :contains?, 0, fn _, _, _ -> :unused end)

    conn
    |> put_req_header("authorization", "Bearer #{other_key}")
    |> post(~p"/api/v1/stories/#{ctx.story.id}/verify", %{"summary" => "ok"})
    |> json_response(404)

    assert AdminRepo.get!(Story, ctx.story.id).verified_status == :unverified
  end
end
