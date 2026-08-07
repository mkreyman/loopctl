defmodule LoopctlWeb.StoryLifecycleCapabilityTest do
  @moduledoc """
  Issue #621 — the story lifecycle must be completable over HTTP by a KEYED
  tenant (one with an `audit_signing_public_key`, which is every tenant created
  through the current signup flow).

  The pre-existing suite exercised only the KEYLESS path, where
  `Progress.maybe_consume_cap/6` lets a nil capability through — so CI stayed
  green while every keyed tenant got `403 missing_capability` on start/report/
  verify. These tests drive the real HTTP surface with a keyed tenant, which is
  the shape that was broken in production.
  """

  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Dispatches.Dispatch

  setup :verify_on_exit!

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp insert_dispatch(tenant_id, agent_id, api_key_id, lineage, role) do
    %Dispatch{tenant_id: tenant_id}
    |> Dispatch.changeset(%{
      role: role,
      agent_id: agent_id,
      api_key_id: api_key_id,
      lineage_path: lineage,
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    })
    |> AdminRepo.insert!()
  end

  # An actor = agent + api key + a dispatch that MINTED that key, which is what
  # makes `Dispatches.dispatch_for_api_key/2` resolve a real lineage server-side.
  # Each actor gets its own lineage ROOT so the custody gates see them as
  # structurally separate principals (Dispatches.lineage_shares_prefix?/2
  # compares roots).
  defp actor(tenant, role) do
    agent = fixture(:agent, %{tenant_id: tenant.id})

    {raw_key, api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: role, agent_id: agent.id})

    lineage = [Ecto.UUID.generate(), Ecto.UUID.generate()]
    dispatch = insert_dispatch(tenant.id, agent.id, api_key.id, lineage, role)

    %{agent: agent, raw_key: raw_key, api_key: api_key, lineage: lineage, dispatch: dispatch}
  end

  defp keyed_context do
    tenant = fixture(:tenant)

    # A KEYED tenant: audit signing keypair present and resolvable, so
    # Capabilities.mint/4 succeeds and maybe_consume_cap/6 ENFORCES.
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    tenant =
      tenant
      |> Ecto.Changeset.change(audit_signing_public_key: pub)
      |> AdminRepo.update!()

    Mox.stub(Loopctl.MockSecrets, :get, fn _name -> {:ok, priv} end)
    Loopctl.TenantKeys.init_cache()

    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

    story =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        project_id: project.id,
        agent_status: :contracted
      })

    %{
      tenant: tenant,
      story: story,
      implementer: actor(tenant, :agent),
      reporter: actor(tenant, :agent),
      orchestrator: actor(tenant, :orchestrator)
    }
  end

  describe "keyed tenant: claim delivers the start_cap (#621)" do
    test "claim response carries a start_cap bound to the caller's lineage", %{conn: conn} do
      %{story: story, implementer: impl} = keyed_context()

      body =
        conn
        |> auth(impl.raw_key)
        |> post("/api/v1/stories/#{story.id}/claim")
        |> json_response(200)

      assert %{"capability" => cap} = body,
             "claim must return the minted start_cap — without it a keyed tenant " <>
               "cannot call start (#621)"

      assert cap["typ"] == "start_cap"
      assert cap["story_id"] == story.id
      assert cap["issued_to_lineage"] == impl.lineage
      assert is_binary(cap["cap_id"])
    end

    test "claim records the implementer's dispatch, so the custody gates have provenance",
         %{conn: conn} do
      %{story: story, implementer: impl} = keyed_context()

      conn
      |> auth(impl.raw_key)
      |> post("/api/v1/stories/#{story.id}/claim")
      |> json_response(200)

      reloaded = AdminRepo.get!(Loopctl.WorkBreakdown.Story, story.id)

      assert reloaded.implementer_dispatch_id == impl.dispatch.id,
             "claim over HTTP must record implementer_dispatch_id — every lineage gate " <>
               "downstream degrades to plain agent-id equality without it"
    end
  end

  describe "keyed tenant: start consumes the start_cap (#621)" do
    test "start succeeds when the start_cap from claim is presented", %{conn: conn} do
      %{story: story, implementer: impl} = keyed_context()

      %{"capability" => start_cap} =
        conn
        |> auth(impl.raw_key)
        |> post("/api/v1/stories/#{story.id}/claim")
        |> json_response(200)

      body =
        conn
        |> auth(impl.raw_key)
        |> post("/api/v1/stories/#{story.id}/start", %{"capability" => start_cap["cap_id"]})
        |> json_response(200)

      assert body["story"]["agent_status"] == "implementing"

      # start deliberately mints nothing: the next transition (report) is gated by
      # lineage separation, not a capability, because no capability can be bound to
      # a reporter who is by definition not the principal starting the work.
      refute Map.has_key?(body, "capability")
    end

    test "the start_cap is single-use", %{conn: conn} do
      %{story: story, implementer: impl} = keyed_context()

      %{"capability" => start_cap} =
        conn
        |> auth(impl.raw_key)
        |> post("/api/v1/stories/#{story.id}/claim")
        |> json_response(200)

      conn
      |> auth(impl.raw_key)
      |> post("/api/v1/stories/#{story.id}/start", %{"capability" => start_cap["cap_id"]})
      |> json_response(200)

      # The token is burned atomically with the transition.
      cap = AdminRepo.get!(Loopctl.Capabilities.CapabilityToken, start_cap["cap_id"])
      refute is_nil(cap.consumed_at), "start must consume the start_cap it was given"

      # A retry is refused by the STATE MACHINE (409) before the capability layer
      # sees the replayed token.
      conn
      |> auth(impl.raw_key)
      |> post("/api/v1/stories/#{story.id}/start", %{"capability" => start_cap["cap_id"]})
      |> response(409)
    end

    test "an EXPIRED start_cap is a 403, not a tenant-wide custody halt", %{conn: conn} do
      %{tenant: tenant, story: story, implementer: impl} = keyed_context()

      %{"capability" => start_cap} =
        conn
        |> auth(impl.raw_key)
        |> post("/api/v1/stories/#{story.id}/claim")
        |> json_response(200)

      # The cap TTL is an hour; a review/planning pause longer than that is
      # ordinary, not byzantine.
      Loopctl.Capabilities.CapabilityToken
      |> AdminRepo.get!(start_cap["cap_id"])
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
      |> AdminRepo.update!()

      conn
      |> auth(impl.raw_key)
      |> post("/api/v1/stories/#{story.id}/start", %{"capability" => start_cap["cap_id"]})
      |> response(403)

      # THE point of the test: a client-side timeout must not custody-halt the
      # tenant, which would 503 every other agent working in it.
      assert is_nil(AdminRepo.get!(Loopctl.Tenants.Tenant, tenant.id).custody_halted_at),
             "an expired capability is a client error — it must never halt the tenant"
    end

    test "a malformed capability is refused, not a 500", %{conn: conn} do
      %{story: story, implementer: impl} = keyed_context()

      conn
      |> auth(impl.raw_key)
      |> post("/api/v1/stories/#{story.id}/claim")
      |> json_response(200)

      # Straight off the request body into an Ecto UUID column: this used to raise
      # Ecto.Query.CastError and surface as a crash.
      conn
      |> auth(impl.raw_key)
      |> post("/api/v1/stories/#{story.id}/start", %{"capability" => "not-a-uuid"})
      |> response(403)
    end

    test "start without a capability is refused for a keyed tenant", %{conn: conn} do
      %{story: story, implementer: impl} = keyed_context()

      conn
      |> auth(impl.raw_key)
      |> post("/api/v1/stories/#{story.id}/claim")
      |> json_response(200)

      # This is the exact production failure of #621 — it must remain a refusal
      # (the capability layer is doing its job), and be reachable ONLY by
      # omitting the token, not by presenting a correct one.
      resp =
        conn
        |> auth(impl.raw_key)
        |> post("/api/v1/stories/#{story.id}/start")
        |> json_response(403)

      assert resp["error"]["message"] =~ "capability" or
               resp["error"]["code"] == "missing_capability"
    end

    test "a start_cap issued to another lineage is refused", %{conn: conn} do
      %{story: story, implementer: impl, reporter: other} = keyed_context()

      %{"capability" => start_cap} =
        conn
        |> auth(impl.raw_key)
        |> post("/api/v1/stories/#{story.id}/claim")
        |> json_response(200)

      # `other` is not the assigned agent, and the cap is bound to impl's
      # lineage: presenting a stolen cap_id must not authorize anything.
      conn
      |> auth(other.raw_key)
      |> post("/api/v1/stories/#{story.id}/start", %{"capability" => start_cap["cap_id"]})
      |> response(403)
    end
  end

  describe "GET /stories/:id/capabilities — delivery of already-issued caps (#621)" do
    test "returns the caller's own live capabilities for the story", %{conn: conn} do
      %{story: story, implementer: impl} = keyed_context()

      conn
      |> auth(impl.raw_key)
      |> post("/api/v1/stories/#{story.id}/claim")
      |> json_response(200)

      %{"data" => caps} =
        conn
        |> auth(impl.raw_key)
        |> get("/api/v1/stories/#{story.id}/capabilities")
        |> json_response(200)

      assert [%{"typ" => "start_cap"}] = caps
      assert Enum.all?(caps, &(&1["issued_to_lineage"] == impl.lineage))
    end

    test "never returns capabilities issued to a DIFFERENT lineage", %{conn: conn} do
      %{story: story, implementer: impl, reporter: other} = keyed_context()

      conn
      |> auth(impl.raw_key)
      |> post("/api/v1/stories/#{story.id}/claim")
      |> json_response(200)

      %{"data" => caps} =
        conn
        |> auth(other.raw_key)
        |> get("/api/v1/stories/#{story.id}/capabilities")
        |> json_response(200)

      assert caps == [],
             "a caller must never be handed a capability minted for someone else's lineage"
    end
  end

  describe "keyed tenant: report (chain-of-custody, #621)" do
    # Drives the story to :implementing by the implementer, then returns the ctx.
    defp implemented(conn, ctx) do
      %{"capability" => start_cap} =
        conn
        |> auth(ctx.implementer.raw_key)
        |> post("/api/v1/stories/#{ctx.story.id}/claim")
        |> json_response(200)

      conn
      |> auth(ctx.implementer.raw_key)
      |> post("/api/v1/stories/#{ctx.story.id}/start", %{"capability" => start_cap["cap_id"]})
      |> json_response(200)

      ctx
    end

    test "a DIFFERENT agent completes the report transition with no capability",
         %{conn: conn} do
      ctx = implemented(conn, keyed_context())

      # The reporter is a structurally separate principal (different lineage root
      # AND different agent_id) — which is exactly what the custody gate requires,
      # and exactly why no capability could have been minted for it in advance.
      body =
        conn
        |> auth(ctx.reporter.raw_key)
        |> post("/api/v1/stories/#{ctx.story.id}/report", %{
          "summary" => "independent review complete"
        })
        |> json_response(200)

      assert body["story"]["agent_status"] == "reported_done"
    end

    test "the IMPLEMENTER still cannot report its own work", %{conn: conn} do
      ctx = implemented(conn, keyed_context())

      # The custody gate is the whole enforcement for this transition now that no
      # capability gates it. If this ever returns 200, dropping report_cap
      # regressed the product's core guarantee.
      body =
        conn
        |> auth(ctx.implementer.raw_key)
        |> post("/api/v1/stories/#{ctx.story.id}/report", %{"summary" => "I finished it"})
        |> json_response(409)

      assert body["error"]["code"] == "self_report_blocked"
    end
  end

  describe "keyed tenant: verify closes the lifecycle (#621)" do
    # claim -> start -> report -> review-complete, leaving the story verifiable.
    defp reviewed(conn, ctx) do
      ctx = implemented(conn, ctx)

      conn
      |> auth(ctx.reporter.raw_key)
      |> post("/api/v1/stories/#{ctx.story.id}/report", %{"summary" => "review complete"})
      |> json_response(200)

      conn
      |> auth(ctx.orchestrator.raw_key)
      |> post("/api/v1/stories/#{ctx.story.id}/review-complete", %{
        "review_type" => "enhanced",
        "summary" => "reviewed"
      })
      |> json_response(201)

      ctx
    end

    test "an orchestrator verifies with no capability at all", %{conn: conn} do
      ctx = reviewed(conn, keyed_context())

      # The leg the suite never exercised. A verify_cap could not have reached
      # this caller — it was minted to whichever dispatch loopctl selected, which
      # may not even be orchestrator-role — so requiring one wedged every keyed
      # tenant's story at the last step.
      conn
      |> auth(ctx.orchestrator.raw_key)
      |> post("/api/v1/stories/#{ctx.story.id}/verify", %{
        "review_type" => "enhanced",
        "summary" => "verified independently"
      })
      |> json_response(202)

      story = AdminRepo.get!(Loopctl.WorkBreakdown.Story, ctx.story.id)
      assert story.verified_status == :verified
    end

    test "the IMPLEMENTER still cannot verify its own work", %{conn: conn} do
      ctx = reviewed(conn, keyed_context())

      # L4 is the whole enforcement now that no capability gates verify. If this
      # ever passes, dropping verify_cap regressed the core guarantee.
      %{agent: impl_agent} = ctx.implementer

      {impl_orch_key, api_key} =
        fixture(:api_key, %{
          tenant_id: ctx.tenant.id,
          role: :orchestrator,
          agent_id: impl_agent.id
        })

      insert_dispatch(
        ctx.tenant.id,
        impl_agent.id,
        api_key.id,
        ctx.implementer.lineage,
        :orchestrator
      )

      body =
        conn
        |> auth(impl_orch_key)
        |> post("/api/v1/stories/#{ctx.story.id}/verify", %{
          "review_type" => "enhanced",
          "summary" => "looks good to me"
        })
        |> json_response(409)

      assert body["error"]["code"] == "self_verify_blocked" or
               body["error"]["message"] =~ "own"
    end
  end
end
