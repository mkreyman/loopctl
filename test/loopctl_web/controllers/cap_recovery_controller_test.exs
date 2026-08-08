defmodule LoopctlWeb.CapRecoveryControllerTest do
  @moduledoc """
  Chain-of-custody v2 (L1): capability recovery must only ever re-mint a
  `start_cap`, bound to the CALLER's server-resolved dispatch lineage — never a
  client-chosen cap type or lineage, and never the story's OLD implementer
  lineage (which a re-dispatched agent could not consume).

  Refs advisory GHSA-w3j2-2w3r-hjcf.
  """

  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Capabilities.CapabilityToken
  alias Loopctl.Dispatches.Dispatch

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp caps_for(story_id) do
    AdminRepo.all(from(c in CapabilityToken, where: c.story_id == ^story_id))
  end

  # capture_log/1 captures the GLOBAL, process-wide Logger — including lines from
  # OTHER async tests running concurrently. Keep only the captured line(s) carrying
  # this test's unique story.id so marker assertions can't be satisfied by a sibling.
  defp forgery_line(log, story_id) do
    log
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, story_id))
    |> Enum.join("\n")
  end

  defp audit_entries(story_id, action) do
    AdminRepo.all(
      from(a in AuditLog,
        where: a.entity_id == ^story_id and a.action == ^action
      )
    )
  end

  defp insert_dispatch(tenant_id, agent_id, story_id, lineage, extra) do
    attrs =
      Map.merge(
        %{
          role: :agent,
          agent_id: agent_id,
          story_id: story_id,
          lineage_path: lineage,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        },
        extra
      )

    %Dispatch{tenant_id: tenant_id}
    |> Dispatch.changeset(attrs)
    |> AdminRepo.insert!()
  end

  # Builds a tenant whose audit signing key is available, an agent + agent-role
  # API key, and a story assigned to that agent.
  #
  # Two DISTINCT lineages, which is the whole point of the recovery contract:
  #
  #   * `impl_lineage` — recorded on the story via `implementer_dispatch_id`. It
  #     is the dispatch that CLAIMED the story, and by the time recovery is
  #     needed that session is gone.
  #   * `caller_lineage` — the lineage of the dispatch that minted the API key
  #     making the request. This is the RE-DISPATCHED agent, and it is what a
  #     recovered cap must bind to, because `Capabilities.validate_cap/6` demands
  #     an exact match against the lineage the CALLER presents at `POST /start`.
  #
  # They are DIFFERENT dispatches under the SAME custody root, which is the usual
  # re-dispatch. `caller_root: :other` is the harder one: the whole tree died and
  # the agent returns under a NEW root, which recovery must still serve.
  #
  # `caller_dispatch: false` drops the caller's dispatch, leaving the key
  # unlineaged (a legacy env-var key).
  defp setup_ctx(opts \\ %{}) do
    tenant = fixture(:tenant)

    # Make the tenant's audit signing key available so mint/4 can succeed.
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    tenant =
      tenant
      |> Ecto.Changeset.change(audit_signing_public_key: pub)
      |> AdminRepo.update!()

    case Map.get(opts, :secrets, :ok) do
      :unavailable ->
        Mox.stub(Loopctl.MockSecrets, :get, fn _name -> {:error, :secret_store_unavailable} end)

      :absent ->
        Mox.stub(Loopctl.MockSecrets, :get, fn _name -> {:error, :not_found} end)

      :ok ->
        Mox.stub(Loopctl.MockSecrets, :get, fn _name -> {:ok, priv} end)
    end

    Loopctl.TenantKeys.init_cache()

    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id})

    role = Map.get(opts, :role, :agent)

    {raw_key, api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: role, agent_id: agent.id})

    story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
    root = Ecto.UUID.generate()
    impl_lineage = [root, Ecto.UUID.generate()]

    caller_root =
      case Map.get(opts, :caller_root, :same) do
        :same -> root
        :other -> Ecto.UUID.generate()
      end

    caller_lineage = [caller_root, Ecto.UUID.generate()]

    if Map.get(opts, :caller_dispatch, true) do
      insert_dispatch(tenant.id, agent.id, nil, caller_lineage, %{api_key_id: api_key.id})
    end

    {story, recorded_lineage} =
      if Map.get(opts, :with_dispatch, true) do
        dispatch =
          insert_dispatch(
            tenant.id,
            agent.id,
            story.id,
            impl_lineage,
            Map.get(opts, :dispatch_attrs, %{})
          )

        story =
          story
          |> Ecto.Changeset.change(
            assigned_agent_id: agent.id,
            implementer_dispatch_id: dispatch.id
          )
          |> AdminRepo.update!()

        {story, impl_lineage}
      else
        story =
          story
          |> Ecto.Changeset.change(assigned_agent_id: agent.id)
          |> AdminRepo.update!()

        {story, nil}
      end

    %{
      tenant: tenant,
      agent: agent,
      raw_key: raw_key,
      story: story,
      impl_lineage: recorded_lineage,
      caller_lineage: caller_lineage
    }
  end

  describe "POST /api/v1/stories/:id/recover-cap — cap_type restriction" do
    for forged <- ["verify_cap", "report_cap", "review_complete_cap"] do
      test "rejects client-supplied cap_type #{forged} with 422 and mints nothing", %{conn: conn} do
        %{raw_key: raw_key, story: story} = setup_ctx()

        conn =
          conn
          |> auth_conn(raw_key)
          |> post("/api/v1/stories/#{story.id}/recover-cap", %{"cap_type" => unquote(forged)})

        assert %{"error" => %{"status" => 422, "message" => message}} = json_response(conn, 422)
        assert message =~ "start_cap"
        assert caps_for(story.id) == []
      end
    end
  end

  describe "POST /api/v1/stories/:id/recover-cap — start_cap recovery" do
    test "with no cap_type mints a start_cap bound to the CALLER's lineage", %{conn: conn} do
      %{raw_key: raw_key, story: story, caller_lineage: caller_lineage, impl_lineage: impl} =
        setup_ctx()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{})

      assert %{"data" => data} = json_response(conn, 201)
      assert data["typ"] == "start_cap"
      assert data["story_id"] == story.id
      # THE regression this endpoint exists to avoid: a cap bound to the story's
      # OLD implementer lineage is unconsumable by the re-dispatched agent, whose
      # lineage is by definition different. `validate_cap/6` matches exactly.
      assert data["issued_to_lineage"] == caller_lineage
      refute data["issued_to_lineage"] == impl
    end

    test "with explicit cap_type start_cap mints a start_cap", %{conn: conn} do
      %{raw_key: raw_key, story: story, caller_lineage: caller_lineage} = setup_ctx()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{"cap_type" => "start_cap"})

      assert %{"data" => data} = json_response(conn, 201)
      assert data["typ"] == "start_cap"
      assert data["issued_to_lineage"] == caller_lineage
    end

    test "ignores a client-supplied lineage and uses the caller's resolved lineage", %{conn: conn} do
      %{raw_key: raw_key, story: story, caller_lineage: caller_lineage} = setup_ctx()
      attacker_lineage = [Ecto.UUID.generate(), Ecto.UUID.generate()]

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{"lineage" => attacker_lineage})

      assert %{"data" => data} = json_response(conn, 201)
      assert data["typ"] == "start_cap"
      assert data["issued_to_lineage"] == caller_lineage
      refute data["issued_to_lineage"] == attacker_lineage
    end

    test "the recovered cap actually verifies for the caller at consume time", %{conn: conn} do
      # The end-to-end property the old binding broke: what recovery hands back
      # must be spendable by the principal that asked for it.
      %{raw_key: raw_key, story: story, tenant: tenant, caller_lineage: caller_lineage} =
        setup_ctx()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{})

      assert %{"data" => %{"cap_id" => cap_id}} = json_response(conn, 201)

      assert {:ok, _cap} =
               Loopctl.Capabilities.verify(tenant.id, %{
                 "cap_id" => cap_id,
                 "typ" => "start_cap",
                 "story_id" => story.id,
                 "lineage" => caller_lineage
               })
    end

    test "recovery never re-anchors the story's implementer_dispatch_id", %{conn: conn} do
      # The custody provenance report/review-complete/verify compare against must
      # not be rewritable by the agent whose separation they measure.
      %{raw_key: raw_key, story: story} = setup_ctx()
      before = AdminRepo.get!(Loopctl.WorkBreakdown.Story, story.id).implementer_dispatch_id

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{})

      assert %{"data" => _} = json_response(conn, 201)

      assert AdminRepo.get!(Loopctl.WorkBreakdown.Story, story.id).implementer_dispatch_id ==
               before
    end
  end

  describe "POST /api/v1/stories/:id/recover-cap — guards" do
    test "rejects a caller with no recorded dispatch lineage for the story", %{conn: conn} do
      %{raw_key: raw_key, story: story} = setup_ctx(%{with_dispatch: false})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{})

      assert %{"error" => %{"status" => 422}} = json_response(conn, 422)
      assert caps_for(story.id) == []
    end

    test "an agent key with NO agent_id gets the documented 404, not a 500", %{conn: conn} do
      # A legacy env-var agent key owns nothing. The ownership query interpolated
      # that nil into `s.assigned_agent_id == ^agent_id`, which Ecto REFUSES with
      # an ArgumentError, so the refusal surfaced as a 500.
      %{tenant: tenant, story: story} = setup_ctx()

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: nil})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{})

      assert %{"error" => %{"status" => 404}} = json_response(conn, 404)
      assert caps_for(story.id) == []
    end

    test "returns 404 for a same-tenant story assigned to another agent", %{conn: conn} do
      %{raw_key: raw_key, tenant: tenant} = setup_ctx()

      other_agent = fixture(:agent, %{tenant_id: tenant.id})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      other_story =
        fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
        |> Ecto.Changeset.change(assigned_agent_id: other_agent.id)
        |> AdminRepo.update!()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{other_story.id}/recover-cap", %{})

      assert %{"error" => %{"status" => 404}} = json_response(conn, 404)
      assert caps_for(other_story.id) == []
    end

    test "tenant isolation: cannot recover a cap for another tenant's story", %{conn: conn} do
      %{raw_key: raw_key} = setup_ctx()
      # A completely separate tenant with its own agent-owned story.
      %{story: foreign_story} = setup_ctx()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{foreign_story.id}/recover-cap", %{})

      assert %{"error" => %{"status" => 404}} = json_response(conn, 404)
      assert caps_for(foreign_story.id) == []
    end
  end

  describe "POST /api/v1/stories/:id/recover-cap — exact_role gate" do
    test "rejects an orchestrator key linked to the same agent_id with 403", %{conn: conn} do
      # An orchestrator identity can be linked to the same agent_id as an
      # implementer. The exact_role: :agent gate (matching claim/start) must
      # not let it walk this custody endpoint via role hierarchy.
      %{raw_key: orch_key, story: story} = setup_ctx(%{role: :orchestrator})

      conn =
        conn
        |> auth_conn(orch_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{})

      assert %{"error" => %{"status" => 403}} = json_response(conn, 403)
      assert caps_for(story.id) == []
    end
  end

  describe "POST /api/v1/stories/:id/recover-cap — forgery-attempt observability" do
    test "logs a warning and writes an audit entry on a forged cap_type", %{conn: conn} do
      %{raw_key: raw_key, story: story, agent: agent} = setup_ctx()

      log =
        capture_log(fn ->
          conn =
            conn
            |> auth_conn(raw_key)
            |> post("/api/v1/stories/#{story.id}/recover-cap", %{"cap_type" => "verify_cap"})

          assert %{"error" => %{"status" => 422}} = json_response(conn, 422)
        end)

      # Scope marker assertions to THIS story's log line: capture_log sees the
      # global process-wide Logger, so bare "cap_recovery_forgery_attempt" /
      # "rejected_cap_type=..." substrings could match a SIBLING async test's
      # warning captured concurrently. `forgery_line/2` keeps only the line
      # carrying this story.id (the message emits both on one line).
      forgery_line = forgery_line(log, story.id)
      assert forgery_line =~ "cap_recovery_forgery_attempt"
      assert forgery_line =~ "rejected_cap_type=\"verify_cap\""
      assert log =~ story.id

      # Surfaces in GET /stories/:id/history (Audit.entity_history reads this table)
      assert [entry] = audit_entries(story.id, "cap_recovery_forgery_attempt")
      assert entry.entity_type == "story"
      assert entry.metadata["rejected_cap_type"] == "verify_cap"
      assert entry.metadata["caller_agent_id"] == agent.id
      assert caps_for(story.id) == []
    end
  end

  describe "POST /api/v1/stories/:id/recover-cap — implementer dispatch state" do
    test "rejects recovery when the implementer dispatch is revoked", %{conn: conn} do
      %{raw_key: raw_key, story: story} =
        setup_ctx(%{dispatch_attrs: %{revoked_at: DateTime.utc_now()}})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{})

      assert %{"error" => %{"status" => 422, "code" => code, "message" => message}} =
               json_response(conn, 422)

      assert code == "dispatch_revoked"
      assert message =~ "REVOKED"
      assert caps_for(story.id) == []
    end

    test "ALLOWS recovery when the implementer dispatch has merely expired", %{conn: conn} do
      # Dispatch TTLs are bounded, so an agent that lost its session has almost
      # always outlived its original dispatch. Refusing here closed the recovery
      # path in the exact situation it exists for.
      %{raw_key: raw_key, story: story, caller_lineage: caller_lineage} =
        setup_ctx(%{
          dispatch_attrs: %{expires_at: DateTime.add(DateTime.utc_now(), -60, :second)}
        })

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{})

      assert %{"data" => data} = json_response(conn, 201)
      assert data["issued_to_lineage"] == caller_lineage
    end

    test "mints as usual when the implementer dispatch is active", %{conn: conn} do
      %{raw_key: raw_key, story: story, caller_lineage: caller_lineage} = setup_ctx()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{})

      assert %{"data" => data} = json_response(conn, 201)
      assert data["typ"] == "start_cap"
      assert data["issued_to_lineage"] == caller_lineage
    end
  end

  describe "POST /api/v1/stories/:id/recover-cap — mint failure" do
    test "answers a stable code and never inspects the internal term into the body",
         %{conn: conn} do
      # Every guard passes; the MINT itself fails because the tenant's private key
      # cannot be read. The body used to be "Cannot mint cap: #{inspect(reason)}",
      # which handed an agent-role caller internal error structure and gave it no
      # stable string to branch on.
      #
      # It answers through FallbackController, exactly as `POST /claim` answers
      # this IDENTICAL condition: a 422 here (where claim says 503) told a client
      # branching on status class that a transient secret-store fault was
      # permanent, and gave the same condition two different codes.
      %{raw_key: raw_key, story: story} = setup_ctx(%{secrets: :unavailable})

      body =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{})
        |> json_response(503)

      assert body["error"]["code"] == "capability_mint_failed"
      refute body["error"]["message"] =~ "key_unavailable"
      refute body["error"]["message"] =~ "secret_store_unavailable"
      assert caps_for(story.id) == []
    end

    test "a key that is ABSENT, not merely unreachable, is answered as non-retryable",
         %{conn: conn} do
      # `:not_found` is an operator condition: retrying cannot clear it, and
      # `retry-after` on it is what turned agents into hot-loops against a state
      # only a human can fix.
      %{raw_key: raw_key, story: story} = setup_ctx(%{secrets: :absent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{})

      assert %{"error" => %{"code" => "capability_key_unavailable"}} = json_response(conn, 503)
      assert get_resp_header(conn, "retry-after") == []
      assert caps_for(story.id) == []
    end
  end

  describe "POST /api/v1/stories/:id/recover-cap — custody tree" do
    test "recovers for a caller re-dispatched under a NEW root", %{conn: conn} do
      # The crash this endpoint exists for can take the whole tree with it: the
      # orchestration session dies and the agent returns under a new ROOT dispatch.
      # Demanding a shared root refused exactly that, leaving force_unclaim (an
      # operator) as the only way out. Separation is still held by the caller being
      # the story's assigned agent, and by the `assigned_agent_id` equality every
      # L4 gate runs alongside its lineage comparison.
      %{raw_key: raw_key, story: story, caller_lineage: caller_lineage} =
        setup_ctx(%{caller_root: :other})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{})

      assert %{"data" => %{"issued_to_lineage" => ^caller_lineage, "typ" => "start_cap"}} =
               json_response(conn, 201)
    end
  end

  describe "POST /api/v1/stories/:id/recover-cap — unlineaged caller" do
    test "refuses a caller whose key no dispatch minted, on dispatch-minted work", %{conn: conn} do
      # An `[]`-lineage cap would let an unlineaged legacy key start work that was
      # claimed under a dispatch — the separation the caller cannot demonstrate.
      %{raw_key: raw_key, story: story} = setup_ctx(%{caller_dispatch: false})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{})

      assert %{"error" => %{"status" => 409, "code" => "caller_lineage_required"}} =
               json_response(conn, 409)

      assert caps_for(story.id) == []
    end
  end
end
