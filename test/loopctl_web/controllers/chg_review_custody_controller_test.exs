defmodule LoopctlWeb.ChgReviewCustodyControllerTest do
  @moduledoc """
  US-47.5 over HTTP: real dispatch-minted keys, so the caller's lineage is the one the
  controllers resolve SERVER-SIDE from the authenticating key (`Dispatches.lineage_for_api_key/2`
  and `minting_lineage_for_api_key/2`), never a value a request could carry. The decisions
  themselves are `Loopctl.Changes.ReviewCustodyTest`'s; this module holds the routes, the
  response bodies, and the OpenAPI declarations each refusal now needs.
  """

  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.ApiSpec.Messages
  alias Loopctl.Changes.Events
  alias Loopctl.Changes.Signature
  alias Loopctl.Dispatches
  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  @repo "mkreyman/infra"

  setup do
    tenant = fixture(:tenant)
    agent = fn -> fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator}).id end

    # chg-server's root: a parentless orchestrator dispatch WITH a key, registered on a chg
    # source as `chg_root_dispatch_id`.
    {:ok, %{dispatch: root, raw_key: root_key}} =
      Dispatches.create_dispatch(tenant.id, %{role: :orchestrator, agent_id: agent.()})

    secret = "chg-secret-" <> Base.encode16(:crypto.strong_rand_bytes(16))

    {_webhook_secret, source} =
      fixture(:intake_source, %{
        tenant_id: tenant.id,
        repo_full_name: @repo,
        mode: "chg",
        change_events_secret: secret,
        chg_root_dispatch_id: root.id
      })

    {:ok, %{dispatch: chg_child, raw_key: child_key}} =
      Dispatches.create_dispatch(tenant.id, %{
        role: :orchestrator,
        agent_id: agent.(),
        parent_dispatch_id: root.id
      })

    # The delivery loop's own tree: the implementer, and an orchestrator outside chg.
    {:ok, %{dispatch: loop_root}} =
      Dispatches.create_dispatch(tenant.id, %{role: :orchestrator, agent_id: agent.()})

    impl_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

    {:ok, %{dispatch: impl}} =
      Dispatches.create_dispatch(tenant.id, %{
        role: :agent,
        agent_id: impl_agent.id,
        parent_dispatch_id: loop_root.id
      })

    {:ok, %{dispatch: orch, raw_key: orch_key}} =
      Dispatches.create_dispatch(tenant.id, %{
        role: :orchestrator,
        agent_id: agent.(),
        parent_dispatch_id: loop_root.id
      })

    epic = fixture(:epic, %{tenant_id: tenant.id})

    story =
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
      |> Ecto.Changeset.change(%{
        agent_status: :reported_done,
        reported_done_at: DateTime.add(DateTime.utc_now(), -60, :second),
        assigned_agent_id: impl_agent.id,
        implementer_dispatch_id: impl.id
      })
      |> AdminRepo.update!()

    %{
      tenant: tenant,
      source: source,
      secret: secret,
      root: root,
      root_key: root_key,
      chg_child: chg_child,
      child_key: child_key,
      orch: orch,
      orch_key: orch_key,
      epic: epic,
      story: story,
      new_agent: agent
    }
  end

  defp auth(conn, key), do: put_req_header(conn, "authorization", "Bearer #{key}")

  defp sha(char), do: String.duplicate(char, 40)

  defp submit!(ctx, story, revision_sha) do
    raw =
      Jason.encode!(
        build(:chg_event, %{
          change_id: "C1",
          event_seq: 1,
          kind: "submitted",
          sha: revision_sha,
          data: %{"story_id" => story.id}
        })
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

  defp review_complete(conn, key, story, body) do
    conn
    |> auth(key)
    |> post(
      ~p"/api/v1/stories/#{story.id}/review-complete",
      Map.merge(%{"review_type" => "chg", "summary" => "chg review"}, body)
    )
  end

  defp error_of(conn, status) do
    %{"error" => error} = json_response(conn, status)
    error
  end

  defp child_key(ctx, role) do
    {:ok, %{raw_key: key}} =
      Dispatches.create_dispatch(ctx.tenant.id, %{
        role: role,
        agent_id: ctx.new_agent.(),
        parent_dispatch_id: ctx.root.id
      })

    key
  end

  # A review an orchestrator OUTSIDE chg recorded, so the story is verifiable by anyone the
  # custody gates otherwise admit — the chg refusal is then the only thing in the way.
  defp reviewed(ctx) do
    {:ok, _} =
      Progress.record_review(ctx.tenant.id, ctx.story.id, %{"review_type" => "enhanced"},
        reviewer_agent_id: ctx.orch.agent_id,
        reviewer_lineage: ctx.orch.lineage_path
      )

    ctx.story
  end

  describe "POST /stories/:id/review-complete on a chg story" do
    test "TC-47.5.1: 201 from a chg child naming the revision", %{conn: conn} = ctx do
      :ok = submit!(ctx, ctx.story, sha("a"))

      body =
        conn
        |> review_complete(ctx.child_key, ctx.story, %{"commit_sha" => sha("a")})
        |> json_response(201)

      assert body["review_record"]["commit_sha"] == sha("a")
      assert body["review_record"]["reviewer_dispatch_id"] == ctx.chg_child.id
    end

    test "TC-47.5.2: 409 chg_reviewer_required for an orchestrator outside chg, and for the root",
         %{conn: conn} = ctx do
      :ok = submit!(ctx, ctx.story, sha("a"))

      for key <- [ctx.orch_key, ctx.root_key] do
        error =
          conn
          |> review_complete(key, ctx.story, %{"commit_sha" => sha("a")})
          |> error_of(409)

        assert error["code"] == "chg_reviewer_required"
        assert error["message"] == Messages.chg_reviewer_required()
      end
    end

    test "TC-47.5.3: 422 commit_sha_not_bound for a sha the binding does not have",
         %{conn: conn} = ctx do
      :ok = submit!(ctx, ctx.story, sha("a"))

      error =
        conn
        |> review_complete(ctx.child_key, ctx.story, %{"commit_sha" => sha("b")})
        |> error_of(422)

      assert error["code"] == "commit_sha_not_bound"
      assert error["message"] == Messages.commit_sha_not_bound()
    end

    test "409 chg_review_already_recorded for the same reviewer dispatch's second verdict",
         %{conn: conn} = ctx do
      :ok = submit!(ctx, ctx.story, sha("a"))

      assert conn
             |> review_complete(ctx.child_key, ctx.story, %{"commit_sha" => sha("a")})
             |> json_response(201)

      error =
        build_conn()
        |> review_complete(ctx.child_key, ctx.story, %{"commit_sha" => sha("a")})
        |> error_of(409)

      assert error["code"] == "chg_review_already_recorded"
    end

    test "a non-chg story ignores commit_sha", %{conn: conn} = ctx do
      body =
        conn
        |> review_complete(ctx.orch_key, ctx.story, %{"commit_sha" => sha("a")})
        |> json_response(201)

      assert body["review_record"]["commit_sha"] == nil
      assert body["review_record"]["reviewer_dispatch_id"] == nil
    end

    test "caller_lineage_required is a 409, not an unhandled 500", %{conn: conn} = ctx do
      # A plain (legacy) orchestrator key on dispatch-minted work. Its 409 was documented and
      # the controller's enumerated case had no clause for it.
      {legacy_key, _} =
        fixture(:api_key, %{
          tenant_id: ctx.tenant.id,
          role: :orchestrator,
          agent_id: ctx.new_agent.()
        })

      assert conn
             |> review_complete(legacy_key, ctx.story, %{})
             |> error_of(409)
             |> Map.fetch!("code") == "caller_lineage_required"
    end
  end

  describe "chg_root_cannot_verify on every terminal custody route" do
    test "TC-47.5.4: verify and bulk verify both answer 409", %{conn: conn} = ctx do
      story = reviewed(ctx)

      for {method_path, body} <- [
            {~p"/api/v1/stories/#{story.id}/verify", %{"summary" => "ok"}},
            {~p"/api/v1/stories/bulk/verify", %{"stories" => [%{"story_id" => story.id}]}}
          ] do
        error = conn |> auth(ctx.child_key) |> post(method_path, body) |> error_of(409)
        assert error["code"] == "chg_root_cannot_verify", method_path
        assert error["message"] == Messages.chg_root_cannot_verify()
      end

      assert AdminRepo.get!(Story, story.id).verified_status == :unverified
    end

    test "reject, bulk reject, verify-all, backfill and bulk mark-complete answer 409",
         %{conn: conn} = ctx do
      story = reviewed(ctx)
      pending = fixture(:story, %{tenant_id: ctx.tenant.id, epic_id: ctx.epic.id})

      for {path, body} <- [
            {~p"/api/v1/stories/#{story.id}/reject", %{"reason" => "no"}},
            {~p"/api/v1/stories/bulk/reject",
             %{"stories" => [%{"story_id" => story.id, "reason" => "no"}]}},
            {~p"/api/v1/epics/#{ctx.epic.id}/verify-all",
             %{"review_type" => "chg", "summary" => "all"}},
            {~p"/api/v1/stories/#{pending.id}/backfill", %{"reason" => "pre-existing"}},
            {~p"/api/v1/stories/bulk/mark-complete",
             %{
               "stories" => [
                 %{"story_id" => pending.id, "summary" => "pre", "review_type" => "pre"}
               ]
             }}
          ] do
        error = conn |> auth(ctx.child_key) |> post(path, body) |> error_of(409)
        assert error["code"] == "chg_root_cannot_verify", path
      end

      assert AdminRepo.get!(Story, story.id).verified_status == :unverified
      assert AdminRepo.get!(Story, pending.id).verified_status == :unverified
    end

    test "an EXPIRED chg key is refused too: the controller resolves the MINTING lineage",
         %{conn: conn} = ctx do
      story = reviewed(ctx)

      # The expired-dispatch sweep revokes the dispatch ROW and leaves its key usable
      # (`Dispatches.revoke_dispatch_rows/3`), so the key's LIVE lineage is `[]` — which reject
      # accepts as an unlineaged caller. Only the minting lineage still names chg's root.
      1 = Dispatches.revoke_dispatch_rows(ctx.tenant.id, [ctx.chg_child.id], DateTime.utc_now())
      assert Dispatches.lineage_for_api_key(ctx.tenant.id, ctx.chg_child.api_key_id) == []

      error =
        conn
        |> auth(ctx.child_key)
        |> post(~p"/api/v1/stories/#{story.id}/reject", %{"reason" => "no"})
        |> error_of(409)

      assert error["code"] == "chg_root_cannot_verify"
      assert AdminRepo.get!(Story, story.id).verified_status == :unverified
    end

    test "the same routes still serve an orchestrator outside chg", %{conn: conn} = ctx do
      story = reviewed(ctx)

      assert conn
             |> auth(ctx.orch_key)
             |> post(~p"/api/v1/stories/#{story.id}/verify", %{"summary" => "ok"})
             |> json_response(202)

      assert AdminRepo.get!(Story, story.id).verified_status == :verified
    end
  end

  describe "chg_root_review_only on claim and report" do
    test "a chg agent-role child cannot claim, singly or in bulk", %{conn: conn} = ctx do
      contracted =
        fixture(:story, %{tenant_id: ctx.tenant.id, epic_id: ctx.epic.id})
        |> Ecto.Changeset.change(agent_status: :contracted)
        |> AdminRepo.update!()

      agent_key = child_key(ctx, :agent)

      for {path, body} <- [
            {~p"/api/v1/stories/#{contracted.id}/claim", %{}},
            {~p"/api/v1/stories/bulk/claim", %{"story_ids" => [contracted.id]}}
          ] do
        error = conn |> auth(agent_key) |> post(path, body) |> error_of(409)
        assert error["code"] == "chg_root_review_only", path
        assert error["message"] == Messages.chg_root_review_only()
      end

      assert AdminRepo.get!(Story, contracted.id).agent_status == :contracted
    end

    test "a chg orchestrator child cannot report", %{conn: conn} = ctx do
      implementing =
        ctx.story
        |> Ecto.Changeset.change(agent_status: :implementing, reported_done_at: nil)
        |> AdminRepo.update!()

      error =
        conn
        |> auth(ctx.child_key)
        |> post(~p"/api/v1/stories/#{implementing.id}/report", %{})
        |> error_of(409)

      assert error["code"] == "chg_root_review_only"
    end
  end

  describe "the OpenAPI spec declares each new refusal, with the message the body carries" do
    @declared [
      {"/api/v1/stories/{id}/review-complete", 409, &Messages.chg_reviewer_required/0},
      {"/api/v1/stories/{id}/review-complete", 409, &Messages.chg_review_already_recorded/0},
      {"/api/v1/stories/{id}/review-complete", 422, &Messages.commit_sha_not_bound/0},
      {"/api/v1/stories/{id}/verify", 409, &Messages.chg_root_cannot_verify/0},
      {"/api/v1/stories/{id}/reject", 409, &Messages.chg_root_cannot_verify/0},
      {"/api/v1/epics/{id}/verify-all", 409, &Messages.chg_root_cannot_verify/0},
      {"/api/v1/stories/{id}/backfill", 409, &Messages.chg_root_cannot_verify/0},
      {"/api/v1/stories/bulk/verify", 409, &Messages.chg_root_cannot_verify/0},
      {"/api/v1/stories/bulk/reject", 409, &Messages.chg_root_cannot_verify/0},
      {"/api/v1/stories/bulk/mark-complete", 409, &Messages.chg_root_cannot_verify/0},
      {"/api/v1/stories/{id}/claim", 409, &Messages.chg_root_review_only/0},
      {"/api/v1/stories/bulk/claim", 409, &Messages.chg_root_review_only/0},
      {"/api/v1/stories/{id}/report", 409, &Messages.chg_root_review_only/0}
    ]

    test "every route, status and message" do
      paths = Loopctl.ApiSpec.spec().paths

      for {path, status, message} <- @declared do
        response = paths[path].post.responses[status]
        assert response, "#{path} does not declare #{status}"
        assert response.description =~ message.(), "#{path} #{status} does not quote the message"
      end
    end

    test "review-complete declares commit_sha in its request body" do
      body = Loopctl.ApiSpec.spec().paths["/api/v1/stories/{id}/review-complete"].post.requestBody

      assert %{commit_sha: %{type: :string}} =
               body.content["application/json"].schema.properties
    end
  end
end
