defmodule LoopctlWeb.EgressControllerTest do
  @moduledoc """
  US-41.4 web surface: role asymmetry + mandatory pre-flight (TC-41.4.6), the
  allowlist is not writable at any role (TC-41.4.7), the posture report is
  complete and leaks nothing (TC-41.4.9), and markings are tenant-isolated
  (TC-41.4.13).
  """

  use LoopctlWeb.ConnCase, async: true

  import Mox

  alias Loopctl.Egress
  alias Loopctl.Egress.Allowlist
  alias Loopctl.Egress.PinCache
  alias Loopctl.Egress.Scope

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant)
    on_exit(fn -> PinCache.invalidate_tenant(tenant.id) end)

    keys =
      Map.new([:agent, :orchestrator, :user], fn role ->
        {raw, _} = fixture(:api_key, %{tenant_id: tenant.id, role: role})
        {role, raw}
      end)

    {:ok, tenant: tenant, keys: keys}
  end

  defp auth(conn, raw), do: put_req_header(conn, "authorization", "Bearer #{raw}")

  describe "role asymmetry on local_only (AC-41.4.1, TC-41.4.6)" do
    test "an agent can NEITHER enable nor clear", %{conn: conn, keys: keys} do
      assert conn
             |> auth(keys.agent)
             |> post(~p"/api/v1/egress/local-only", %{acknowledge: true})
             |> json_response(403)

      assert conn
             |> auth(keys.agent)
             |> delete(~p"/api/v1/egress/local-only")
             |> json_response(403)
    end

    test "an orchestrator can ENABLE but NOT clear", %{conn: conn, keys: keys, tenant: t} do
      assert conn
             |> auth(keys.orchestrator)
             |> post(~p"/api/v1/egress/local-only", %{acknowledge: true})
             |> json_response(200)

      assert Egress.effective_local_only?(Scope.new(t.id))

      assert conn
             |> auth(keys.orchestrator)
             |> delete(~p"/api/v1/egress/local-only")
             |> json_response(403)

      # Still marked — the tightening role genuinely cannot undo it.
      assert Egress.effective_local_only?(Scope.new(t.id))
    end

    test "a user can do BOTH", %{conn: conn, keys: keys, tenant: t} do
      assert conn
             |> auth(keys.user)
             |> post(~p"/api/v1/egress/local-only", %{acknowledge: true})
             |> json_response(200)

      assert conn
             |> auth(keys.user)
             |> delete(~p"/api/v1/egress/local-only")
             |> json_response(200)

      refute Egress.effective_local_only?(Scope.new(t.id))
    end

    test "the pre-flight REFUSES an un-acknowledged enable on a vendor-endpoint scope, naming every offending endpoint",
         %{conn: conn, keys: keys, tenant: t} do
      body =
        conn
        |> auth(keys.orchestrator)
        |> post(~p"/api/v1/egress/local-only", %{})
        |> json_response(409)

      assert body["error"] == "would_block_endpoints"
      assert body["blocked_endpoints"] != []
      assert Enum.all?(body["blocked_endpoints"], &is_binary(&1["endpoint"]))
      assert body["message"] =~ "acknowledge=true"

      # NOT a silent tenant-wide outage: nothing was written.
      refute Egress.effective_local_only?(Scope.new(t.id))
    end

    test "the acknowledged retry succeeds and REPORTS the resulting blocked posture",
         %{conn: conn, keys: keys} do
      body =
        conn
        |> auth(keys.orchestrator)
        |> post(~p"/api/v1/egress/local-only", %{acknowledge: true})
        |> json_response(200)

      assert body["local_only"] == true
      assert body["acknowledged"] == true
      assert body["blocked_endpoints"] != []
      assert body["note"] =~ "egress_blocked"
    end
  end

  describe "the deployment allowlist is not writable at ANY role (AC-41.4.5, TC-41.4.7)" do
    test "no exposed egress route mutates it", %{conn: conn, keys: keys} do
      before = Allowlist.raw_entries()

      poison = ["10.0.0.0/8", "169.254.169.254"]

      for role <- [:agent, :orchestrator, :user] do
        c = auth(conn, keys[role])
        post(c, ~p"/api/v1/egress/local-only", %{acknowledge: true, deployment_allowlist: poison})

        post(c, ~p"/api/v1/egress/trusted-endpoints", %{
          host: "x.example.com",
          purposes: ["inference"],
          deployment_allowlist: poison,
          local_endpoint_allowlist: poison
        })

        post(c, ~p"/api/v1/egress/repin", %{host: "x.example.com", deployment_allowlist: poison})
        delete(c, ~p"/api/v1/egress/local-only", %{deployment_allowlist: poison})
        get(c, ~p"/api/v1/egress/posture")
      end

      assert Allowlist.raw_entries() == before
    end

    test "the router exposes no allowlist path at all" do
      paths = Enum.map(LoopctlWeb.Router.__routes__(), & &1.path)
      refute Enum.any?(paths, &(&1 =~ "allowlist"))
    end
  end

  describe "posture report (AC-41.4.8, TC-41.4.9)" do
    setup %{tenant: t} do
      stub(Loopctl.MockDnsResolver, :resolve, fn
        "ollama.example.com" -> {:ok, [{203, 0, 113, 10}]}
        _ -> {:ok, [{93, 184, 216, 34}]}
      end)

      {:ok, _} =
        Egress.declare_trusted_endpoint(t.id, %{
          "host" => "ollama.example.com",
          "purposes" => ["inference"]
        })

      {:ok, _} = Egress.enable_local_only(t.id, nil, acknowledge: true)
      Loopctl.Llm.upsert_settings(t.id, %{"api_key" => "sk-ant-SECRET-POSTURE-CHECK"})
      :ok
    end

    test "at :agent — own endpoints, verdicts, declarations, scopes; NO allowlist contents",
         %{conn: conn, keys: keys} do
      body = conn |> auth(keys.agent) |> get(~p"/api/v1/egress/posture") |> json_response(200)

      assert length(body["endpoints"]) >= 2
      assert Enum.all?(body["endpoints"], &is_binary(&1["verdict"]))
      # Only a BOOLEAN about the allowlist — operator infrastructure is not
      # disclosed to the lowest-privileged key of every tenant.
      assert Enum.all?(body["endpoints"], &is_boolean(&1["verdict_from_deployment_allowlist"]))
      refute Map.has_key?(body, "deployment_allowlist")

      [declared] = body["declared_endpoints"]
      assert declared["purposes"] == ["inference"]

      assert declared["locality_label"] ==
               "tenant-declared (unverified attestation), not network-local"

      [scope] = body["scopes"]
      assert scope["local_only"] == true
      assert scope["encrypt_body"] == false
      assert body["posture_defects"] == []

      # US-41.5: webhook delivery is now covered and reported per destination, so
      # the guarantee no longer carves it out — but it is still narrowed to what
      # the static chokepoint check actually proves.
      assert Map.has_key?(body, "webhook_destinations")
      assert is_list(body["webhook_destinations"])
      assert body["guarantee_scope"] =~ "WEBHOOK DELIVERY"
      assert body["guarantee_scope"] =~ "loopctl application code"
      assert body["guarantee_scope"] =~ "inside a dependency"
      refute body["guarantee_scope"] =~ "NOT yet covered"
    end

    # AC-41.5.5: the destination and its locality classification are readable at
    # AGENT role (the URL is not a secret — only the signing secret is), while
    # the allowlist CONTENTS stay a boolean.
    test "webhook destinations are classified at :agent, allowlist as a BOOLEAN",
         %{conn: conn, keys: keys, tenant: tenant} do
      webhook =
        fixture(:webhook, %{
          tenant_id: tenant.id,
          url: "https://hooks.example.com/inbound",
          events: ["story.status_changed"]
        })

      body = conn |> auth(keys.agent) |> get(~p"/api/v1/egress/posture") |> json_response(200)

      assert [destination] = body["webhook_destinations"]
      assert destination["webhook_id"] == webhook.id
      assert destination["endpoint"] == "https://hooks.example.com/inbound"
      assert destination["host"] == "hooks.example.com"
      assert is_binary(destination["verdict"])
      assert is_boolean(destination["verdict_from_deployment_allowlist"])
      assert destination["blocked_by_local_only"] == true
      refute Map.has_key?(destination, "signing_secret_encrypted")
    end

    test "at :user — the allowlist contents ARE present", %{conn: conn, keys: keys} do
      body = conn |> auth(keys.user) |> get(~p"/api/v1/egress/posture") |> json_response(200)
      assert Map.has_key?(body, "deployment_allowlist")
      assert is_list(body["deployment_allowlist"])
    end

    test "NO key material appears in either payload", %{conn: conn, keys: keys} do
      for role <- [:agent, :user] do
        raw =
          conn |> auth(keys[role]) |> get(~p"/api/v1/egress/posture") |> response(200)

        refute raw =~ "sk-ant-SECRET-POSTURE-CHECK"
        refute raw =~ "api_key"
        refute raw =~ "embedding_api_key"
      end
    end

    test "posture is available at :agent (verify-before-harvest works with the key it has)",
         %{conn: conn, keys: keys} do
      assert conn |> auth(keys.agent) |> get(~p"/api/v1/egress/posture") |> json_response(200)
    end
  end

  describe "trusted-endpoint declarations (AC-41.4.5)" do
    test "declaring requires :user", %{conn: conn, keys: keys} do
      for role <- [:agent, :orchestrator] do
        assert conn
               |> auth(keys[role])
               |> post(~p"/api/v1/egress/trusted-endpoints", %{
                 host: "ollama.example.com",
                 purposes: ["inference"]
               })
               |> json_response(403)
      end
    end

    test "a :user declaration succeeds and is labelled an unverified attestation",
         %{conn: conn, keys: keys} do
      stub(Loopctl.MockDnsResolver, :resolve, fn _ -> {:ok, [{203, 0, 113, 10}]} end)

      body =
        conn
        |> auth(keys.user)
        |> post(~p"/api/v1/egress/trusted-endpoints", %{
          host: "ollama.example.com",
          purposes: ["inference"]
        })
        |> json_response(201)

      assert body["host"] == "ollama.example.com"

      assert body["locality_label"] ==
               "tenant-declared (unverified attestation), not network-local"
    end

    test "a private-range declaration is rejected at write time", %{conn: conn, keys: keys} do
      assert conn
             |> auth(keys.user)
             |> post(~p"/api/v1/egress/trusted-endpoints", %{
               host: "169.254.169.254",
               purposes: ["inference"]
             })
             |> json_response(422)
    end

    test "revoking requires :user and invalidates immediately", %{
      conn: conn,
      keys: keys,
      tenant: t
    } do
      stub(Loopctl.MockDnsResolver, :resolve, fn _ -> {:ok, [{203, 0, 113, 10}]} end)

      {:ok, _} =
        Egress.declare_trusted_endpoint(t.id, %{
          "host" => "ollama.example.com",
          "purposes" => ["inference"]
        })

      assert conn
             |> auth(keys.agent)
             |> delete(~p"/api/v1/egress/trusted-endpoints/ollama.example.com")
             |> json_response(403)

      assert conn
             |> auth(keys.user)
             |> delete(~p"/api/v1/egress/trusted-endpoints/ollama.example.com")
             |> json_response(200)

      assert Egress.declared_purposes(t.id, "ollama.example.com") == []
    end
  end

  describe "project_id is resolved against the CALLER's tenant" do
    # REGRESSION (review): `project_id` was taken from the request BODY and written
    # straight into a row whose FK has no tenant component, so tenant A could persist
    # a marking pointing at tenant B's project; a valid FOREIGN uuid returned 200
    # while a nonexistent one 422'd on the FK (a cross-tenant existence oracle); and
    # a non-UUID raised Ecto.Query.CastError -> 500.
    test "a FOREIGN project_id is refused, byte-identically to a nonexistent one",
         %{conn: conn, keys: keys} do
      other = fixture(:tenant)
      foreign = fixture(:project, %{tenant_id: other.id})

      foreign_resp =
        conn
        |> auth(keys.orchestrator)
        |> post(~p"/api/v1/egress/local-only", %{
          "project_id" => foreign.id,
          "acknowledge" => true
        })

      missing_resp =
        conn
        |> auth(keys.orchestrator)
        |> post(~p"/api/v1/egress/local-only", %{
          "project_id" => Ecto.UUID.generate(),
          "acknowledge" => true
        })

      assert json_response(foreign_resp, 404) == json_response(missing_resp, 404)

      # And NOTHING was written against the foreign project.
      assert Egress.get_marking(other.id, foreign.id) == nil
      refute Egress.effective_local_only?(Scope.new(other.id, foreign.id))
    end

    test "a MALFORMED project_id is a clean 404, never a 500", %{conn: conn, keys: keys} do
      assert conn
             |> auth(keys.orchestrator)
             |> post(~p"/api/v1/egress/local-only", %{
               "project_id" => "not-a-uuid",
               "acknowledge" => true
             })
             |> json_response(404)

      assert conn
             |> auth(keys.user)
             |> delete(~p"/api/v1/egress/local-only", %{"project_id" => "not-a-uuid"})
             |> json_response(404)

      assert conn
             |> auth(keys.agent)
             |> post(~p"/api/v1/egress/repin", %{
               "host" => "ollama.example.com",
               "project_id" => "not-a-uuid"
             })
             |> json_response(404)
    end

    test "the caller's OWN project is accepted", %{conn: conn, keys: keys, tenant: t} do
      project = fixture(:project, %{tenant_id: t.id})

      body =
        conn
        |> auth(keys.orchestrator)
        |> post(~p"/api/v1/egress/local-only", %{
          "project_id" => project.id,
          "acknowledge" => true
        })
        |> json_response(200)

      assert body["scope"] == "project:#{project.id}"
      assert Egress.effective_local_only?(Scope.new(t.id, project.id))
    end
  end

  describe "tenant isolation (AC-41.4.11, TC-41.4.13)" do
    test "tenant B cannot see or mutate tenant A's marking", %{conn: conn, keys: keys, tenant: a} do
      {:ok, _} = Egress.enable_local_only(a.id, nil, acknowledge: true)

      other = fixture(:tenant)
      on_exit(fn -> PinCache.invalidate_tenant(other.id) end)
      {raw_b, _} = fixture(:api_key, %{tenant_id: other.id, role: :user})

      body = conn |> auth(raw_b) |> get(~p"/api/v1/egress/posture") |> json_response(200)
      # AC-41.4.8: the TENANT-scope entry is ALWAYS present so an agent doing
      # verify-before-harvest can tell "not marked" from "field not populated" —
      # explicitly `local_only: false` for a tenant that never enabled it.
      assert body["scopes"] == [
               %{
                 "scope" => "tenant",
                 "project_id" => nil,
                 "local_only" => false,
                 "encrypt_body" => false
               }
             ]

      assert body["tenant_id"] == other.id

      # B clearing "the" marking only ever touches its OWN tenant row.
      assert conn |> auth(raw_b) |> delete(~p"/api/v1/egress/local-only") |> json_response(200)
      assert Egress.effective_local_only?(Scope.new(a.id))

      # And A still sees its own.
      body_a = conn |> auth(keys.user) |> get(~p"/api/v1/egress/posture") |> json_response(200)
      assert [%{"local_only" => true}] = body_a["scopes"]
    end
  end

  describe "repin is agent-reachable (AC-41.4.12)" do
    test "an agent can re-pin without a :user write", %{conn: conn, keys: keys, tenant: t} do
      stub(Loopctl.MockDnsResolver, :resolve, fn _ -> {:ok, [{203, 0, 113, 10}]} end)

      {:ok, _} =
        Egress.declare_trusted_endpoint(t.id, %{
          "host" => "ollama.example.com",
          "purposes" => ["inference"]
        })

      body =
        conn
        |> auth(keys.agent)
        |> post(~p"/api/v1/egress/repin", %{host: "ollama.example.com"})
        |> json_response(200)

      assert body["repinned"] == true
      assert body["verdict"] == "tenant_declared"
    end

    test "a resolved vendor endpoint is re-pinnable too", %{conn: conn, keys: keys} do
      stub(Loopctl.MockDnsResolver, :resolve, fn _ -> {:ok, [{93, 184, 216, 34}]} end)

      body =
        conn
        |> auth(keys.agent)
        |> post(~p"/api/v1/egress/repin", %{host: "api.openai.com"})
        |> json_response(200)

      assert body["repinned"] == true
    end

    # REGRESSION (review): repin took an ARBITRARY host at role :agent and returned
    # its locality verdict — a 3-way membership oracle over the OPERATOR deployment
    # allowlist (network_local) and the private address space (denylisted), which
    # AC-41.4.8 deliberately withholds from :agent and `Egress.posture/2` gates
    # behind :user. It also forced server-side DNS of caller-chosen names (an
    # existing internal name 200'd, a nonexistent one 422'd) and inserted every
    # probed host into the globally named pin table the refresher then maintained.
    test "an arbitrary host is REFUSED — no allowlist / internal-DNS oracle",
         %{conn: conn, keys: keys} do
      stub(Loopctl.MockDnsResolver, :resolve, fn _ -> raise "must not resolve a probed host" end)

      body =
        conn
        |> auth(keys.agent)
        |> post(~p"/api/v1/egress/repin", %{host: "secret-internal.operator.example"})
        |> json_response(422)

      assert body["error"] == "host_not_repinnable"
      refute Map.has_key?(body, "verdict")
    end

    test "a non-string host is a clean 422, never a 500", %{conn: conn, keys: keys} do
      body =
        conn
        |> auth(keys.agent)
        |> post(~p"/api/v1/egress/repin", %{host: 123})
        |> json_response(422)

      assert body["error"] == "invalid_host"
    end
  end
end
