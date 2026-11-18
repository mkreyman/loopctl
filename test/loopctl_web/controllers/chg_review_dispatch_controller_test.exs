defmodule LoopctlWeb.ChgReviewDispatchControllerTest do
  @moduledoc """
  US-50.3: `POST /api/v1/change_events/:source_id/review_dispatch`, the review key a fleet
  chgd obtains from its intake source, and that key's reach under US-47.5's chg review custody.
  """

  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain.Entry
  alias Loopctl.Changes.Events
  alias Loopctl.Changes.ReviewCustody
  alias Loopctl.Changes.ReviewDispatches
  alias Loopctl.Changes.Signature
  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Tenants.Tenant

  setup :verify_on_exit!

  @unauthorized %{
    "error" => %{
      "status" => 401,
      "code" => "invalid_signature",
      "message" => "The event could not be authenticated."
    }
  }

  setup do
    %{secret: secret, source: source, root: root} = fixture(:chg_source, %{})
    tenant_id = source.tenant_id

    impl_agent = fixture(:agent, %{tenant_id: tenant_id, agent_type: :implementer})

    {:ok, %{dispatch: impl}} =
      Dispatches.create_dispatch(tenant_id, %{role: :agent, agent_id: impl_agent.id})

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

    ctx = %{tenant_id: tenant_id, secret: secret, source: source, root: root, story: story}
    submit!(ctx, "C1", 1, 1, sha("a"))
    ctx
  end

  defp sha(char), do: String.duplicate(char, 40)

  defp submit!(ctx, change_id, seq, revision, revision_sha) do
    event =
      build(:chg_event, %{
        change_id: change_id,
        event_seq: seq,
        kind: "submitted",
        revision: revision,
        sha: revision_sha,
        data: %{"story_id" => ctx.story.id}
      })

    raw = Jason.encode!(event)
    ts = Integer.to_string(System.os_time(:second))
    signature = Signature.header(ctx.secret, Signature.delivery_string(ts, raw))

    assert {:ok, %{outcome: :applied}} =
             Events.receive_push(ctx.source.id, %{
               raw_body: raw,
               timestamp: ts,
               signature: signature
             })
  end

  defp request(conn, ctx, body, opts \\ []) do
    raw = Jason.encode!(body)
    ts = Integer.to_string(System.os_time(:second))
    secret = Keyword.get(opts, :secret, ctx.secret)

    signature =
      Keyword.get(opts, :signature, Signature.header(secret, Signature.delivery_string(ts, raw)))

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-chg-timestamp", ts)
    |> put_req_header("x-chg-signature", signature)
    |> post(
      "/api/v1/change_events/#{Keyword.get(opts, :source_id, ctx.source.id)}/review_dispatch",
      raw
    )
  end

  defp mint!(ctx, revision \\ 1) do
    build_conn()
    |> request(ctx, %{change_id: "C1", revision: revision})
    |> json_response(201)
  end

  defp with_key(raw_key) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> raw_key)
    |> put_req_header("content-type", "application/json")
  end

  defp review_complete(raw_key, story, revision_sha) do
    raw_key
    |> with_key()
    |> post("/api/v1/stories/#{story.id}/review-complete", %{
      "review_type" => "chg",
      "summary" => "chg review",
      "commit_sha" => revision_sha
    })
  end

  defp dispatch(id), do: AdminRepo.get!(Dispatch, id)

  describe "TC-50.3.1: mint and record" do
    test "201 with a key under the chg root, and the review records", ctx do
      minted = mint!(ctx)

      d = dispatch(minted["dispatch_id"])
      assert d.parent_dispatch_id == ctx.root.id
      assert d.lineage_path == [ctx.root.id, d.id]
      assert d.role == :orchestrator
      assert is_nil(d.revoked_at)

      assert %{"review_record" => %{"commit_sha" => recorded}} =
               minted["api_key"] |> review_complete(ctx.story, sha("a")) |> json_response(201)

      assert recorded == sha("a")
    end

    test "AC-50.3.5: an expired (unrevoked) root still mints, and the mint is audited", ctx do
      {1, _} =
        AdminRepo.update_all(from(d in Dispatch, where: d.id == ^ctx.root.id),
          set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
        )

      minted = mint!(ctx)

      entry =
        AdminRepo.one!(
          from e in Entry,
            where: e.tenant_id == ^ctx.tenant_id and e.action == "chg_review_dispatch_minted"
        )

      assert entry.payload["dispatch_id"] == minted["dispatch_id"]
      assert entry.payload["source_id"] == ctx.source.id
      assert entry.payload["change_id"] == "C1"
      assert entry.payload["revision"] == 1
    end

    test "the reviewer is the revision's system agent, never the implementer", ctx do
      minted = mint!(ctx)
      d = dispatch(minted["dispatch_id"])

      assert %{name: name} = AdminRepo.get!(Loopctl.Agents.Agent, d.agent_id)
      assert name == ReviewDispatches.agent_name(ctx.source.id, "C1", 1)
      refute d.agent_id == ctx.story.assigned_agent_id
    end

    test "a live key for one revision does not block the next revision's mint", ctx do
      first = mint!(ctx)
      assert first["api_key"] |> review_complete(ctx.story, sha("a")) |> json_response(201)
      assert is_nil(dispatch(first["dispatch_id"]).revoked_at)

      submit!(ctx, "C1", 2, 2, sha("b"))
      second = mint!(ctx, 2)

      assert is_nil(dispatch(first["dispatch_id"]).revoked_at)
      assert second["api_key"] |> review_complete(ctx.story, sha("b")) |> json_response(201)
    end
  end

  describe "a minted key reviews only its own revision" do
    test "a revision-1 key naming revision 2's sha is 409 chg_review_dispatch_mismatch", ctx do
      submit!(ctx, "C1", 2, 2, sha("b"))
      minted = mint!(ctx, 1)

      assert %{"error" => %{"code" => "chg_review_dispatch_mismatch"}} =
               minted["api_key"] |> review_complete(ctx.story, sha("b")) |> json_response(409)

      # Revision 2 has recorded no verdict, so its own key can still be minted and record.
      second = mint!(ctx, 2)
      assert second["api_key"] |> review_complete(ctx.story, sha("b")) |> json_response(201)
    end

    test "a revoked minted dispatch is refused inside the review's transaction", ctx do
      minted = mint!(ctx)

      {1, _} =
        AdminRepo.update_all(from(d in Dispatch, where: d.id == ^minted["dispatch_id"]),
          set: [revoked_at: DateTime.utc_now()]
        )

      assert {:error, :chg_review_dispatch_mismatch} =
               ReviewCustody.hold_minted_dispatch(
                 AdminRepo,
                 ctx.tenant_id,
                 [ctx.root.id, minted["dispatch_id"]],
                 sha("a")
               )

      assert {:ok, :not_minted} =
               ReviewCustody.hold_minted_dispatch(
                 AdminRepo,
                 ctx.tenant_id,
                 [ctx.root.id, Ecto.UUID.generate()],
                 sha("a")
               )
    end

    test "a key delegated under a minted key cannot review, even its revision's sha", ctx do
      minted = mint!(ctx)
      delegate = fixture(:agent, %{tenant_id: ctx.tenant_id, agent_type: :orchestrator})

      {:ok, %{dispatch: child, raw_key: child_key}} =
        Dispatches.create_dispatch(ctx.tenant_id, %{
          parent_dispatch_id: minted["dispatch_id"],
          role: :orchestrator,
          agent_id: delegate.id
        })

      assert child.lineage_path == [ctx.root.id, minted["dispatch_id"], child.id]

      assert %{"error" => %{"code" => "chg_review_dispatch_mismatch"}} =
               child_key |> review_complete(ctx.story, sha("a")) |> json_response(409)

      # The minted key itself still records its revision.
      assert minted["api_key"] |> review_complete(ctx.story, sha("a")) |> json_response(201)
    end
  end

  describe "retire_idle_reviewers/2" do
    test "deactivates a reviewer agent with no live dispatch; a re-mint re-activates it", ctx do
      first = mint!(ctx)
      agent_id = dispatch(first["dispatch_id"]).agent_id
      later = DateTime.add(DateTime.utc_now(), 5 * 3_600, :second)

      # Live now: nothing retired.
      assert ReviewDispatches.retire_idle_reviewers(DateTime.utc_now()) |> is_integer()
      assert %{status: :active} = AdminRepo.get!(Loopctl.Agents.Agent, agent_id)

      # Past the dispatch's expiry it is idle.
      assert ReviewDispatches.retire_idle_reviewers(later) >= 1
      assert %{status: :deactivated} = AdminRepo.get!(Loopctl.Agents.Agent, agent_id)

      mint!(ctx)
      assert %{status: :active} = AdminRepo.get!(Loopctl.Agents.Agent, agent_id)
    end
  end

  describe "TC-50.3.2: re-mint before and after a verdict" do
    test "the first is revoked, the second records, the third is 409", ctx do
      first = mint!(ctx)
      second = mint!(ctx)

      refute is_nil(dispatch(first["dispatch_id"]).revoked_at)
      assert is_nil(dispatch(second["dispatch_id"]).revoked_at)

      assert first["api_key"] |> review_complete(ctx.story, sha("a")) |> json_response(401)

      assert second["api_key"] |> review_complete(ctx.story, sha("a")) |> json_response(201)

      assert %{"error" => %{"code" => "review_already_recorded"}} =
               build_conn()
               |> request(ctx, %{change_id: "C1", revision: 1})
               |> json_response(409)

      assert is_nil(dispatch(second["dispatch_id"]).revoked_at)
    end
  end

  describe "TC-50.3.3: the key cannot verify or claim" do
    test "verify is chg_root_cannot_verify and claim is refused", ctx do
      minted = mint!(ctx)

      assert %{"error" => %{"code" => "chg_root_cannot_verify"}} =
               minted["api_key"]
               |> with_key()
               |> post("/api/v1/stories/#{ctx.story.id}/verify", %{"summary" => "ok"})
               |> json_response(409)

      conn =
        minted["api_key"] |> with_key() |> post("/api/v1/stories/#{ctx.story.id}/claim", %{})

      assert conn.status in [403, 409]
    end
  end

  describe "TC-50.3.4: refusals" do
    test "an unsubmitted revision is 422 revision_not_submitted", %{conn: conn} = ctx do
      assert %{"error" => %{"code" => "revision_not_submitted"}} =
               conn |> request(ctx, %{change_id: "C1", revision: 2}) |> json_response(422)

      assert %{"error" => %{"code" => "revision_not_submitted"}} =
               build_conn()
               |> request(ctx, %{change_id: "never-seen", revision: 1})
               |> json_response(422)
    end

    test "a revoked root and a bad signature are the change-events 401", %{conn: conn} = ctx do
      assert conn
             |> request(ctx, %{change_id: "C1", revision: 1},
               signature: "sha256=" <> String.duplicate("0", 64)
             )
             |> json_response(401) == @unauthorized

      {1, _} =
        AdminRepo.update_all(from(d in Dispatch, where: d.id == ^ctx.root.id),
          set: [revoked_at: DateTime.utc_now()]
        )

      assert build_conn()
             |> request(ctx, %{change_id: "C1", revision: 1})
             |> json_response(401) == @unauthorized
    end

    # Issue #1047: a revision submitted during a `pr` stint was applied unrouted, so once the
    # source is `chg` again it is still not a revision a reviewer can be minted for.
    test "a revision submitted while the source was pr is 422 revision_not_submitted",
         %{conn: conn} = ctx do
      {:ok, _} = Loopctl.Intake.update_source(ctx.tenant_id, ctx.source.id, %{mode: "pr"})
      submit!(ctx, "C1", 2, 2, sha("b"))
      {:ok, _} = Loopctl.Intake.update_source(ctx.tenant_id, ctx.source.id, %{mode: "chg"})

      assert %{"error" => %{"code" => "revision_not_submitted"}} =
               conn |> request(ctx, %{change_id: "C1", revision: 2}) |> json_response(422)
    end

    # Issue #1047: a `pr` source holding the chg credentials sends its ledger and events, but a
    # reviewer key is minted under a `chg` source's root only. The revision here was submitted
    # (and routed) while the source was `chg`, so nothing but the mode refuses the mint.
    test "a source switched to pr is the 401 and mints nothing", %{conn: conn} = ctx do
      {:ok, %{mode: :pr}} =
        Loopctl.Intake.update_source(ctx.tenant_id, ctx.source.id, %{mode: "pr"})

      before =
        AdminRepo.aggregate(from(d in Dispatch, where: d.tenant_id == ^ctx.tenant_id), :count)

      assert conn
             |> request(ctx, %{change_id: "C1", revision: 1})
             |> json_response(401) == @unauthorized

      assert AdminRepo.aggregate(
               from(d in Dispatch, where: d.tenant_id == ^ctx.tenant_id),
               :count
             ) ==
               before
    end

    test "a malformed body is 400 invalid_request", %{conn: conn} = ctx do
      for body <- [
            %{change_id: "C1"},
            %{change_id: "C1", revision: 0},
            %{revision: 1},
            %{change_id: "C1", revision: 1, extra: true}
          ] do
        assert %{"error" => %{"code" => "invalid_request"}} =
                 conn |> request(ctx, body) |> json_response(400)
      end
    end

    test "a signed change-event push replayed here is 400, and mints nothing", ctx do
      # The same bytes a push signs: an envelope carries change_id and revision among others.
      envelope =
        build(:chg_event, %{
          change_id: "C1",
          event_seq: 1,
          kind: "submitted",
          revision: 1,
          sha: sha("a"),
          data: %{"story_id" => ctx.story.id}
        })

      assert %{"error" => %{"code" => "invalid_request"}} =
               build_conn() |> request(ctx, envelope) |> json_response(400)

      assert AdminRepo.all(from(d in Dispatch, where: d.parent_dispatch_id == ^ctx.root.id)) ==
               []
    end

    test "a custody-halted tenant mints nothing: 503 tenant_halted", %{conn: conn} = ctx do
      {1, _} =
        AdminRepo.update_all(from(t in Tenant, where: t.id == ^ctx.tenant_id),
          set: [custody_halted_at: DateTime.utc_now()]
        )

      assert %{"error" => %{"code" => "tenant_halted"}} =
               conn |> request(ctx, %{change_id: "C1", revision: 1}) |> json_response(503)

      assert AdminRepo.all(from(d in Dispatch, where: d.parent_dispatch_id == ^ctx.root.id)) ==
               []
    end
  end

  describe "tenant isolation" do
    test "another tenant's source cannot mint for this tenant's change", %{conn: conn} = ctx do
      other = fixture(:chg_source, %{})

      assert %{"error" => %{"code" => "revision_not_submitted"}} =
               conn
               |> request(ctx, %{change_id: "C1", revision: 1},
                 source_id: other.source.id,
                 secret: other.secret
               )
               |> json_response(422)

      assert build_conn()
             |> request(ctx, %{change_id: "C1", revision: 1}, source_id: other.source.id)
             |> json_response(401) == @unauthorized
    end
  end
end
