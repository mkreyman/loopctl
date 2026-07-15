defmodule LoopctlWeb.TenantAuthenticatorControllerTest do
  @moduledoc """
  US-26.7.2 — the opt-in WebAuthn trust-tier upgrade ceremony
  (agent_rooted -> human_anchored) and authenticator revocation. Covers the
  story's test cases TC-26.7.2.1 through TC-26.7.2.7.
  """

  use LoopctlWeb.ConnCase, async: true

  import Loopctl.Fixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Tenants
  alias Loopctl.Tenants.RootAuthenticators
  alias Loopctl.WebAuthn.EnrollmentChallenge

  setup :verify_on_exit!

  # A reauth assertion body (add_authenticator / revoke_authenticator
  # purposes) — mirrors tenant_audit_key_controller_test.exs's shape.
  defp assertion_body(challenge_id, credential_id) do
    %{
      "challenge_id" => challenge_id,
      "credential_id" => Base.url_encode64(credential_id, padding: false),
      "authenticator_data" => Base.url_encode64(:crypto.strong_rand_bytes(37), padding: false),
      "signature" => Base.url_encode64(:crypto.strong_rand_bytes(64), padding: false),
      "client_data_json" => Base.url_encode64(~s({"type":"webauthn.get"}), padding: false)
    }
  end

  # A registration attestation body for POST .../authenticators.
  defp attestation_body(challenge_id, opts \\ []) do
    credential_id = Keyword.get(opts, :credential_id, :crypto.strong_rand_bytes(32))

    base = %{
      "challenge_id" => challenge_id,
      "attestation_object" => Base.url_encode64(:crypto.strong_rand_bytes(64), padding: false),
      "client_data_json" => Base.url_encode64(~s({"type":"webauthn.create"}), padding: false),
      "credential_id" => Base.url_encode64(credential_id, padding: false)
    }

    case Keyword.get(opts, :friendly_name) do
      nil -> base
      name -> Map.put(base, "friendly_name", name)
    end
    |> maybe_put_reauth(Keyword.get(opts, :reauth_assertion))
  end

  defp maybe_put_reauth(body, nil), do: body
  defp maybe_put_reauth(body, assertion), do: Map.put(body, "reauth_assertion", assertion)

  defp authed(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "POST /api/v1/tenants/:id/authenticators/challenge" do
    test "issues a registration challenge for an agent_rooted tenant (no reauth required)", %{
      conn: conn
    } do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, tenant_id: tenant.id, role: :user)

      resp =
        conn
        |> authed(raw_key)
        |> post(~p"/api/v1/tenants/#{tenant.id}/authenticators/challenge", %{})
        |> json_response(200)
        |> Map.fetch!("data")

      assert resp["challenge_id"]
      assert resp["challenge"] != ""
      assert resp["rp"]["id"]
      assert resp["user"]["id"]
      assert resp["pub_key_cred_params"] != []
      assert resp["reauth_required"] == false
      refute Map.has_key?(resp, "reauth_challenge")
    end

    test "includes a reauth challenge when the tenant is already human_anchored", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      auth = fixture(:root_authenticator, tenant_id: tenant.id)
      {raw_key, _} = fixture(:api_key, tenant_id: tenant.id, role: :user)

      resp =
        conn
        |> authed(raw_key)
        |> post(~p"/api/v1/tenants/#{tenant.id}/authenticators/challenge", %{})
        |> json_response(200)
        |> Map.fetch!("data")

      assert resp["reauth_required"] == true
      assert resp["reauth_challenge"]["challenge_id"]

      assert Base.url_encode64(auth.credential_id, padding: false) in resp["reauth_challenge"][
               "allowed_credentials"
             ]
    end

    test "rejects when the caller doesn't own the target tenant", %{conn: conn} do
      tenant_a = fixture(:tenant, %{trust_tier: :agent_rooted})
      tenant_b = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, tenant_id: tenant_a.id, role: :user)

      conn =
        conn
        |> authed(raw_key)
        |> post(~p"/api/v1/tenants/#{tenant_b.id}/authenticators/challenge", %{})

      assert json_response(conn, 403)["error"]["message"] == "Forbidden"
    end

    test "is rate limited", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, tenant_id: tenant.id, role: :user)

      # US-38.2: the inbound RPM plug (LoopctlWeb.Plugs.RateLimiter) now also
      # resolves through the :rate_limiter DI, so it hits this mock first with the
      # "key:"/"tenant:" buckets. Deny ONLY the controller's own "enroll:actions:"
      # bucket so the plug lets the request reach the controller, whose rate-limit
      # check is what we're asserting returns 429 code "rate_limited".
      Mox.stub(Loopctl.MockRateLimiter, :check_rate, fn
        "enroll:actions:" <> _tenant, _window, _limit -> {:deny, 0}
        _bucket, _window, _limit -> {:allow, 1}
      end)

      conn =
        conn
        |> authed(raw_key)
        |> post(~p"/api/v1/tenants/#{tenant.id}/authenticators/challenge", %{})

      assert json_response(conn, 429)["error"]["code"] == "rate_limited"
    end
  end

  describe "POST /api/v1/tenants/:id/authenticators — full round trip (TC-26.7.2.1)" do
    test "self-signup -> 403 on custody op -> enroll -> human_anchored -> custody op passes", %{
      conn: conn
    } do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, tenant_id: tenant.id, role: :user)
      client = authed(conn, raw_key)

      project_params = %{"name" => "First project", "slug" => "first-project"}

      denied = post(client, ~p"/api/v1/projects", project_params)
      assert json_response(denied, 403)["error"]["code"] == "custody_tier_required"

      challenge_data =
        client
        |> post(~p"/api/v1/tenants/#{tenant.id}/authenticators/challenge", %{})
        |> json_response(200)
        |> Map.fetch!("data")

      enroll_resp =
        client
        |> post(
          ~p"/api/v1/tenants/#{tenant.id}/authenticators",
          attestation_body(challenge_data["challenge_id"])
        )
        |> json_response(201)
        |> Map.fetch!("data")

      assert enroll_resp["trust_tier"] == "human_anchored"
      assert enroll_resp["upgraded"] == true
      assert enroll_resp["authenticator"]["friendly_name"] == "Authenticator"

      {:ok, tenant_reloaded} = Tenants.get_tenant(tenant.id)
      assert tenant_reloaded.trust_tier == :human_anchored

      {:ok, entries} =
        Audit.list_entries(tenant.id, entity_type: "tenant", action: "tenant_trust_upgraded")

      assert entries.total == 1

      allowed = post(client, ~p"/api/v1/projects", project_params)
      assert json_response(allowed, 201)
    end
  end

  describe "POST /api/v1/tenants/:id/authenticators — subsequent enrollment gate (TC-26.7.2.2)" do
    setup do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      auth = fixture(:root_authenticator, tenant_id: tenant.id)
      {raw_key, _} = fixture(:api_key, tenant_id: tenant.id, role: :user)
      %{tenant: tenant, auth: auth, raw_key: raw_key}
    end

    test "without the existing-authenticator assertion is rejected 401", %{
      conn: conn,
      tenant: tenant,
      raw_key: raw_key
    } do
      client = authed(conn, raw_key)

      challenge_data =
        client
        |> post(~p"/api/v1/tenants/#{tenant.id}/authenticators/challenge", %{})
        |> json_response(200)
        |> Map.fetch!("data")

      assert challenge_data["reauth_required"] == true

      resp =
        client
        |> post(
          ~p"/api/v1/tenants/#{tenant.id}/authenticators",
          attestation_body(challenge_data["challenge_id"])
        )

      assert json_response(resp, 401)["error"]["code"] == "reauth_required"
      assert RootAuthenticators.count_by_tenant(tenant.id) == 1
    end

    test "with a valid existing-authenticator assertion succeeds and stays human_anchored", %{
      conn: conn,
      tenant: tenant,
      auth: auth,
      raw_key: raw_key
    } do
      client = authed(conn, raw_key)

      challenge_data =
        client
        |> post(~p"/api/v1/tenants/#{tenant.id}/authenticators/challenge", %{})
        |> json_response(200)
        |> Map.fetch!("data")

      reauth_assertion =
        assertion_body(challenge_data["reauth_challenge"]["challenge_id"], auth.credential_id)

      resp =
        client
        |> post(
          ~p"/api/v1/tenants/#{tenant.id}/authenticators",
          attestation_body(challenge_data["challenge_id"], reauth_assertion: reauth_assertion)
        )
        |> json_response(201)
        |> Map.fetch!("data")

      assert resp["trust_tier"] == "human_anchored"
      assert resp["upgraded"] == false
      assert RootAuthenticators.count_by_tenant(tenant.id) == 2

      {:ok, upgraded} =
        Audit.list_entries(tenant.id, entity_type: "tenant", action: "tenant_trust_upgraded")

      assert upgraded.total == 0

      {:ok, enrolled} =
        Audit.list_entries(tenant.id, entity_type: "tenant", action: "authenticator_enrolled")

      assert enrolled.total == 1
    end
  end

  describe "POST /api/v1/tenants/:id/authenticators — forged attestation (TC-26.7.2.3)" do
    test "does not enroll, does not flip the tier, and does not un-burn the challenge", %{
      conn: conn
    } do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, tenant_id: tenant.id, role: :user)
      client = authed(conn, raw_key)

      Mox.expect(Loopctl.MockWebAuthn, :verify_registration, fn _payload, _challenge, _opts ->
        {:error, :invalid_attestation}
      end)

      challenge_data =
        client
        |> post(~p"/api/v1/tenants/#{tenant.id}/authenticators/challenge", %{})
        |> json_response(200)
        |> Map.fetch!("data")

      resp =
        client
        |> post(
          ~p"/api/v1/tenants/#{tenant.id}/authenticators",
          attestation_body(challenge_data["challenge_id"])
        )

      assert json_response(resp, 401)["error"]["code"] == "webauthn_failed"
      assert RootAuthenticators.count_by_tenant(tenant.id) == 0

      {:ok, tenant_reloaded} = Tenants.get_tenant(tenant.id)
      assert tenant_reloaded.trust_tier == :agent_rooted

      {:ok, upgraded} =
        Audit.list_entries(tenant.id, entity_type: "tenant", action: "tenant_trust_upgraded")

      assert upgraded.total == 0

      # Replaying the SAME (already-consumed-in-phase-1) challenge is refused.
      replay =
        client
        |> post(
          ~p"/api/v1/tenants/#{tenant.id}/authenticators",
          attestation_body(challenge_data["challenge_id"])
        )

      assert json_response(replay, 401)["error"]["code"] == "challenge_invalid"
    end
  end

  describe "registration challenge is single-use and TTL-bound (TC-26.7.2.4)" do
    test "replay of an already-consumed challenge_id is rejected", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, tenant_id: tenant.id, role: :user)
      client = authed(conn, raw_key)

      challenge_data =
        client
        |> post(~p"/api/v1/tenants/#{tenant.id}/authenticators/challenge", %{})
        |> json_response(200)
        |> Map.fetch!("data")

      assert client
             |> post(
               ~p"/api/v1/tenants/#{tenant.id}/authenticators",
               attestation_body(challenge_data["challenge_id"])
             )
             |> json_response(201)

      replay =
        client
        |> post(
          ~p"/api/v1/tenants/#{tenant.id}/authenticators",
          attestation_body(challenge_data["challenge_id"])
        )

      assert json_response(replay, 401)["error"]["code"] == "challenge_invalid"
      assert RootAuthenticators.count_by_tenant(tenant.id) == 1
    end

    test "an expired challenge is rejected", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, tenant_id: tenant.id, role: :user)
      client = authed(conn, raw_key)

      challenge_data =
        client
        |> post(~p"/api/v1/tenants/#{tenant.id}/authenticators/challenge", %{})
        |> json_response(200)
        |> Map.fetch!("data")

      AdminRepo.get!(EnrollmentChallenge, challenge_data["challenge_id"])
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      |> AdminRepo.update!()

      resp =
        client
        |> post(
          ~p"/api/v1/tenants/#{tenant.id}/authenticators",
          attestation_body(challenge_data["challenge_id"])
        )

      assert json_response(resp, 401)["error"]["code"] == "challenge_invalid"
      assert RootAuthenticators.count_by_tenant(tenant.id) == 0
    end
  end

  describe "revoke ceremony (TC-26.7.2.5)" do
    test "revoking the last authenticator is refused with 409, no auto-downgrade", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      auth = fixture(:root_authenticator, tenant_id: tenant.id)
      {raw_key, _} = fixture(:api_key, tenant_id: tenant.id, role: :user)
      client = authed(conn, raw_key)

      challenge_data =
        client
        |> post(~p"/api/v1/tenants/#{tenant.id}/authenticators/revoke-challenge", %{})
        |> json_response(200)
        |> Map.fetch!("data")

      resp =
        client
        |> delete(~p"/api/v1/tenants/#{tenant.id}/authenticators/#{auth.id}", %{
          "webauthn_assertion" =>
            assertion_body(challenge_data["challenge_id"], auth.credential_id)
        })

      assert json_response(resp, 409)["error"]["code"] == "last_authenticator"
      assert RootAuthenticators.count_by_tenant(tenant.id) == 1

      {:ok, tenant_reloaded} = Tenants.get_tenant(tenant.id)
      assert tenant_reloaded.trust_tier == :human_anchored
    end

    test "revoking a non-last authenticator succeeds", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      auth_a = fixture(:root_authenticator, tenant_id: tenant.id)
      auth_b = fixture(:root_authenticator, tenant_id: tenant.id)
      {raw_key, _} = fixture(:api_key, tenant_id: tenant.id, role: :user)
      client = authed(conn, raw_key)

      challenge_data =
        client
        |> post(~p"/api/v1/tenants/#{tenant.id}/authenticators/revoke-challenge", %{})
        |> json_response(200)
        |> Map.fetch!("data")

      resp =
        client
        |> delete(~p"/api/v1/tenants/#{tenant.id}/authenticators/#{auth_b.id}", %{
          "webauthn_assertion" =>
            assertion_body(challenge_data["challenge_id"], auth_a.credential_id)
        })
        |> json_response(200)
        |> Map.fetch!("data")

      assert resp["revoked"] == true
      assert RootAuthenticators.count_by_tenant(tenant.id) == 1
    end

    test "missing assertion is rejected 401", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      auth_a = fixture(:root_authenticator, tenant_id: tenant.id)
      fixture(:root_authenticator, tenant_id: tenant.id)
      {raw_key, _} = fixture(:api_key, tenant_id: tenant.id, role: :user)

      resp =
        conn
        |> authed(raw_key)
        |> delete(~p"/api/v1/tenants/#{tenant.id}/authenticators/#{auth_a.id}", %{})

      assert json_response(resp, 401)["error"]["code"] == "webauthn_required"
    end
  end

  describe "cross-tenant isolation (TC-26.7.2.6)" do
    test "every action 403s when the caller doesn't own the target tenant", %{conn: conn} do
      tenant_a = fixture(:tenant, %{trust_tier: :agent_rooted})
      tenant_b = fixture(:tenant, %{trust_tier: :human_anchored})
      auth_b = fixture(:root_authenticator, tenant_id: tenant_b.id)
      {raw_key, _} = fixture(:api_key, tenant_id: tenant_a.id, role: :user)
      client = authed(conn, raw_key)

      assert client
             |> post(~p"/api/v1/tenants/#{tenant_b.id}/authenticators/challenge", %{})
             |> json_response(403)

      assert client
             |> post(~p"/api/v1/tenants/#{tenant_b.id}/authenticators", %{
               "challenge_id" => Ecto.UUID.generate()
             })
             |> json_response(403)

      assert client
             |> post(~p"/api/v1/tenants/#{tenant_b.id}/authenticators/revoke-challenge", %{})
             |> json_response(403)

      assert client
             |> delete(~p"/api/v1/tenants/#{tenant_b.id}/authenticators/#{auth_b.id}", %{
               "webauthn_assertion" => assertion_body(Ecto.UUID.generate(), auth_b.credential_id)
             })
             |> json_response(403)

      assert RootAuthenticators.count_by_tenant(tenant_b.id) == 1
    end
  end

  describe "credential_id uniqueness (AC-26.7.2.8i)" do
    test "re-enrolling the same credential_id for a tenant is rejected 422", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, tenant_id: tenant.id, role: :user)
      client = authed(conn, raw_key)
      credential_id = :crypto.strong_rand_bytes(32)

      challenge_1 =
        client
        |> post(~p"/api/v1/tenants/#{tenant.id}/authenticators/challenge", %{})
        |> json_response(200)
        |> Map.fetch!("data")

      assert client
             |> post(
               ~p"/api/v1/tenants/#{tenant.id}/authenticators",
               attestation_body(challenge_1["challenge_id"], credential_id: credential_id)
             )
             |> json_response(201)

      challenge_2 =
        client
        |> post(~p"/api/v1/tenants/#{tenant.id}/authenticators/challenge", %{})
        |> json_response(200)
        |> Map.fetch!("data")

      resp =
        client
        |> post(
          ~p"/api/v1/tenants/#{tenant.id}/authenticators",
          attestation_body(challenge_2["challenge_id"],
            credential_id: credential_id,
            reauth_assertion:
              assertion_body(challenge_2["reauth_challenge"]["challenge_id"], credential_id)
          )
        )

      assert json_response(resp, 422)["error"]["message"]
      assert RootAuthenticators.count_by_tenant(tenant.id) == 1
    end
  end

  describe "revoke-challenge action" do
    test "422s when the tenant has no enrolled authenticator", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, tenant_id: tenant.id, role: :user)

      resp =
        conn
        |> authed(raw_key)
        |> post(~p"/api/v1/tenants/#{tenant.id}/authenticators/revoke-challenge", %{})

      assert json_response(resp, 422)["error"]["code"] == "no_authenticators"
    end

    test "is rate limited", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      fixture(:root_authenticator, tenant_id: tenant.id)
      {raw_key, _} = fixture(:api_key, tenant_id: tenant.id, role: :user)

      # US-38.2: the inbound RPM plug (LoopctlWeb.Plugs.RateLimiter) now also
      # resolves through the :rate_limiter DI, so it hits this mock first with the
      # "key:"/"tenant:" buckets. Deny ONLY the controller's own "enroll:actions:"
      # bucket so the plug lets the request reach the controller, whose rate-limit
      # check is what we're asserting returns 429 code "rate_limited".
      Mox.stub(Loopctl.MockRateLimiter, :check_rate, fn
        "enroll:actions:" <> _tenant, _window, _limit -> {:deny, 0}
        _bucket, _window, _limit -> {:allow, 1}
      end)

      resp =
        conn
        |> authed(raw_key)
        |> post(~p"/api/v1/tenants/#{tenant.id}/authenticators/revoke-challenge", %{})

      assert json_response(resp, 429)["error"]["code"] == "rate_limited"
    end
  end

  describe "enroll action rate limiting (AC-26.7.2.7)" do
    test "over-budget create is rejected 429", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, tenant_id: tenant.id, role: :user)

      # US-38.2: the inbound RPM plug (LoopctlWeb.Plugs.RateLimiter) now also
      # resolves through the :rate_limiter DI, so it hits this mock first with the
      # "key:"/"tenant:" buckets. Deny ONLY the controller's own "enroll:actions:"
      # bucket so the plug lets the request reach the controller, whose rate-limit
      # check is what we're asserting returns 429 code "rate_limited".
      Mox.stub(Loopctl.MockRateLimiter, :check_rate, fn
        "enroll:actions:" <> _tenant, _window, _limit -> {:deny, 0}
        _bucket, _window, _limit -> {:allow, 1}
      end)

      resp =
        conn
        |> authed(raw_key)
        |> post(~p"/api/v1/tenants/#{tenant.id}/authenticators", %{
          "challenge_id" => Ecto.UUID.generate()
        })

      assert json_response(resp, 429)["error"]["code"] == "rate_limited"
    end
  end

  describe "friendly_name validation (AC-26.7.2.3, review #3)" do
    test "an over-120-byte friendly_name is REJECTED 422, not silently truncated", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, tenant_id: tenant.id, role: :user)
      client = authed(conn, raw_key)

      challenge =
        client
        |> post(~p"/api/v1/tenants/#{tenant.id}/authenticators/challenge", %{})
        |> json_response(200)
        |> Map.fetch!("data")

      resp =
        client
        |> post(
          ~p"/api/v1/tenants/#{tenant.id}/authenticators",
          attestation_body(challenge["challenge_id"], friendly_name: String.duplicate("a", 121))
        )

      assert json_response(resp, 422)["error"]["code"] == "friendly_name_too_long"
      # Nothing was enrolled and the tier did NOT flip.
      assert RootAuthenticators.count_by_tenant(tenant.id) == 0
      {:ok, reloaded} = Tenants.get_tenant(tenant.id)
      assert reloaded.trust_tier == :agent_rooted
    end

    test "a 120-byte friendly_name is accepted VERBATIM (proves no truncation)", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, tenant_id: tenant.id, role: :user)
      client = authed(conn, raw_key)

      challenge =
        client
        |> post(~p"/api/v1/tenants/#{tenant.id}/authenticators/challenge", %{})
        |> json_response(200)
        |> Map.fetch!("data")

      name = String.duplicate("b", 120)

      resp =
        client
        |> post(
          ~p"/api/v1/tenants/#{tenant.id}/authenticators",
          attestation_body(challenge["challenge_id"], friendly_name: name)
        )
        |> json_response(201)
        |> Map.fetch!("data")

      assert resp["authenticator"]["friendly_name"] == name
    end
  end

  # review #1 regression: the residual double-first-enroll race, at the HTTP
  # layer. Two concurrent POST .../authenticators against an agent_rooted
  # tenant, BOTH with NO reauth_assertion (both are first-enroll attempts).
  # Exactly one must 201 (flip to human_anchored + enroll); the loser must be
  # rejected 401 reauth_required by the under-lock gate — it must NOT get a
  # 201 grafting a second, possession-unproven device.
  describe "concurrent double-first-enroll at the HTTP layer (review #1)" do
    @tag :capture_log
    test "exactly one 201; the loser gets 401 reauth_required, never 201", %{conn: _conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, tenant_id: tenant.id, role: :user)

      # Two independent single-use challenges, issued sequentially before the race.
      issue_challenge = fn ->
        build_conn()
        |> authed(raw_key)
        |> post(~p"/api/v1/tenants/#{tenant.id}/authenticators/challenge", %{})
        |> json_response(200)
        |> Map.fetch!("data")
        |> Map.fetch!("challenge_id")
      end

      challenge_a = issue_challenge.()
      challenge_b = issue_challenge.()

      parent = self()

      fire = fn challenge_id ->
        Task.async(fn ->
          Sandbox.allow(Loopctl.Repo, parent, self())
          Sandbox.allow(Loopctl.AdminRepo, parent, self())
          Mox.allow(Loopctl.MockWebAuthn, parent, self())
          Mox.allow(Loopctl.MockRateLimiter, parent, self())

          build_conn()
          |> authed(raw_key)
          |> post(
            ~p"/api/v1/tenants/#{tenant.id}/authenticators",
            attestation_body(challenge_id)
          )
        end)
      end

      task_a = fire.(challenge_a)
      task_b = fire.(challenge_b)

      result_a = Task.await(task_a, 10_000)
      result_b = Task.await(task_b, 10_000)

      assert Enum.sort([result_a.status, result_b.status]) == [201, 401]

      loser = Enum.find([result_a, result_b], &(&1.status == 401))
      assert Jason.decode!(loser.resp_body)["error"]["code"] == "reauth_required"

      # Exactly ONE device was grafted on; the tenant is human_anchored with a
      # single upgrade entry.
      assert RootAuthenticators.count_by_tenant(tenant.id) == 1
      {:ok, reloaded} = Tenants.get_tenant(tenant.id)
      assert reloaded.trust_tier == :human_anchored

      {:ok, upgraded} =
        Audit.list_entries(tenant.id, entity_type: "tenant", action: "tenant_trust_upgraded")

      assert upgraded.total == 1
    end
  end
end
