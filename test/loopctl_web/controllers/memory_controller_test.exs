defmodule LoopctlWeb.MemoryControllerTest do
  @moduledoc """
  US-28.3 — HTTP JSON API for agent memory (`/api/v1/memory*`).

  Covers the scope-from-key invariant (body tenant_id/subject_id ignored),
  cross-subject and cross-tenant isolation, superadmin oversight, the custody-halt
  write block, and subject-unresolvable rejection.

  Async: every path routes through `Loopctl.AdminRepo` / `Loopctl.HeavyRead` (which
  points at `AdminRepo` in test), so all queries share the one sandbox connection
  the fixtures insert through, and inline Oban embeds long-term writes during the
  request.
  """
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Auth.ApiKey
  alias Loopctl.Knowledge
  alias Loopctl.Memory
  alias Loopctl.Memory.Scope
  alias LoopctlWeb.MemoryController

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  # A fresh conn carrying the witness STH header (ConnCase adds it to the shared
  # `conn`, but each dispatched request needs its own conn).
  defp base_conn,
    do: put_req_header(build_conn(), "x-loopctl-last-known-sth", "0:AAAAAAAAAAAAAAAAAAAAAA")

  # api_keys.agent_id is a FK to agents, so mint a real agent per agent key. The
  # agent's id becomes the memory subject_id (subject_id_for/1).
  defp agent_key(tenant_id) do
    agent = fixture(:agent, %{tenant_id: tenant_id})
    {raw, key} = fixture(:api_key, %{tenant_id: tenant_id, role: :agent, agent_id: agent.id})
    {raw, key, agent}
  end

  # The %Scope{} a given agent key resolves to (subject_id = agent.id).
  defp scope_for(tenant_id, agent),
    do: %Scope{tenant_id: tenant_id, subject_id: to_string(agent.id)}

  # Override the default promoter-LLM stub to emit a crafted candidate array, and
  # signal every call so a NON-call can be asserted (refute_received :llm_called).
  defp stub_promoter(candidates) do
    json =
      candidates
      |> Enum.map(fn c ->
        %{
          "text" => c.text,
          "when_to_apply" => Map.get(c, :when_to_apply, "when relevant"),
          "tags" => Map.get(c, :tags, ["t"]),
          "confidence" => c.confidence,
          "cross_links" => []
        }
      end)
      |> JSON.encode!()

    Mox.stub(Loopctl.MockPromoterLLM, :extract, fn _tenant_id, _content, _opts ->
      send(self(), :llm_called)
      {:ok, json}
    end)
  end

  # --- TC-28.3.1: remember + recall round-trip over HTTP ---

  describe "POST /api/v1/memory + POST /api/v1/memory/recall (TC-28.3.1)" do
    test "round-trips a long-term memory within the key's scope", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)
      Knowledge.reset_circuit_breaker(tenant.id)

      create_conn =
        conn
        |> auth(raw)
        |> post(~p"/api/v1/memory", %{"tier" => "long_term", "text" => "prefers reshipments"})

      created = json_response(create_conn, 201)
      assert created["data"]["tier"] == "long_term"
      assert created["data"]["text"] == "prefers reshipments"

      recall_conn =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/memory/recall", %{"query" => "handling delayed orders"})

      body = json_response(recall_conn, 200)
      assert %{"data" => [entry | _], "meta" => meta} = body
      assert entry["memory"]["text"] == "prefers reshipments"
      assert is_map(meta)
      assert Map.has_key?(meta, "total_count")
      assert meta["fallback"] == false
    end
  end

  # --- Review finding (US-28.4): metadata must persist for the DEFAULT tier ---
  #
  # memory_remember/the HTTP API advertise a generic `metadata` param, but
  # `create_changeset/2` used to cast metadata ONLY for `session_memories` — the
  # default `long_term` tier silently dropped it (no column, no cast, no render).
  # Prove the fix: metadata written on a long_term memory round-trips through
  # both `POST /api/v1/memory` and the recall response.
  describe "metadata persists on the default long_term tier (review finding)" do
    test "a metadata map supplied on a long_term write is stored and rendered back", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)
      Knowledge.reset_circuit_breaker(tenant.id)

      created =
        conn
        |> auth(raw)
        |> post(~p"/api/v1/memory", %{
          "tier" => "long_term",
          "text" => "prefers Req over Tesla",
          "metadata" => %{"source" => "code_review", "pr" => 320}
        })
        |> json_response(201)

      assert created["data"]["metadata"] == %{"source" => "code_review", "pr" => 320}

      recall_body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/memory/recall", %{"query" => "HTTP client preference"})
        |> json_response(200)

      assert %{"data" => [entry | _]} = recall_body
      assert entry["memory"]["metadata"] == %{"source" => "code_review", "pr" => 320}
    end

    test "omitting metadata on a long_term write defaults it to an empty map", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)

      created =
        conn
        |> auth(raw)
        |> post(~p"/api/v1/memory", %{"tier" => "long_term", "text" => "no metadata here"})
        |> json_response(201)

      assert created["data"]["metadata"] == %{}
    end
  end

  # --- TC-28.3.2: body-supplied subject ignored; cross-subject read impossible ---

  describe "cross-subject isolation (TC-28.3.2)" do
    test "a body subject_id is ignored and B never sees A's memory", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_a, _key_a, agent_a} = agent_key(tenant.id)
      {raw_b, _key_b, _agent_b} = agent_key(tenant.id)
      Knowledge.reset_circuit_breaker(tenant.id)

      conn
      |> auth(raw_a)
      |> post(~p"/api/v1/memory", %{"tier" => "long_term", "text" => "alpha secret note"})
      |> json_response(201)

      # B recalls, spoofing A's subject in the body — must be ignored.
      recall_body =
        base_conn()
        |> auth(raw_b)
        |> post(~p"/api/v1/memory/recall", %{
          "query" => "alpha secret",
          "subject_id" => to_string(agent_a.id)
        })
        |> json_response(200)

      refute Enum.any?(recall_body["data"], &(&1["memory"]["text"] == "alpha secret note"))

      # B lists — A's memory never appears, no 500, no existence leak.
      list_body =
        base_conn()
        |> auth(raw_b)
        |> get(~p"/api/v1/memory")
        |> json_response(200)

      assert list_body["data"] == []
    end
  end

  # --- TC-28.3.3: cross-tenant read impossible + body tenant_id ignored ---

  describe "cross-tenant isolation (TC-28.3.3)" do
    test "body tenant_id is ignored; writes land under the key's tenant", %{conn: conn} do
      tenant_t = fixture(:tenant)
      tenant_u = fixture(:tenant)
      {raw_t, _key_t, _agent_t} = agent_key(tenant_t.id)
      Knowledge.reset_circuit_breaker(tenant_t.id)

      # A memory under tenant_u, distinct subject.
      fixture(:memory, %{tenant_id: tenant_u.id, subject_id: "u-subject", text: "unicorn fact"})

      # Write as the tenant_t key, spoofing tenant_u in the body — must land under tenant_t.
      created =
        conn
        |> auth(raw_t)
        |> post(~p"/api/v1/memory", %{
          "tier" => "long_term",
          "text" => "tango fact",
          "tenant_id" => tenant_u.id
        })
        |> json_response(201)

      assert created["data"]["tenant_id"] == tenant_t.id

      # List as tenant_t — sees only its own tenant/subject rows; tenant_u never leaks.
      list_body =
        base_conn()
        |> auth(raw_t)
        |> get(~p"/api/v1/memory")
        |> json_response(200)

      texts = Enum.map(list_body["data"], & &1["text"])
      assert "tango fact" in texts
      refute "unicorn fact" in texts
      assert Enum.all?(list_body["data"], &(&1["tenant_id"] == tenant_t.id))
    end
  end

  # --- TC-28.3.4: superadmin lists across subjects, agent cannot ---

  describe "superadmin oversight (TC-28.3.4)" do
    test "superadmin sees all subjects; agent is confined to its own", %{conn: conn} do
      tenant = fixture(:tenant)
      # Superadmin keys are tenant-less; the tenant scope is supplied via
      # X-Impersonate-Tenant (Impersonate keeps role :superadmin, sets tenant_id).
      {raw_super, _super_key} = fixture(:api_key, %{role: :superadmin})
      {raw_agent, _agent_key, agent} = agent_key(tenant.id)

      fixture(:memory, %{tenant_id: tenant.id, subject_id: "other-subject", text: "other note"})
      fixture(:memory, %{tenant_id: tenant.id, subject_id: to_string(agent.id), text: "own note"})

      # Superadmin with all_subjects=true sees BOTH subjects.
      super_body =
        conn
        |> put_req_header("x-impersonate-tenant", tenant.id)
        |> auth(raw_super)
        |> get(~p"/api/v1/memory?all_subjects=true")
        |> json_response(200)

      subjects = super_body["data"] |> Enum.map(& &1["subject_id"]) |> Enum.uniq()
      assert "other-subject" in subjects
      assert to_string(agent.id) in subjects

      # Agent requesting all_subjects=true is IGNORED — sees only its own subject.
      agent_body =
        base_conn()
        |> auth(raw_agent)
        |> get(~p"/api/v1/memory?all_subjects=true")
        |> json_response(200)

      assert Enum.all?(agent_body["data"], &(&1["subject_id"] == to_string(agent.id)))
      refute Enum.any?(agent_body["data"], &(&1["text"] == "other note"))
    end

    test "superadmin may delete any subject's memory; agent may not", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_super, _super_key} = fixture(:api_key, %{role: :superadmin})
      {raw_agent, _agent_key, _agent} = agent_key(tenant.id)

      foreign = fixture(:memory, %{tenant_id: tenant.id, subject_id: "foreign-subject"})

      # Agent cannot delete a foreign subject's memory — 404, no existence leak.
      conn
      |> auth(raw_agent)
      |> delete(~p"/api/v1/memory/#{foreign.id}")
      |> json_response(404)

      # Superadmin (impersonating the tenant) can delete any memory in it.
      del_body =
        base_conn()
        |> put_req_header("x-impersonate-tenant", tenant.id)
        |> auth(raw_super)
        |> delete(~p"/api/v1/memory/#{foreign.id}")
        |> json_response(200)

      assert del_body["data"]["deleted"] == true
    end
  end

  # --- TC-28.3.5: custody-halted key cannot write ---

  describe "custody halt (TC-28.3.5)" do
    test "a custody-halted tenant's key cannot write memory (503)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)
      {:ok, _} = Loopctl.Tenants.halt_custody(tenant.id)

      body =
        conn
        |> auth(raw)
        |> post(~p"/api/v1/memory", %{"tier" => "long_term", "text" => "should not persist"})
        |> json_response(503)

      assert body["error"]["code"] == "tenant_halted"
    end
  end

  # --- Own-subject delete + not-found (no existence leak) ---

  describe "DELETE /api/v1/memory/:id" do
    test "deletes the caller's own memory and 404s an unknown id", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw, _key, agent} = agent_key(tenant.id)
      mine = fixture(:memory, %{tenant_id: tenant.id, subject_id: to_string(agent.id)})

      conn
      |> auth(raw)
      |> delete(~p"/api/v1/memory/#{mine.id}")
      |> json_response(200)

      base_conn()
      |> auth(raw)
      |> delete(~p"/api/v1/memory/#{Ecto.UUID.generate()}")
      |> json_response(404)
    end
  end

  # --- Subject-unresolvable rejection (AC-28.3.2) ---

  describe "subject_id_unresolvable" do
    test "an identity-less key is refused with a deterministic 422" do
      tenant = fixture(:tenant)

      # subject_id_for/1 cannot resolve a key with no id AND no agent_id — the
      # controller must refuse rather than operate on a null scope. (Unreachable
      # through the real pipeline; exercised by calling the action directly.)
      conn =
        build_conn()
        |> Plug.Conn.assign(:current_api_key, %ApiKey{
          id: nil,
          tenant_id: tenant.id,
          role: :agent,
          agent_id: nil
        })

      result = MemoryController.index(conn, %{})
      assert json_response(result, 422)["error"]["code"] == "subject_id_unresolvable"
    end
  end

  # --- Recall degradation shape over HTTP (AC-28.3.5) ---

  describe "POST /api/v1/memory/recall degradation" do
    test "degrades to the fallback envelope (score null, meta.fallback/reason) when " <>
           "embeddings are unavailable" do
      tenant = fixture(:tenant)
      {raw, _key, agent} = agent_key(tenant.id)

      # Seed a long-term row directly so the ILIKE fallback has something to return.
      fixture(:memory, %{
        tenant_id: tenant.id,
        subject_id: to_string(agent.id),
        text: "prefers reshipments"
      })

      # Force embedding generation to fail -> recall takes the recent-first ILIKE
      # fallback path (`:no_api_key` is exempt from the circuit breaker, so this is
      # deterministic and self-contained).
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :no_api_key}
      end)

      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/memory/recall", %{"query" => "reshipments"})
        |> json_response(200)

      assert %{"data" => [entry | _], "meta" => meta} = body
      assert entry["memory"]["text"] == "prefers reshipments"
      # score is null on the fallback path (no vector similarity computed).
      assert entry["score"] == nil
      assert meta["fallback"] == true
      assert meta["reason"] == "no_embedding_key"
    end

    test "a non-string query is rejected with a deterministic 422 (no 500 crash)" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)

      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/memory/recall", %{"query" => %{"nested" => "object"}})
        |> json_response(422)

      assert body["error"]["code"] == "invalid_query"
      assert body["error"]["status"] == 422
    end
  end

  # --- #411 Gap 2: project_id on create + recall (merged global ∪ active-project) ---

  describe "POST /api/v1/memory + /recall project_id scoping (#411 Gap 2)" do
    test "create persists a valid project_id", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)
      Knowledge.reset_circuit_breaker(tenant.id)
      project = fixture(:project, %{tenant_id: tenant.id})

      created =
        conn
        |> auth(raw)
        |> post(~p"/api/v1/memory", %{
          "tier" => "long_term",
          "text" => "prefers reshipments",
          "project_id" => project.id
        })
        |> json_response(201)

      assert created["data"]["project_id"] == project.id
    end

    test "recall with a valid project_id returns merged global ∪ project", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)
      Knowledge.reset_circuit_breaker(tenant.id)
      project = fixture(:project, %{tenant_id: tenant.id})

      # Global memory (no project_id).
      conn
      |> auth(raw)
      |> post(~p"/api/v1/memory", %{"tier" => "long_term", "text" => "global widgets fact"})
      |> json_response(201)

      # Project-scoped memory.
      base_conn()
      |> auth(raw)
      |> post(~p"/api/v1/memory", %{
        "tier" => "long_term",
        "text" => "project widgets fact",
        "project_id" => project.id
      })
      |> json_response(201)

      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/memory/recall", %{"query" => "widgets", "project_id" => project.id})
        |> json_response(200)

      texts = Enum.map(body["data"], & &1["memory"]["text"])
      assert "global widgets fact" in texts
      assert "project widgets fact" in texts
    end

    test "recall with a different project_id excludes that project's memory", %{conn: _conn} do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)
      Knowledge.reset_circuit_breaker(tenant.id)
      project_a = fixture(:project, %{tenant_id: tenant.id})
      project_b = fixture(:project, %{tenant_id: tenant.id})

      base_conn()
      |> auth(raw)
      |> post(~p"/api/v1/memory", %{
        "tier" => "long_term",
        "text" => "project alpha widgets fact",
        "project_id" => project_a.id
      })
      |> json_response(201)

      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/memory/recall", %{"query" => "widgets", "project_id" => project_b.id})
        |> json_response(200)

      texts = Enum.map(body["data"], & &1["memory"]["text"])
      refute "project alpha widgets fact" in texts
    end

    test "a malformed project_id on recall returns a deterministic 422 invalid_project_id", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)

      body =
        conn
        |> auth(raw)
        |> post(~p"/api/v1/memory/recall", %{"query" => "widgets", "project_id" => "not-a-uuid"})
        |> json_response(422)

      assert body["error"]["code"] == "invalid_project_id"
      assert body["error"]["status"] == 422
    end

    test "a malformed project_id on create returns a deterministic 422 invalid_project_id", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)

      body =
        conn
        |> auth(raw)
        |> post(~p"/api/v1/memory", %{
          "tier" => "long_term",
          "text" => "x",
          "project_id" => "not-a-uuid"
        })
        |> json_response(422)

      assert body["error"]["code"] == "invalid_project_id"
      assert body["error"]["status"] == 422
    end
  end

  # --- Quota-exceeded envelope over HTTP (create/2) ---

  describe "POST /api/v1/memory quota" do
    test "a write past the per-subject quota returns the 422 quota_exceeded envelope", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw, _key, agent} = agent_key(tenant.id)
      cap = Application.get_env(:loopctl, :max_long_term_memories_per_subject, 10_000)

      # Fill the subject's live long-term tier exactly to the cap.
      for n <- 1..cap do
        fixture(:memory, %{
          tenant_id: tenant.id,
          subject_id: to_string(agent.id),
          text: "seed #{n}"
        })
      end

      body =
        conn
        |> auth(raw)
        |> post(~p"/api/v1/memory", %{"tier" => "long_term", "text" => "one too many"})
        |> json_response(422)

      assert body["error"]["code"] == "quota_exceeded"
      assert body["error"]["status"] == 422
    end
  end

  # --- Index pagination meta over HTTP (AC-28.3.5) ---

  describe "GET /api/v1/memory pagination meta" do
    test "index returns meta.total_count/limit/offset reflecting the scoped page" do
      tenant = fixture(:tenant)
      {raw, _key, agent} = agent_key(tenant.id)

      for n <- 1..3 do
        fixture(:memory, %{
          tenant_id: tenant.id,
          subject_id: to_string(agent.id),
          text: "m#{n}"
        })
      end

      body =
        base_conn()
        |> auth(raw)
        |> get(~p"/api/v1/memory?limit=2&offset=1")
        |> json_response(200)

      assert %{"data" => data, "meta" => meta} = body
      # limit caps the page; total_count is the TRUE scoped total (never capped).
      assert length(data) == 2
      assert meta["total_count"] == 3
      assert meta["limit"] == 2
      assert meta["offset"] == 1
    end
  end

  # --- Superadmin oversight WITHOUT an impersonation target (AC-28.3.4 / .5) ---

  describe "superadmin oversight without impersonation" do
    test "all_subjects list without X-Impersonate-Tenant returns 422, not a 500 crash", %{
      conn: conn
    } do
      # Superadmin keys are tenant-less; without impersonation the tenant scope is
      # nil, which would crash the guarded `list_all_subjects/2` (is_binary/1).
      {raw_super, _super_key} = fixture(:api_key, %{role: :superadmin})

      body =
        conn
        |> auth(raw_super)
        |> get(~p"/api/v1/memory?all_subjects=true")
        |> json_response(422)

      assert body["error"]["code"] == "impersonation_tenant_required"
      assert body["error"]["status"] == 422
    end

    test "any-subject delete without X-Impersonate-Tenant returns 422, not a 500 crash", %{
      conn: conn
    } do
      {raw_super, _super_key} = fixture(:api_key, %{role: :superadmin})

      body =
        conn
        |> auth(raw_super)
        |> delete(~p"/api/v1/memory/#{Ecto.UUID.generate()}")
        |> json_response(422)

      assert body["error"]["code"] == "impersonation_tenant_required"
      assert body["error"]["status"] == 422
    end

    # A tenant-less superadmin hitting the OWN-scope actions (no all_subjects, POST
    # create, POST recall) has tenant_id nil; without this guard the own-scope path
    # would build a %Scope{tenant_id: nil} and Ecto would raise at query-build time
    # ("comparing with nil is forbidden") -> a bare HTTP 500. Each must return the
    # deterministic 422 impersonation envelope instead (AC-28.3.2 / .5).
    test "own-scope list without X-Impersonate-Tenant returns 422, not a 500 crash", %{
      conn: conn
    } do
      {raw_super, _super_key} = fixture(:api_key, %{role: :superadmin})

      body =
        conn
        |> auth(raw_super)
        |> get(~p"/api/v1/memory")
        |> json_response(422)

      assert body["error"]["code"] == "impersonation_tenant_required"
      assert body["error"]["status"] == 422
    end

    test "own-scope create without X-Impersonate-Tenant returns 422, not a 500 crash", %{
      conn: conn
    } do
      {raw_super, _super_key} = fixture(:api_key, %{role: :superadmin})

      body =
        conn
        |> auth(raw_super)
        |> post(~p"/api/v1/memory", %{"tier" => "long_term", "text" => "orphan note"})
        |> json_response(422)

      assert body["error"]["code"] == "impersonation_tenant_required"
      assert body["error"]["status"] == 422
    end

    test "own-scope recall without X-Impersonate-Tenant returns 422, not a 500 crash", %{
      conn: conn
    } do
      {raw_super, _super_key} = fixture(:api_key, %{role: :superadmin})

      body =
        conn
        |> auth(raw_super)
        |> post(~p"/api/v1/memory/recall", %{"query" => "anything"})
        |> json_response(422)

      assert body["error"]["code"] == "impersonation_tenant_required"
      assert body["error"]["status"] == 422
    end
  end

  # --- Superadmin oversight is NOT frozen by a custody halt (AC-28.3.4) ---

  describe "superadmin oversight during a custody halt" do
    test "superadmin may still LIST and DELETE on a halted tenant, but agent writes stay 503" do
      tenant = fixture(:tenant)
      {raw_super, _super_key} = fixture(:api_key, %{role: :superadmin})
      {raw_agent, _agent_key, agent} = agent_key(tenant.id)

      target =
        fixture(:memory, %{
          tenant_id: tenant.id,
          subject_id: to_string(agent.id),
          text: "halted-tenant note"
        })

      {:ok, _} = Loopctl.Tenants.halt_custody(tenant.id)

      # The halt still blocks the agent's own custody WRITE (AC-28.3.3 baseline).
      agent_write =
        base_conn()
        |> auth(raw_agent)
        |> post(~p"/api/v1/memory", %{"tier" => "long_term", "text" => "should not persist"})
        |> json_response(503)

      assert agent_write["error"]["code"] == "tenant_halted"

      # Oversight LIST is NOT frozen — the operator retains visibility during a halt.
      list_body =
        base_conn()
        |> put_req_header("x-impersonate-tenant", tenant.id)
        |> auth(raw_super)
        |> get(~p"/api/v1/memory?all_subjects=true")
        |> json_response(200)

      assert Enum.any?(list_body["data"], &(&1["id"] == target.id))

      # Oversight DELETE is NOT frozen — the operator retains delete control.
      del_body =
        base_conn()
        |> put_req_header("x-impersonate-tenant", tenant.id)
        |> auth(raw_super)
        |> delete(~p"/api/v1/memory/#{target.id}")
        |> json_response(200)

      assert del_body["data"]["deleted"] == true
    end
  end

  # =========================================================================
  # US-29.3 — POST /api/v1/memory/promote + promoted-vs-explicit oversight
  # =========================================================================

  # --- TC-29.3.1: promote endpoint enqueues promotion scoped to the key ---

  describe "POST /api/v1/memory/promote (TC-29.3.1)" do
    test "enqueues promotion under the key's scope; promoted memory surfaces via source=promoted",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw, _key, agent} = agent_key(tenant.id)
      Knowledge.reset_circuit_breaker(tenant.id)
      scope = scope_for(tenant.id, agent)

      # Seed >1 session turn under the KEY's subject so the promotion has content
      # (compile/2 short-circuits a 0/1-turn session without an LLM call).
      for content <- [
            "decided to always expedite reships for this customer",
            "confirmed the customer prefers email follow-ups"
          ] do
        {:ok, _} =
          Memory.remember(scope, %{
            tier: :session,
            session_id: "s1",
            role: :user,
            content: content,
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          })
      end

      stub_promoter([
        %{text: "expedite reships for this customer", confidence: 0.9, tags: ["ship"]}
      ])

      promote_body =
        conn
        |> auth(raw)
        |> post(~p"/api/v1/memory/promote", %{"session_id" => "s1"})
        |> json_response(202)

      assert promote_body["data"]["session_id"] == "s1"
      assert promote_body["data"]["status"] == "enqueued"
      # The 202 reference is the tenant-scoped session_id, NOT the system-wide Oban job
      # id: the raw global bigserial is deliberately withheld from agent-role callers to
      # avoid a cross-tenant throughput side-channel (US-29.3 finding fix).
      refute Map.has_key?(promote_body["data"], "job_id")

      # Inline Oban runs the worker during the request; drain is a harmless no-op.
      Oban.drain_queue(queue: :memory)

      list_body =
        base_conn()
        |> auth(raw)
        |> get(~p"/api/v1/memory?source=promoted")
        |> json_response(200)

      assert [entry | _] = list_body["data"]
      assert entry["source"] == "promoted"
      assert entry["source_session_id"] == "s1"
      assert entry["confidence"] == 0.9
      assert entry["subject_id"] == to_string(agent.id)
    end

    # US-29.3 finding fix: a whitespace-only session_id must hit the documented
    # "non-blank session_id required" 422, not enqueue a budget-consuming no-op.
    test "a whitespace-only session_id returns 422 (not a 202 no-op)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)

      body =
        conn
        |> auth(raw)
        |> post(~p"/api/v1/memory/promote", %{"session_id" => "   "})
        |> json_response(422)

      assert body["error"]["status"] == 422
      assert body["error"]["code"] == "missing_session_id"
    end
  end

  # --- TC-29.3.2: a caller cannot promote another subject's session ---

  describe "POST /api/v1/memory/promote scope isolation (TC-29.3.2)" do
    test "B promoting A's session_id is a scoped no-op; A's memory is never written", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {_raw_a, _key_a, agent_a} = agent_key(tenant.id)
      {raw_b, _key_b, _agent_b} = agent_key(tenant.id)
      Knowledge.reset_circuit_breaker(tenant.id)
      scope_a = scope_for(tenant.id, agent_a)

      # Session s1 belongs to A.
      {:ok, _} =
        Memory.remember(scope_a, %{
          tier: :session,
          session_id: "s1",
          role: :user,
          content: "A's private decision that must not leak to B",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      stub_promoter([%{text: "should never be promoted for A via B", confidence: 0.9}])

      # B promotes "s1" — resolves to B's subject, whose session s1 is empty → no-op.
      conn
      |> auth(raw_b)
      |> post(~p"/api/v1/memory/promote", %{"session_id" => "s1"})
      |> json_response(202)

      Oban.drain_queue(queue: :memory)

      # A has NO promoted memory — B's run could not touch A's (tenant, subject).
      assert %{results: [], meta: %{total_count: 0}} = Memory.list(scope_a, %{source: :promoted})
    end
  end

  # --- TC-29.3.3: superadmin lists promoted across subjects and rejects one ---

  describe "superadmin promoted oversight (TC-29.3.3)" do
    test "lists promoted memories across subjects and can reject one", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_super, _super_key} = fixture(:api_key, %{role: :superadmin})

      p1 =
        fixture(:memory, %{
          tenant_id: tenant.id,
          subject_id: "subj-1",
          source: :promoted,
          source_session_id: "sess-1",
          confidence: 0.8,
          text: "promoted for subject one"
        })

      _p2 =
        fixture(:memory, %{
          tenant_id: tenant.id,
          subject_id: "subj-2",
          source: :promoted,
          source_session_id: "sess-2",
          confidence: 0.7,
          text: "promoted for subject two"
        })

      # An explicit memory must NOT appear under source=promoted.
      fixture(:memory, %{tenant_id: tenant.id, subject_id: "subj-1", text: "explicit note"})

      list_body =
        conn
        |> put_req_header("x-impersonate-tenant", tenant.id)
        |> auth(raw_super)
        |> get(~p"/api/v1/memory?source=promoted&all_subjects=true")
        |> json_response(200)

      subjects = list_body["data"] |> Enum.map(& &1["subject_id"]) |> Enum.uniq() |> Enum.sort()
      assert subjects == ["subj-1", "subj-2"]
      assert Enum.all?(list_body["data"], &(&1["source"] == "promoted"))
      assert Enum.all?(list_body["data"], &(&1["source_session_id"] != nil))
      assert Enum.all?(list_body["data"], &(&1["confidence"] != nil))
      refute Enum.any?(list_body["data"], &(&1["text"] == "explicit note"))

      # Reject a bad promotion via DELETE — nothing left orphaned-invisible.
      del_body =
        base_conn()
        |> put_req_header("x-impersonate-tenant", tenant.id)
        |> auth(raw_super)
        |> delete(~p"/api/v1/memory/#{p1.id}")
        |> json_response(200)

      assert del_body["data"]["deleted"] == true

      after_body =
        base_conn()
        |> put_req_header("x-impersonate-tenant", tenant.id)
        |> auth(raw_super)
        |> get(~p"/api/v1/memory?source=promoted&all_subjects=true")
        |> json_response(200)

      refute Enum.any?(after_body["data"], &(&1["id"] == p1.id))
    end

    # AC-29.3.4: rejecting (deleting) a PROMOTED memory that SUPERSEDES a prior
    # one must never permanently hide the dependent. The promotion worker actively
    # creates superseders (near-dup supersede), so a :promoted memory CAN be a live
    # superseder. This exercises that exact path end-to-end through the HTTP delete:
    # seed a promoted superseder P over dependent D (D.superseded_by = P), then have
    # a superadmin reject P and assert D's edge is nilified (epic_28
    # on_delete: :nilify_all) so D resurfaces in the list rather than staying hidden.
    test "rejecting a promoted superseder nilifies its dependent so no memory stays permanently hidden" do
      tenant = fixture(:tenant)
      {raw_super, _super_key} = fixture(:api_key, %{role: :superadmin})

      # D — the dependent (prior) promoted memory that P will supersede.
      dependent =
        fixture(:memory, %{
          tenant_id: tenant.id,
          subject_id: "subj-1",
          source: :promoted,
          source_session_id: "sess-1",
          confidence: 0.6,
          text: "older promoted truth about the customer"
        })

      # P — the promoted superseder. `superseded_by` is a programmatic field (never
      # cast), so set the edge directly on the dependent, mirroring the worker's
      # supersede write.
      superseder =
        fixture(:memory, %{
          tenant_id: tenant.id,
          subject_id: "subj-1",
          source: :promoted,
          source_session_id: "sess-2",
          confidence: 0.95,
          text: "newer promoted truth about the customer"
        })

      {:ok, _} =
        dependent
        |> Ecto.Changeset.change(superseded_by: superseder.id)
        |> Loopctl.AdminRepo.update()

      # While superseded, D is hidden from the default (include_superseded=false) list;
      # P is present.
      before_ids =
        base_conn()
        |> put_req_header("x-impersonate-tenant", tenant.id)
        |> auth(raw_super)
        |> get(~p"/api/v1/memory?source=promoted&all_subjects=true")
        |> json_response(200)
        |> Map.fetch!("data")
        |> Enum.map(& &1["id"])

      refute dependent.id in before_ids
      assert superseder.id in before_ids

      # Reject the superseder P via superadmin DELETE.
      del_body =
        base_conn()
        |> put_req_header("x-impersonate-tenant", tenant.id)
        |> auth(raw_super)
        |> delete(~p"/api/v1/memory/#{superseder.id}")
        |> json_response(200)

      assert del_body["data"]["deleted"] == true

      # on_delete: :nilify_all cleared D.superseded_by — D is no longer hidden.
      reloaded = Loopctl.AdminRepo.get(Loopctl.Memory.Memory, dependent.id)
      assert is_nil(reloaded.superseded_by)

      # D resurfaces in the default list; P is gone. Nothing stays permanently hidden.
      after_ids =
        base_conn()
        |> put_req_header("x-impersonate-tenant", tenant.id)
        |> auth(raw_super)
        |> get(~p"/api/v1/memory?source=promoted&all_subjects=true")
        |> json_response(200)
        |> Map.fetch!("data")
        |> Enum.map(& &1["id"])

      assert dependent.id in after_ids
      refute superseder.id in after_ids
    end
  end

  # --- TC-29.3.4: custody-halted key cannot promote (503) ---

  describe "POST /api/v1/memory/promote custody halt (TC-29.3.4)" do
    test "a custody-halted tenant's key cannot promote (503)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)
      {:ok, _} = Loopctl.Tenants.halt_custody(tenant.id)

      body =
        conn
        |> auth(raw)
        |> post(~p"/api/v1/memory/promote", %{"session_id" => "s1"})
        |> json_response(503)

      assert body["error"]["code"] == "tenant_halted"
    end
  end

  # --- Over-budget: 429 without enqueuing or calling the LLM ---

  describe "POST /api/v1/memory/promote over budget" do
    test "returns 429 (standard envelope), enqueues nothing, and never calls the LLM", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw, _key, agent} = agent_key(tenant.id)
      scope = scope_for(tenant.id, agent)

      # Exhaust the per-hour promotion budget by seeding watermark rows in-hour
      # (config: :memory_promotion_compiles_per_hour = 5).
      for i <- 1..Memory.promotion_budget() do
        {:ok, _} =
          Memory.upsert_session_promotion(
            %Scope{scope | session_id: "budget-#{i}"},
            %{content_hash: "h#{i}", last_turn_inserted_at: DateTime.utc_now()}
          )
      end

      # A LLM call would signal :llm_called — assert it never happens.
      stub_promoter([%{text: "should not compile", confidence: 0.9}])

      body =
        conn
        |> auth(raw)
        |> post(~p"/api/v1/memory/promote", %{"session_id" => "over-budget"})
        |> json_response(429)

      assert body["error"]["code"] == "promotion_budget_exceeded"
      assert body["error"]["status"] == 429

      Oban.drain_queue(queue: :memory)

      # No LLM call, and nothing promoted for this subject.
      refute_received :llm_called
      assert %{results: [], meta: %{total_count: 0}} = Memory.list(scope, %{source: :promoted})
    end
  end

  # --- Missing session_id: 422 ---

  describe "POST /api/v1/memory/promote validation" do
    test "a blank/missing session_id is rejected with a deterministic 422", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)

      body =
        conn
        |> auth(raw)
        |> post(~p"/api/v1/memory/promote", %{})
        |> json_response(422)

      assert body["error"]["code"] == "missing_session_id"
      assert body["error"]["status"] == 422
    end
  end

  # --- GET source=explicit filter isolation ---

  describe "GET /api/v1/memory?source=explicit" do
    test "returns only explicit memories, never promoted ones", %{conn: _conn} do
      tenant = fixture(:tenant)
      {raw, _key, agent} = agent_key(tenant.id)

      fixture(:memory, %{
        tenant_id: tenant.id,
        subject_id: to_string(agent.id),
        text: "explicit one"
      })

      fixture(:memory, %{
        tenant_id: tenant.id,
        subject_id: to_string(agent.id),
        source: :promoted,
        source_session_id: "sX",
        text: "promoted one"
      })

      body =
        base_conn()
        |> auth(raw)
        |> get(~p"/api/v1/memory?source=explicit")
        |> json_response(200)

      texts = Enum.map(body["data"], & &1["text"])
      assert "explicit one" in texts
      refute "promoted one" in texts
      assert Enum.all?(body["data"], &(&1["source"] == "explicit"))
    end
  end
end
