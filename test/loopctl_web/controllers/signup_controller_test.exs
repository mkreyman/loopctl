defmodule LoopctlWeb.SignupControllerTest do
  @moduledoc """
  US-26.7.1 — `POST /api/v1/signup`, the public agent-rooted self-signup path.
  """

  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Tenants

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "POST /api/v1/signup" do
    test "creates an agent-rooted tenant and returns a one-time raw_key (TC-26.7.1.3)", %{
      conn: conn
    } do
      unique = System.unique_integer([:positive])

      conn =
        post(conn, ~p"/api/v1/signup", %{
          "name" => "Stranger Agent Co",
          "slug" => "stranger-agent-#{unique}",
          "email" => "agent-#{unique}@stranger.example"
        })

      body = json_response(conn, 201)
      data = body["data"]

      assert data["tenant"]["trust_tier"] == "agent_rooted"
      assert data["tenant"]["status"] == "active"
      assert data["tenant"]["slug"] == "stranger-agent-#{unique}"
      assert is_binary(data["raw_key"])
      assert String.starts_with?(data["raw_key"], "lc_")
      assert is_map(data["next_action"])
    end

    test "does not require any Authorization header (public)", %{conn: conn} do
      unique = System.unique_integer([:positive])

      conn = conn |> delete_req_header("authorization")

      conn =
        post(conn, ~p"/api/v1/signup", %{
          "name" => "No Auth Needed",
          "slug" => "no-auth-#{unique}",
          "email" => "noauth-#{unique}@example.com"
        })

      assert json_response(conn, 201)
    end

    test "duplicate slug returns 422", %{conn: conn} do
      fixture(:tenant, %{slug: "signup-taken"})

      conn =
        post(conn, ~p"/api/v1/signup", %{
          "name" => "Dup",
          "slug" => "signup-taken",
          "email" => "dup-signup@example.com"
        })

      body = json_response(conn, 422)
      assert body["error"]["status"] == 422
    end

    test "duplicate email returns 422", %{conn: conn} do
      fixture(:tenant, %{email: "signup-dup@example.com"})

      conn =
        post(conn, ~p"/api/v1/signup", %{
          "name" => "Dup",
          "slug" => "signup-email-dup",
          "email" => "signup-dup@example.com"
        })

      body = json_response(conn, 422)
      assert body["error"]["status"] == 422
    end

    test "invalid slug format returns 422 via changeset", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/signup", %{
          "name" => "Weird",
          "slug" => "NOT A SLUG",
          "email" => "weird-signup@example.com"
        })

      body = json_response(conn, 422)
      assert body["error"]["details"]["slug"]
    end

    test "oversized field is rejected before the DB call", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/signup", %{
          "name" => String.duplicate("a", 10_000),
          "slug" => "oversized-signup",
          "email" => "oversized@example.com"
        })

      body = json_response(conn, 422)
      assert body["error"]["status"] == 422

      assert {:error, :not_found} = Tenants.get_tenant_by_slug("oversized-signup"),
             "an oversized field must be rejected before any DB write"
    end

    # Review #6a — an oversized-field request must still consume the per-IP
    # budget, so the rate-limit check runs BEFORE the size validation.
    test "an oversized-field request still consumes the rate-limit budget", %{conn: conn} do
      test_pid = self()

      Mox.expect(Loopctl.MockRateLimiter, :check_rate, fn bucket, _window, _limit ->
        send(test_pid, {:rate_checked, bucket})
        {:allow, 1}
      end)

      conn =
        post(conn, ~p"/api/v1/signup", %{
          "name" => String.duplicate("a", 10_000),
          "slug" => "oversized-budget",
          "email" => "oversized-budget@example.com"
        })

      assert json_response(conn, 422)
      # The rate limiter was consulted even though the request 422s on size.
      assert_received {:rate_checked, _bucket}
    end

    # Review #6b — a proxy-resolved client must NOT collapse onto one shared
    # bucket (which a flood could fill to block legitimate signups).
    test "a proxy-resolved client falls back to a non-shared, per-request bucket", %{conn: conn} do
      test_pid = self()

      Mox.expect(Loopctl.MockRateLimiter, :check_rate, fn bucket, _window, _limit ->
        send(test_pid, {:bucket, bucket})
        {:allow, 1}
      end)

      unique = System.unique_integer([:positive])

      # 198.51.100.0/24 is the configured proxy range (config/test.exs). No
      # forwarding header resolves, so ClientIp leaves this proxy IP in place.
      conn =
        %{conn | remote_ip: {198, 51, 100, 5}}
        |> post(~p"/api/v1/signup", %{
          "name" => "Proxy Client",
          "slug" => "proxy-client-#{unique}",
          "email" => "proxy-#{unique}@example.com"
        })

      assert json_response(conn, 201)

      assert_received {:bucket, bucket}
      refute bucket =~ "198.51.100.5"
      assert String.starts_with?(bucket, "api_signup:ip:req:")
    end

    # AC-26.7.1.12(c) — mass assignment closed
    test "privileged fields in the body are ignored (mass assignment closed)", %{conn: conn} do
      unique = System.unique_integer([:positive])

      conn =
        post(conn, ~p"/api/v1/signup", %{
          "name" => "Sneaky",
          "slug" => "sneaky-#{unique}",
          "email" => "sneaky-#{unique}@example.com",
          "trust_tier" => "human_anchored",
          "role" => "superadmin",
          "tenant_id" => Ecto.UUID.generate(),
          "agent_id" => Ecto.UUID.generate()
        })

      body = json_response(conn, 201)
      data = body["data"]

      assert data["tenant"]["trust_tier"] == "agent_rooted"

      {:ok, tenant} = Tenants.get_tenant_by_slug("sneaky-#{unique}")
      assert tenant.trust_tier == :agent_rooted

      # The returned key is role:user, tenant-bound — cannot mint a superadmin key.
      conn2 =
        build_conn()
        |> auth_conn(data["raw_key"])
        |> post(~p"/api/v1/api_keys", %{"name" => "escalate", "role" => "superadmin"})

      assert json_response(conn2, 403)
    end

    # AC-26.7.1.5 — rate limiting
    test "rate-limit denial returns 429 (TC-26.7.1.7)", %{conn: conn} do
      Mox.expect(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window, _limit ->
        {:deny, 5}
      end)

      conn =
        post(conn, ~p"/api/v1/signup", %{
          "name" => "Rate Limited",
          "slug" => "rate-limited-#{System.unique_integer([:positive])}",
          "email" => "rate-limited@example.com"
        })

      body = json_response(conn, 429)
      assert body["error"]["status"] == 429
      assert get_resp_header(conn, "retry-after") != []
    end

    # TC-26.7.1.3 + AC-26.7.1.8 — full agent-rooted KB-tier happy path
    test "end-to-end: configure key -> register agent -> ingest/search -> create then delete an article",
         %{conn: conn} do
      unique = System.unique_integer([:positive])

      signup_conn =
        post(conn, ~p"/api/v1/signup", %{
          "name" => "KB Tier Co",
          "slug" => "kb-tier-#{unique}",
          "email" => "kb-tier-#{unique}@example.com"
        })

      %{"data" => %{"raw_key" => user_key}} = json_response(signup_conn, 201)

      # Configure BYO LLM keys (role: user).
      llm_conn =
        build_conn()
        |> auth_conn(user_key)
        |> patch(~p"/api/v1/tenants/me/llm-config", %{
          "api_key" => "sk-ant-test-key",
          "embedding_api_key" => "sk-embed-test-key"
        })

      refute llm_conn.status == 403

      # Mint its own agent-role key (role:user is allowed to do this).
      key_conn =
        build_conn()
        |> auth_conn(user_key)
        |> post(~p"/api/v1/api_keys", %{"name" => "worker", "role" => "agent"})

      %{"api_key" => %{"raw_key" => agent_key}} = json_response(key_conn, 201)

      # Register an agent identity (AgentController requires exact_role: :agent).
      register_conn =
        build_conn()
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/agents/register", %{
          "name" => "worker-1",
          "agent_type" => "implementer"
        })

      assert json_response(register_conn, 201)

      # Search the wiki.
      search_conn =
        build_conn()
        |> auth_conn(user_key)
        |> get(~p"/api/v1/knowledge/search?q=test")

      refute search_conn.status == 403

      # Create then delete an article.
      create_conn =
        build_conn()
        |> auth_conn(user_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "KB tier article",
          "body" => "Some content",
          "category" => "pattern"
        })

      %{"data" => %{"id" => article_id}} = json_response(create_conn, 201)

      delete_conn =
        build_conn()
        |> auth_conn(user_key)
        |> delete(~p"/api/v1/articles/#{article_id}")

      refute delete_conn.status == 403
    end

    # AC-26.7.1.12(f) — key-minting bypass is closed
    test "a self-minted orchestrator key is still blocked on custody ops (tier gate keyed on tenant, not role)",
         %{conn: conn} do
      unique = System.unique_integer([:positive])

      signup_conn =
        post(conn, ~p"/api/v1/signup", %{
          "name" => "Bypass Attempt",
          "slug" => "bypass-#{unique}",
          "email" => "bypass-#{unique}@example.com"
        })

      %{"data" => %{"raw_key" => user_key}} = json_response(signup_conn, 201)

      key_conn =
        build_conn()
        |> auth_conn(user_key)
        |> post(~p"/api/v1/api_keys", %{"name" => "escalated-orch", "role" => "orchestrator"})

      %{"api_key" => %{"raw_key" => orch_key}} = json_response(key_conn, 201)

      # The RequireHumanAnchor gate runs before any project lookup, so a
      # bogus project_id is sufficient to prove the tier gate fires first.
      create_conn =
        build_conn()
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/projects/#{Ecto.UUID.generate()}/stories", %{
          "epic_number" => 1,
          "number" => "1.1",
          "title" => "Should be blocked"
        })

      body = json_response(create_conn, 403)
      assert body["error"]["code"] == "custody_tier_required"
    end

    # AC-26.7.1.12(a) / TC-26.7.1.8 — tenant isolation for an agent-rooted tenant
    test "an agent-rooted tenant cannot read another tenant's articles (RLS isolation)",
         %{conn: conn} do
      unique = System.unique_integer([:positive])

      signup_conn =
        post(conn, ~p"/api/v1/signup", %{
          "name" => "Isolation A",
          "slug" => "isolation-a-#{unique}",
          "email" => "isolation-a-#{unique}@example.com"
        })

      %{"data" => %{"raw_key" => key_a}} = json_response(signup_conn, 201)

      tenant_b = fixture(:tenant)
      article_b = fixture(:article, %{tenant_id: tenant_b.id})

      show_conn =
        build_conn()
        |> auth_conn(key_a)
        |> get(~p"/api/v1/articles/#{article_b.id}")

      assert show_conn.status == 404
    end
  end
end
