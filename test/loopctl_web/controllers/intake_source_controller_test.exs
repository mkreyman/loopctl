defmodule LoopctlWeb.IntakeSourceControllerTest do
  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain.Entry
  alias Loopctl.Intake
  alias Loopctl.Intake.Signature
  alias Loopctl.Intake.Source

  setup :verify_on_exit!

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp operator_ctx do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    {operator_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
    project = fixture(:project, %{tenant_id: tenant.id})
    %{tenant: tenant, operator_key: operator_key, project: project}
  end

  defp create_params(ctx, repo \\ "mkreyman/home_care_billing"),
    do: %{"repo_full_name" => repo, "project_id" => ctx.project.id}

  describe "POST /api/v1/intake/sources" do
    test "creates a source and returns its secret once", %{conn: conn} do
      ctx = operator_ctx()

      body =
        conn
        |> auth(ctx.operator_key)
        |> post(~p"/api/v1/intake/sources", create_params(ctx))
        |> json_response(201)

      assert body["source"]["repo_full_name"] == "mkreyman/home_care_billing"
      assert body["source"]["project_id"] == ctx.project.id
      assert body["webhook_path"] == "/api/v1/intake/github/#{body["source"]["id"]}"
      assert body["webhook_secret"] =~ ~r/\A[0-9a-f]{64}\z/
      refute Map.has_key?(body["source"], "webhook_secret")

      # The returned secret is the one deliveries are verified with.
      {:ok, source} = Intake.get_source(ctx.tenant.id, body["source"]["id"])

      assert Signature.valid?(
               source.webhook_secret,
               "x",
               Signature.header(body["webhook_secret"], "x")
             )

      assert [%Entry{action: "intake_source_created"}] =
               AdminRepo.all(
                 from e in Entry,
                   where: e.tenant_id == ^ctx.tenant.id and e.entity_id == ^source.id
               )
    end

    test "target_epic_id is persisted and comes back in the response", %{conn: conn} do
      ctx = operator_ctx()
      epic = fixture(:epic, %{tenant_id: ctx.tenant.id, project_id: ctx.project.id})

      body =
        conn
        |> auth(ctx.operator_key)
        |> post(
          ~p"/api/v1/intake/sources",
          Map.put(create_params(ctx), "target_epic_id", epic.id)
        )
        |> json_response(201)

      # BOTH halves, because both were missing. The controller dropped the parameter, so the
      # column could only ever be set by direct SQL and every promote of a record from a
      # source enrolled through this endpoint escalated for want of a target epic — the
      # feature had no code path at all. The response field was absent too, so an operator
      # could not tell a source that names an epic from one that does not.
      assert body["source"]["target_epic_id"] == epic.id

      {:ok, source} = Intake.get_source(ctx.tenant.id, body["source"]["id"])
      assert source.target_epic_id == epic.id
    end

    test "a source enrolled without a target epic reports it as null", %{conn: conn} do
      ctx = operator_ctx()

      body =
        conn
        |> auth(ctx.operator_key)
        |> post(~p"/api/v1/intake/sources", create_params(ctx))
        |> json_response(201)

      # The key is PRESENT and null rather than absent: "the question has not been answered"
      # is a state an operator reads off this endpoint, and a missing key reads as a client
      # that is out of date instead.
      assert Map.has_key?(body["source"], "target_epic_id")
      assert body["source"]["target_epic_id"] == nil
    end

    test "422 naming target_epic_id for an epic outside the source's project", %{conn: conn} do
      ctx = operator_ctx()
      other_project = fixture(:project, %{tenant_id: ctx.tenant.id})
      epic = fixture(:epic, %{tenant_id: ctx.tenant.id, project_id: other_project.id})

      body =
        conn
        |> auth(ctx.operator_key)
        |> post(
          ~p"/api/v1/intake/sources",
          Map.put(create_params(ctx), "target_epic_id", epic.id)
        )
        |> json_response(422)

      # A 422 rather than an `Ecto.ConstraintError` 500, and the field is named: the mistake
      # is one an operator makes at enrollment and can fix there, not on the first webhook.
      assert body["error"]["details"]["target_epic_id"]
      assert Intake.list_sources(ctx.tenant.id) == []
    end

    test "the secret is encrypted at rest", %{conn: conn} do
      ctx = operator_ctx()

      %{"source" => %{"id" => id}, "webhook_secret" => secret} =
        conn
        |> auth(ctx.operator_key)
        |> post(~p"/api/v1/intake/sources", create_params(ctx))
        |> json_response(201)

      {:ok, uuid} = Ecto.UUID.dump(id)

      %{rows: [[stored]]} =
        AdminRepo.query!("SELECT webhook_secret FROM intake_sources WHERE id = $1", [uuid])

      refute stored =~ secret
    end

    test "the secret never appears in a listing", %{conn: conn} do
      ctx = operator_ctx()
      authed = auth(conn, ctx.operator_key)
      assert json_response(post(authed, ~p"/api/v1/intake/sources", create_params(ctx)), 201)

      [listed] = json_response(get(authed, ~p"/api/v1/intake/sources"), 200)["sources"]
      refute Map.has_key?(listed, "webhook_secret")
    end

    test "422 on a malformed repository, a duplicate, or an unusable project", %{conn: conn} do
      ctx = operator_ctx()
      authed = auth(conn, ctx.operator_key)
      kb = fixture(:project, %{tenant_id: ctx.tenant.id, kind: :kb})
      other_tenant_project = fixture(:project, %{})

      assert json_response(
               post(authed, ~p"/api/v1/intake/sources", create_params(ctx, "no-slash")),
               422
             )

      assert json_response(post(authed, ~p"/api/v1/intake/sources", create_params(ctx)), 201)

      assert json_response(
               post(
                 authed,
                 ~p"/api/v1/intake/sources",
                 create_params(ctx, "MKREYMAN/home_care_billing")
               ),
               422
             )

      for project_id <- [kb.id, other_tenant_project.id, Ecto.UUID.generate(), nil] do
        params = %{"repo_full_name" => "mkreyman/other", "project_id" => project_id}
        assert json_response(post(authed, ~p"/api/v1/intake/sources", params), 422)
      end
    end

    test "403 for orchestrator and agent keys", %{conn: conn} do
      ctx = operator_ctx()

      for role <- [:orchestrator, :agent] do
        {raw, _} = fixture(:api_key, %{tenant_id: ctx.tenant.id, role: role})

        assert conn
               |> auth(raw)
               |> post(~p"/api/v1/intake/sources", create_params(ctx))
               |> json_response(403)
      end

      assert Intake.list_sources(ctx.tenant.id) == []
    end

    test "403 custody_tier_required for an agent-rooted tenant, on create and revoke",
         %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      {_secret, source} = fixture(:intake_source, %{tenant_id: tenant.id, project_id: project.id})
      authed = auth(conn, raw)

      params = %{"repo_full_name" => "mkreyman/other", "project_id" => project.id}

      for resp <- [
            post(authed, ~p"/api/v1/intake/sources", params),
            delete(authed, ~p"/api/v1/intake/sources/#{source.id}")
          ] do
        assert json_response(resp, 403)["error"]["code"] == "custody_tier_required"
      end

      assert [_still_active] = Intake.list_sources(tenant.id)
      assert json_response(get(authed, ~p"/api/v1/intake/sources"), 200)
    end

    test "403 api_key_mint_forbidden for a dispatch-minted key", %{conn: conn} do
      ctx = operator_ctx()
      agent = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :orchestrator})

      %{"api_key" => %{"raw_key" => dispatched_key}} =
        build_conn()
        |> auth(ctx.operator_key)
        |> post(~p"/api/v1/dispatches", %{"role" => "user", "agent_id" => agent.id})
        |> json_response(201)
        |> Map.fetch!("data")

      body =
        conn
        |> auth(dispatched_key)
        |> post(~p"/api/v1/intake/sources", create_params(ctx))
        |> json_response(403)

      assert body["error"]["code"] == "api_key_mint_forbidden"
      assert Intake.list_sources(ctx.tenant.id) == []
    end
  end

  describe "GET /api/v1/intake/sources" do
    test "lists active sources, and revoked ones on request", %{conn: conn} do
      ctx = operator_ctx()

      {_s, active} =
        fixture(:intake_source, %{tenant_id: ctx.tenant.id, project_id: ctx.project.id})

      {_s, gone} =
        fixture(:intake_source, %{
          tenant_id: ctx.tenant.id,
          project_id: ctx.project.id,
          repo_full_name: "mkreyman/gone"
        })

      {:ok, _} = Intake.revoke_source(ctx.tenant.id, gone.id)
      authed = auth(conn, ctx.operator_key)

      assert [%{"id" => id}] =
               json_response(get(authed, ~p"/api/v1/intake/sources"), 200)["sources"]

      assert id == active.id

      all = json_response(get(authed, ~p"/api/v1/intake/sources?include_revoked=true"), 200)
      assert length(all["sources"]) == 2
    end

    test "never lists another tenant's sources", %{conn: conn} do
      ctx = operator_ctx()
      {_s, _other} = fixture(:intake_source, %{})

      assert json_response(get(auth(conn, ctx.operator_key), ~p"/api/v1/intake/sources"), 200) ==
               %{"sources" => []}
    end
  end

  describe "PATCH /api/v1/intake/sources/:id" do
    test "repoints an active source and records it", %{conn: conn} do
      ctx = operator_ctx()

      {_s, source} =
        fixture(:intake_source, %{tenant_id: ctx.tenant.id, project_id: ctx.project.id})

      epic = fixture(:epic, %{tenant_id: ctx.tenant.id, project_id: ctx.project.id})

      body =
        conn
        |> auth(ctx.operator_key)
        |> patch(~p"/api/v1/intake/sources/#{source.id}", %{"target_epic_id" => epic.id})
        |> json_response(200)

      assert body["source"]["target_epic_id"] == epic.id
      refute Map.has_key?(body["source"], "webhook_secret")
      assert AdminRepo.get!(Source, source.id).target_epic_id == epic.id

      assert [_one] =
               AdminRepo.all(
                 from e in Entry,
                   where: e.tenant_id == ^ctx.tenant.id and e.action == "intake_source_repointed"
               )
    end

    test "sets the base branch, records it, and leaves the epic alone", %{conn: conn} do
      ctx = operator_ctx()
      epic = fixture(:epic, %{tenant_id: ctx.tenant.id, project_id: ctx.project.id})

      {_s, source} =
        fixture(:intake_source, %{
          tenant_id: ctx.tenant.id,
          project_id: ctx.project.id,
          target_epic_id: epic.id
        })

      # The column exists so a repository whose default branch is `main` can be dispatched
      # into at all (#803 round 1, finding 7) — hardcoded `master`, the loop placed work
      # against a branch that does not exist, and the failure arrives after the claim.
      body =
        conn
        |> auth(ctx.operator_key)
        |> patch(~p"/api/v1/intake/sources/#{source.id}", %{
          "base_branch" => "main",
          "target_epic_id" => epic.id
        })
        |> json_response(200)

      assert body["source"]["base_branch"] == "main"
      assert AdminRepo.get!(Source, source.id).base_branch == "main"

      assert [_one] =
               AdminRepo.all(
                 from e in Entry,
                   where:
                     e.tenant_id == ^ctx.tenant.id and
                       e.action == "intake_source_base_branch_set"
               )
    end

    test "a PATCH naming ONLY the base branch leaves the epic pointed", %{conn: conn} do
      ctx = operator_ctx()
      epic = fixture(:epic, %{tenant_id: ctx.tenant.id, project_id: ctx.project.id})

      {_s, source} =
        fixture(:intake_source, %{
          tenant_id: ctx.tenant.id,
          project_id: ctx.project.id,
          target_epic_id: epic.id
        })

      # THE TRAP THIS ACTION USED TO CARRY: absent meant "clear" for the epic, and the
      # `required` marker in the request schema is documentation rather than enforcement —
      # this router mounts no `CastAndValidate`. So following the deploy note and setting the
      # base branch before enabling the driver un-pointed the source from its epic, which by
      # this action's own description strands every record from it at `pending_triage`.
      body =
        conn
        |> auth(ctx.operator_key)
        |> patch(~p"/api/v1/intake/sources/#{source.id}", %{"base_branch" => "main"})
        |> json_response(200)

      assert body["source"]["base_branch"] == "main"
      assert body["source"]["target_epic_id"] == epic.id
      assert AdminRepo.get!(Source, source.id).target_epic_id == epic.id
    end

    test "a body naming neither field is refused rather than clearing anything", %{conn: conn} do
      ctx = operator_ctx()
      epic = fixture(:epic, %{tenant_id: ctx.tenant.id, project_id: ctx.project.id})

      {_s, source} =
        fixture(:intake_source, %{
          tenant_id: ctx.tenant.id,
          project_id: ctx.project.id,
          target_epic_id: epic.id
        })

      body =
        conn
        |> auth(ctx.operator_key)
        |> patch(~p"/api/v1/intake/sources/#{source.id}", %{})
        |> json_response(422)

      assert body["error"]["code"] == "nothing_to_update"
      assert AdminRepo.get!(Source, source.id).target_epic_id == epic.id
    end

    test "an invalid base branch commits NOTHING, the repoint included", %{conn: conn} do
      ctx = operator_ctx()
      epic = fixture(:epic, %{tenant_id: ctx.tenant.id, project_id: ctx.project.id})

      {_s, source} =
        fixture(:intake_source, %{tenant_id: ctx.tenant.id, project_id: ctx.project.id})

      # Two context calls in sequence committed the repoint AND appended its chain entry
      # before the branch could be refused, so a caller reading the 422 believed neither field
      # had changed while one had — and the chain carried an entry for it.
      conn
      |> auth(ctx.operator_key)
      |> patch(~p"/api/v1/intake/sources/#{source.id}", %{
        "target_epic_id" => epic.id,
        "base_branch" => ""
      })
      |> json_response(422)

      reloaded = AdminRepo.get!(Source, source.id)
      assert reloaded.target_epic_id == nil
      assert reloaded.base_branch == "master"

      assert [] ==
               AdminRepo.all(
                 from e in Entry,
                   where:
                     e.tenant_id == ^ctx.tenant.id and
                       e.action in ["intake_source_repointed", "intake_source_base_branch_set"]
               )
    end

    test "a PATCH that does not name the base branch leaves it where it was", %{conn: conn} do
      ctx = operator_ctx()
      epic = fixture(:epic, %{tenant_id: ctx.tenant.id, project_id: ctx.project.id})

      {_s, source} =
        fixture(:intake_source, %{tenant_id: ctx.tenant.id, project_id: ctx.project.id})

      {:ok, _} = Intake.set_base_branch(ctx.tenant.id, source.id, "main")

      # THE OPPOSITE RULE TO `target_epic_id`, and it must be: the epic is nullable and unset
      # means "not answered", so omitting it clears it — while the base branch is NOT NULL,
      # every dispatch has to name one, and there is no unanswered state. Omitting it here
      # must therefore leave an operator's override alone rather than reset it to the default
      # they had already overridden.
      body =
        conn
        |> auth(ctx.operator_key)
        |> patch(~p"/api/v1/intake/sources/#{source.id}", %{"target_epic_id" => epic.id})
        |> json_response(200)

      assert body["source"]["base_branch"] == "main"
      assert body["source"]["target_epic_id"] == epic.id
    end

    test "an explicit null base branch is refused rather than stored", %{conn: conn} do
      ctx = operator_ctx()

      {_s, source} =
        fixture(:intake_source, %{tenant_id: ctx.tenant.id, project_id: ctx.project.id})

      conn
      |> auth(ctx.operator_key)
      |> patch(~p"/api/v1/intake/sources/#{source.id}", %{"base_branch" => nil})
      |> json_response(422)

      assert AdminRepo.get!(Source, source.id).base_branch == "master"
    end

    test "an explicit null clears the target", %{conn: conn} do
      ctx = operator_ctx()
      epic = fixture(:epic, %{tenant_id: ctx.tenant.id, project_id: ctx.project.id})

      {_s, source} =
        fixture(:intake_source, %{
          tenant_id: ctx.tenant.id,
          project_id: ctx.project.id,
          target_epic_id: epic.id
        })

      body =
        conn
        |> auth(ctx.operator_key)
        |> patch(~p"/api/v1/intake/sources/#{source.id}", %{"target_epic_id" => nil})
        |> json_response(200)

      assert body["source"]["target_epic_id"] == nil
      assert AdminRepo.get!(Source, source.id).target_epic_id == nil
    end

    test "422 for an epic outside the source's project", %{conn: conn} do
      ctx = operator_ctx()
      other_project = fixture(:project, %{tenant_id: ctx.tenant.id})
      epic = fixture(:epic, %{tenant_id: ctx.tenant.id, project_id: other_project.id})

      {_s, source} =
        fixture(:intake_source, %{tenant_id: ctx.tenant.id, project_id: ctx.project.id})

      assert conn
             |> auth(ctx.operator_key)
             |> patch(~p"/api/v1/intake/sources/#{source.id}", %{"target_epic_id" => epic.id})
             |> json_response(422)

      assert AdminRepo.get!(Source, source.id).target_epic_id == nil
    end

    test "404 for another tenant's source, which is not repointed", %{conn: conn} do
      ctx = operator_ctx()
      {_s, other} = fixture(:intake_source, %{})
      epic = fixture(:epic, %{tenant_id: ctx.tenant.id, project_id: ctx.project.id})

      assert conn
             |> auth(ctx.operator_key)
             |> patch(~p"/api/v1/intake/sources/#{other.id}", %{"target_epic_id" => epic.id})
             |> json_response(404)

      assert AdminRepo.get!(Source, other.id).target_epic_id == nil
    end

    test "an agent-rooted tenant is refused: intake is a human-anchored surface", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {operator_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      {_s, source} = fixture(:intake_source, %{tenant_id: tenant.id})

      # The WRITE half of the surface is what the anchor gates, and a repoint redirects where
      # outside text lands — the same act as enrolling the source, arriving later.
      assert conn
             |> auth(operator_key)
             |> patch(~p"/api/v1/intake/sources/#{source.id}", %{"target_epic_id" => nil})
             |> json_response(403)
    end
  end

  describe "DELETE /api/v1/intake/sources/:id" do
    test "revokes the source once, idempotently, with one audit entry", %{conn: conn} do
      ctx = operator_ctx()

      {_s, source} =
        fixture(:intake_source, %{tenant_id: ctx.tenant.id, project_id: ctx.project.id})

      authed = auth(conn, ctx.operator_key)

      first = json_response(delete(authed, ~p"/api/v1/intake/sources/#{source.id}"), 200)
      second = json_response(delete(authed, ~p"/api/v1/intake/sources/#{source.id}"), 200)

      assert first["source"]["revoked_at"]
      assert second["source"]["revoked_at"] == first["source"]["revoked_at"]

      assert [_one] =
               AdminRepo.all(
                 from e in Entry,
                   where: e.tenant_id == ^ctx.tenant.id and e.action == "intake_source_revoked"
               )

      # A revoked repository can be bound again.
      assert json_response(post(authed, ~p"/api/v1/intake/sources", create_params(ctx)), 201)
    end

    test "404 for another tenant's source, which stays active", %{conn: conn} do
      ctx = operator_ctx()
      {_s, other} = fixture(:intake_source, %{})

      assert conn
             |> auth(ctx.operator_key)
             |> delete(~p"/api/v1/intake/sources/#{other.id}")
             |> json_response(404)

      assert %Source{revoked_at: nil} = AdminRepo.get!(Source, other.id)
    end
  end
end
