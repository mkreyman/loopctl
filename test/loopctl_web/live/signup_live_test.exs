defmodule LoopctlWeb.SignupLiveTest do
  @moduledoc """
  US-26.0.1 — LiveView / controller-level coverage for the tenant
  signup ceremony. Uses the `Loopctl.MockWebAuthn` stub wired in via
  `config/test.exs`.

  Covers TC-26.0.1.2, TC-26.0.1.6, TC-26.0.1.7.
  """

  use LoopctlWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Loopctl.AdminRepo
  alias Loopctl.Tenants.Tenant

  setup :verify_on_exit!

  describe "GET /signup (TC-26.0.1.7)" do
    test "renders with design-system classes and no daisyUI", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/signup")

      # Form elements present
      assert html =~ ~s(id="signup-form")
      assert html =~ ~s(id="tenant-name-input")
      assert html =~ ~s(id="tenant-slug-input")
      assert html =~ ~s(id="tenant-email-input")
      assert html =~ ~s(id="enroll-authenticator-btn")
      assert html =~ ~s(id="signup-submit-btn")

      # Design system classes
      assert html =~ "slate-"
      assert html =~ "rounded-md"
      assert html =~ "font-body"

      # Hero icon marker for the hardware-key prompt
      assert html =~ ~s(data-icon="hero-key")

      # Learn-more link to the reserved wiki slug
      assert html =~ "/wiki/tenant-signup"

      # Anti-patterns from docs/design-system.md are absent
      refute html =~ "rounded-xl"
      refute html =~ "gradient-"
      refute html =~ "bg-gradient"

      # daisyUI classes that must not appear
      refute html =~ ~s(class="card)
      refute html =~ "btn-primary"
      refute html =~ ~s(class="alert)
    end

    test "form is accessible via has_element?", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")
      assert has_element?(view, "#signup-form")
      assert has_element?(view, "#webauthn-hook")
      assert has_element?(view, "#signup-learn-more")
    end

    test "#494: the DEAD render carries the root layout (head + assets) so WebAuthn JS loads", %{
      conn: conn
    } do
      # The plain HTTP (disconnected) response — NOT the connected socket render `live/2`
      # exercises. Before #494 the :browser pipeline had no put_root_layout, so this came
      # back bare: no <!DOCTYPE>, no <head>, and app.js never loaded — bricking the ceremony.
      html = conn |> get(~p"/signup") |> html_response(200)

      assert html =~ "<!DOCTYPE html>"
      assert html =~ "<head>"
      # app.js runs the LiveView socket AND the WebAuthn credential hook.
      assert html =~ "/assets/app.js"
      assert html =~ "/assets/app.css"
      # The LiveView content is present inside that layout.
      assert html =~ ~s(id="signup-page")
    end
  end

  describe "WebAuthn enrollment round-trip" do
    test "valid attestation appends an enrolled authenticator", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      # Name the authenticator via form validate (form attribute wires
      # the enrollment input into the main signup-form change event).
      view
      |> element("#signup-form")
      |> render_change(%{
        "tenant" => %{"name" => "", "slug" => "", "email" => ""},
        "friendly_name" => "Primary YubiKey"
      })

      # Kick off the attestation request (server-side issues a fresh
      # challenge; the hook normally responds via push_event, but in
      # tests we skip straight to attestation_captured with stub bytes).
      view
      |> element("#enroll-authenticator-btn")
      |> render_click()

      # The Mox stub returns an {:ok, attestation_result} regardless of
      # the decoded bytes we send — so any base64url-safe non-empty
      # values suffice.
      render_hook(view, "attestation_captured", %{
        "attestation_object" => "YWJjZA",
        "client_data_json" => "eyJmb28iOiJiYXIifQ",
        "credential_id" => "Y3JlZC1pZA"
      })

      assert has_element?(view, "#authenticator-0")
      assert render(view) =~ "Primary YubiKey"
    end

    test "invalid attestation surfaces inline error and creates no tenant (TC-26.0.1.2)",
         %{conn: conn} do
      # Override the default stub to fail verification for this test.
      stub(Loopctl.MockWebAuthn, :verify_registration, fn _payload, _challenge, _opts ->
        {:error, :invalid_attestation}
      end)

      {:ok, view, _html} = live(conn, ~p"/signup")

      view
      |> element("#signup-form")
      |> render_change(%{
        "tenant" => %{"name" => "", "slug" => "", "email" => ""},
        "friendly_name" => "Broken Key"
      })

      view |> element("#enroll-authenticator-btn") |> render_click()

      html =
        render_hook(view, "attestation_captured", %{
          "attestation_object" => "YWJjZA",
          "client_data_json" => "eyJmb28iOiJiYXIifQ",
          "credential_id" => "Y3JlZC1pZA"
        })

      assert html =~ "Invalid attestation"
    end

    test "rejects signup with no enrolled authenticators", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      html =
        view
        |> form("#signup-form", %{
          "tenant" => %{
            "name" => "Skippy",
            "slug" => "skippy",
            "email" => "skippy@example.com"
          }
        })
        |> render_submit()

      assert html =~ "Enroll at least one"
      refute AdminRepo.get_by(Tenant, slug: "skippy")
    end

    test "successful signup surfaces the root API key once + a continue-to-onboarding link (#500)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      view
      |> element("#signup-form")
      |> render_change(%{
        "tenant" => %{"name" => "", "slug" => "", "email" => ""},
        "friendly_name" => "Primary"
      })

      view |> element("#enroll-authenticator-btn") |> render_click()

      render_hook(view, "attestation_captured", %{
        "attestation_object" => "YWJjZA",
        "client_data_json" => "eyJmb28iOiJiYXIifQ",
        "credential_id" => "Y3JlZC1pZA"
      })

      # #500: no redirect — the raw key is shown once in-page (never a URL / the session).
      html =
        view
        |> form("#signup-form", %{
          "tenant" => %{
            "name" => "Successful Corp",
            "slug" => "successful-corp",
            "email" => "admin@successful.example"
          }
        })
        |> render_submit()

      assert has_element?(view, "#signup-complete")
      assert has_element?(view, "#root-api-key")
      # The continue link carries the onboarding path (with the signed token); no key in the URL.
      assert has_element?(view, "#continue-to-onboarding")
      refute html =~ "signup-form"

      tenant = AdminRepo.get_by(Tenant, slug: "successful-corp")
      assert tenant

      # #500: a real, usable root user-role key was minted for the new tenant.
      key = AdminRepo.get_by(Loopctl.Auth.ApiKey, tenant_id: tenant.id, role: :user)
      assert key
      assert is_nil(key.agent_id)
      # The rendered key must be the actual minted key (its prefix is stored).
      assert html =~ key.key_prefix
    end

    test "audit-key storage failure surfaces a banner and creates no tenant, not a crash (#496)",
         %{conn: conn} do
      # Off Fly with no local adapter, Secrets.set fails; the signup multi rolls back.
      stub(Loopctl.MockSecrets, :set, fn _name, _value -> {:error, :fly_not_configured} end)

      {:ok, view, _html} = live(conn, ~p"/signup")

      view |> element("#enroll-authenticator-btn") |> render_click()

      render_hook(view, "attestation_captured", %{
        "attestation_object" => "YWJjZA",
        "client_data_json" => "eyJmb28iOiJiYXIifQ",
        "credential_id" => "Y3JlZC1pZA"
      })

      html =
        view
        |> form("#signup-form", %{
          "tenant" => %{
            "name" => "Offline Corp",
            "slug" => "offline-corp",
            "email" => "admin@offline.example"
          }
        })
        |> render_submit()

      # Actionable banner (the old behaviour was a CaseClauseError crash / dead button).
      assert html =~ "SECRETS_ADAPTER=local_file"
      refute has_element?(view, "#signup-complete")
      refute AdminRepo.get_by(Tenant, slug: "offline-corp")
    end

    test "duplicate slug surfaces a stable error code (TC-26.0.1.3 via LV)", %{conn: conn} do
      fixture(:tenant, %{slug: "taken-slug"})

      {:ok, view, _html} = live(conn, ~p"/signup")

      view
      |> element("#signup-form")
      |> render_change(%{
        "tenant" => %{"name" => "", "slug" => "", "email" => ""},
        "friendly_name" => "Primary"
      })

      view |> element("#enroll-authenticator-btn") |> render_click()

      render_hook(view, "attestation_captured", %{
        "attestation_object" => "YWJjZA",
        "client_data_json" => "eyJmb28iOiJiYXIifQ",
        "credential_id" => "Y3JlZC1pZA"
      })

      html =
        view
        |> form("#signup-form", %{
          "tenant" => %{
            "name" => "Duplicate Corp",
            "slug" => "taken-slug",
            "email" => "dup@example.com"
          }
        })
        |> render_submit()

      assert html =~ "slug is already in use"
    end
  end

  describe "signup rate limiting (web-01, session Fly-Client-IP, spoof-resistant)" do
    test "REAL Fly shape: fly-client-ip resolves to the client, NOT the app IP Fly appends to XFF",
         %{conn: conn} do
      test_pid = self()
      stub(Loopctl.MockRateLimiter, :check_rate, capture_bucket(test_pid))

      # Exactly the shape the gate said the old code collapsed on: Fly appends
      # the app-assigned IP as the rightmost X-Forwarded-For entry. Resolving via
      # fly-client-ip (unspoofable) keys on the real client, never the app IP.
      conn = fly_conn(conn, "203.0.113.7", xff: "203.0.113.7, 66.241.125.10")

      # Page loads must NOT consume the bucket.
      for _ <- 1..5 do
        {:ok, _view, _html} = live(conn, ~p"/signup")
      end

      refute_received {:bucket, _}

      {:ok, view, _html} = live(conn, ~p"/signup")
      enroll_authenticator(view)
      submit_tenant(view, "Fly Corp", "fly-corp", "fly@corp.example")

      assert_receive {:bucket, bucket}
      assert bucket == "signup:ip:203.0.113.7"
      # The app IP Fly appends to XFF must never become the bucket key.
      refute bucket == "signup:ip:66.241.125.10"
    end

    test "two different real clients get two different buckets (no collapse to the app IP)",
         %{conn: conn} do
      test_pid = self()
      stub(Loopctl.MockRateLimiter, :check_rate, capture_bucket(test_pid))

      {:ok, view1, _html} =
        live(fly_conn(conn, "203.0.113.7", xff: "203.0.113.7, 66.241.125.10"), ~p"/signup")

      enroll_authenticator(view1)
      submit_tenant(view1, "Corp A", "corp-a", "a@corp.example")
      assert_receive {:bucket, "signup:ip:203.0.113.7"}

      {:ok, view2, _html} =
        live(fly_conn(conn, "203.0.113.9", xff: "203.0.113.9, 66.241.125.10"), ~p"/signup")

      enroll_authenticator(view2)
      submit_tenant(view2, "Corp B", "corp-b", "b@corp.example")
      assert_receive {:bucket, "signup:ip:203.0.113.9"}
    end

    test "a client-forged x-forwarded-for cannot override the fly-client-ip client",
         %{conn: conn} do
      test_pid = self()
      stub(Loopctl.MockRateLimiter, :check_rate, capture_bucket(test_pid))

      # fly-proxy overwrites fly-client-ip with the real client; the attacker's
      # forged XFF (incl. the reserved-suffix trick that broke the old code) is
      # never consulted for the bucket.
      conn = fly_conn(conn, "203.0.113.7", xff: "9.9.9.9, 127.0.0.1")

      {:ok, view, _html} = live(conn, ~p"/signup")
      enroll_authenticator(view)
      submit_tenant(view, "Forged Corp", "forged-corp", "forged@corp.example")

      assert_receive {:bucket, bucket}
      assert bucket == "signup:ip:203.0.113.7"
      refute bucket == "signup:ip:9.9.9.9"
    end

    test "one IP hitting the limit does not lock out a different IP", %{conn: conn} do
      stub(Loopctl.MockRateLimiter, :check_rate, fn
        "signup:ip:203.0.113.1", _window, _limit -> {:deny, 5}
        _bucket, _window, _limit -> {:allow, 1}
      end)

      {:ok, abuser_view, _html} = live(fly_conn(conn, "203.0.113.1"), ~p"/signup")
      enroll_authenticator(abuser_view)
      abuser_html = submit_tenant(abuser_view, "Abuser", "abuser-corp", "abuser@corp.example")

      assert abuser_html =~ "Too many signup attempts"
      refute AdminRepo.get_by(Tenant, slug: "abuser-corp")

      # A different IP is unaffected — signup still completes.
      {:ok, victim_view, _html} = live(fly_conn(conn, "203.0.113.9"), ~p"/signup")
      enroll_authenticator(victim_view)

      victim_view
      |> form("#signup-form", %{
        "tenant" => %{
          "name" => "Victim Corp",
          "slug" => "victim-corp",
          "email" => "victim@corp.example"
        }
      })
      |> render_submit()

      # #500: success now surfaces the one-time key panel in-page (no redirect).
      assert has_element?(victim_view, "#signup-complete")
      assert has_element?(victim_view, "#continue-to-onboarding")
      assert AdminRepo.get_by(Tenant, slug: "victim-corp")
    end

    test "off Fly (no fly-client-ip): falls back to conn.remote_ip from x-forwarded-for",
         %{conn: conn} do
      test_pid = self()
      stub(Loopctl.MockRateLimiter, :check_rate, capture_bucket(test_pid))

      # No fly-client-ip header; the HTTP-pipeline RemoteIp plug resolves
      # conn.remote_ip from X-Forwarded-For (e.g. an nginx front end).
      {:ok, view, _html} = live(xff_conn(conn, "203.0.113.20"), ~p"/signup")
      enroll_authenticator(view)
      submit_tenant(view, "Nginx Corp", "nginx-corp", "nginx@corp.example")

      assert_receive {:bucket, "signup:ip:203.0.113.20"}
    end

    # The signed-session resolver is a plain public function; exercise its edge
    # cases directly (the LiveViewTest adapter always injects a loopback peer, so
    # the truly-unresolvable branch can't be reached through `live/2`).
    test "signup_session/1 yields a nil client_ip when nothing is resolvable" do
      # nil -> mount's signup_rate_key/2 falls back to signup:session:<id>,
      # never a shared bucket.
      bare = %Plug.Conn{remote_ip: nil, req_headers: []}
      assert LoopctlWeb.SignupLive.signup_session(bare) == %{"client_ip" => nil}
    end

    test "signup_session/1 prefers fly-client-ip over a forged x-forwarded-for and the peer" do
      conn =
        %Plug.Conn{remote_ip: {10, 0, 0, 9}, req_headers: []}
        |> Plug.Conn.put_req_header("fly-client-ip", "203.0.113.7")
        |> Plug.Conn.put_req_header("x-forwarded-for", "9.9.9.9, 66.241.125.10")

      assert LoopctlWeb.SignupLive.signup_session(conn) == %{"client_ip" => "203.0.113.7"}
    end

    test "signup_session/1 normalizes an IPv4-mapped IPv6 peer to plain IPv4" do
      # ::ffff:203.0.113.7 (how Bandit surfaces IPv4 peers on a dual-stack bind).
      conn = %Plug.Conn{remote_ip: {0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7107}, req_headers: []}
      assert LoopctlWeb.SignupLive.signup_session(conn) == %{"client_ip" => "203.0.113.7"}
    end

    test "signup_session/1 returns nil for a PROXY peer with no forwarded header" do
      # No fly-client-ip / XFF; the raw peer is a configured proxy (198.51.100.0/24
      # in test). Keying on it would collapse every visitor onto one bucket, so it
      # returns nil -> signup_rate_key/2 uses the per-connection bucket.
      conn = %Plug.Conn{remote_ip: {198, 51, 100, 50}, req_headers: []}
      assert LoopctlWeb.SignupLive.signup_session(conn) == %{"client_ip" => nil}
    end

    test "signup_session/1 uses a PUBLIC (non-proxy) peer as the visitor identity" do
      conn = %Plug.Conn{remote_ip: {203, 0, 113, 7}, req_headers: []}
      assert LoopctlWeb.SignupLive.signup_session(conn) == %{"client_ip" => "203.0.113.7"}
    end
  end

  describe "attestation verification is protected server-side (web-01 expensive path)" do
    test "attestation_captured enforces the authenticator cap even when the UI gate is skipped",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")
      max = Loopctl.Tenants.max_authenticators_per_signup()

      # Skip request_attestation and spam attestation_captured straight over the
      # socket, as an attacker would. The cap must hold server-side.
      for _ <- 1..(max + 5) do
        render_hook(view, "attestation_captured", valid_attestation())
      end

      assert has_element?(view, "#authenticator-#{max - 1}")
      refute has_element?(view, "#authenticator-#{max}")
    end

    test "attestation_captured rejects an oversized payload before decoding", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      html =
        render_hook(view, "attestation_captured", %{
          "attestation_object" => String.duplicate("A", 9_000),
          "client_data_json" => "eyJmb28iOiJiYXIifQ",
          "credential_id" => "Y3JlZC1pZA"
        })

      assert html =~ "Attestation payload too large"
      refute has_element?(view, "#authenticator-0")
    end

    test "attestation_captured is rate-limited so a burst cannot pin the scheduler",
         %{conn: conn} do
      stub(Loopctl.MockRateLimiter, :check_rate, fn
        "signup:webauthn:" <> _rest, _w, _l -> {:deny, 20}
        _bucket, _w, _l -> {:allow, 1}
      end)

      {:ok, view, _html} = live(conn, ~p"/signup")

      html = render_hook(view, "attestation_captured", valid_attestation())

      assert html =~ "Too many verification attempts"
      refute has_element?(view, "#authenticator-0")
    end

    test "a non-map attestation_captured payload is a no-op and does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      render_hook(view, "attestation_captured", ["not", "a", "map"])

      refute has_element?(view, "#authenticator-0")
      assert has_element?(view, "#signup-form")
    end

    test "a non-map request_attestation payload is a no-op and does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      render_hook(view, "request_attestation", ["not", "a", "map"])

      assert has_element?(view, "#signup-form")
    end
  end

  describe "malformed websocket events (web-02, no crash)" do
    test "remove_authenticator with a non-parseable index is a no-op and does not crash",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")
      enroll_authenticator(view)

      assert has_element?(view, "#authenticator-0")

      render_hook(view, "remove_authenticator", %{"index" => "x"})

      # Process is still alive and the entry is untouched.
      assert has_element?(view, "#authenticator-0")
    end

    test "remove_authenticator with a non-binary index is a no-op and does not crash",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")
      enroll_authenticator(view)

      render_hook(view, "remove_authenticator", %{"index" => 3})

      assert has_element?(view, "#authenticator-0")
    end

    test "remove_authenticator with a non-map payload is a no-op and does not crash",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")
      enroll_authenticator(view)

      render_hook(view, "remove_authenticator", ["not", "a", "map"])

      assert has_element?(view, "#authenticator-0")
    end

    test "remove_authenticator with an out-of-range index is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")
      enroll_authenticator(view)

      render_hook(view, "remove_authenticator", %{"index" => "5"})

      assert has_element?(view, "#authenticator-0")
    end

    test "remove_authenticator with a missing index key is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")
      enroll_authenticator(view)

      render_hook(view, "remove_authenticator", %{})

      assert has_element?(view, "#authenticator-0")
    end

    test "a valid remove_authenticator still removes the right entry", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")
      enroll_authenticator(view, "First Key")
      enroll_authenticator(view, "Second Key")

      assert has_element?(view, "#authenticator-0")
      assert has_element?(view, "#authenticator-1")

      # Remove the first entry; the second slides into index 0.
      render_hook(view, "remove_authenticator", %{"index" => "0"})

      html = render(view)
      refute has_element?(view, "#authenticator-1")
      assert has_element?(view, "#authenticator-0")
      assert html =~ "Second Key"
      refute html =~ "First Key"
    end

    test "attestation_error without a reason key is a no-op and does not crash",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      render_hook(view, "attestation_error", %{})

      # Alive and no error surfaced from the malformed frame.
      refute has_element?(view, "#signup-error")
      assert has_element?(view, "#signup-form")
    end

    test "a non-map attestation_error payload is a no-op and does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      render_hook(view, "attestation_error", ["boom"])

      assert has_element?(view, "#signup-form")
    end

    test "a known attestation_error reason still surfaces its message", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      html = render_hook(view, "attestation_error", %{"reason" => "webauthn_unsupported"})

      assert html =~ "does not support WebAuthn"
    end

    test "an entirely unknown event is ignored and does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      render_hook(view, "totally_bogus_event", %{"junk" => true})

      assert has_element?(view, "#signup-form")
    end
  end

  describe "legacy tenant creation paths (TC-26.0.1.6)" do
    test "POST /api/v1/tenants/register returns 404", %{conn: conn} do
      conn =
        post(conn, "/api/v1/tenants/register", %{
          "name" => "Legacy",
          "slug" => "legacy",
          "email" => "legacy@example.com"
        })

      assert conn.status in [404, 403]
    end

    test "POST /api/v1/admin/tenants returns 404", %{conn: conn} do
      conn =
        post(conn, "/api/v1/admin/tenants", %{
          "name" => "Legacy Admin",
          "slug" => "legacy-admin",
          "email" => "legacy-admin@example.com"
        })

      assert conn.status in [404, 403, 401]
    end

    test "GET /api/v1/admin/tenants is still an admin-only read", %{conn: conn} do
      # Sanity-check that the admin read path still exists (unauthenticated request).
      conn = get(conn, "/api/v1/admin/tenants")
      assert conn.status in [401, 403]
    end
  end

  describe "input validation for WebAuthn handlers (web-02 regression, from master)" do
    test "remove_authenticator gracefully handles non-integer index", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      view
      |> element("#signup-form")
      |> render_change(%{
        "tenant" => %{"name" => "", "slug" => "", "email" => ""},
        "friendly_name" => "Primary"
      })

      view |> element("#enroll-authenticator-btn") |> render_click()

      render_hook(view, "attestation_captured", %{
        "attestation_object" => "YWJjZA",
        "client_data_json" => "eyJmb28iOiJiYXIifQ",
        "credential_id" => "Y3JlZC1pZA"
      })

      # Try to remove with an invalid index (non-numeric string)
      # Should not crash; authenticator list should remain unchanged
      html = render_hook(view, "remove_authenticator", %{"index" => "not-a-number"})
      assert html =~ "Primary"
      assert has_element?(view, "#authenticator-0")
    end

    test "remove_authenticator gracefully handles negative index", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      view
      |> element("#signup-form")
      |> render_change(%{
        "tenant" => %{"name" => "", "slug" => "", "email" => ""},
        "friendly_name" => "First"
      })

      view |> element("#enroll-authenticator-btn") |> render_click()

      render_hook(view, "attestation_captured", %{
        "attestation_object" => "YWJjZA",
        "client_data_json" => "eyJmb28iOiJiYXIifQ",
        "credential_id" => "Y3JlZC1pZA"
      })

      # Try to remove with a negative index
      # Should not crash; authenticator list should remain unchanged
      html = render_hook(view, "remove_authenticator", %{"index" => "-1"})
      assert html =~ "First"
      assert has_element?(view, "#authenticator-0")
    end

    test "attestation_error gracefully handles non-string reason", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      # Send an attestation_error with a numeric reason instead of string
      # Should not crash; should use a safe default message
      html = render_hook(view, "attestation_error", %{"reason" => 123})
      assert html =~ "Authenticator ceremony failed"
    end

    test "attestation_error gracefully handles nil reason", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      # Send an attestation_error with a nil reason
      # Should not crash; should use a safe default message
      html = render_hook(view, "attestation_error", %{"reason" => nil})
      assert html =~ "Authenticator ceremony failed"
    end
  end

  describe "DoS regression tests (final three vectors: friendly_name, reason, XFF order)" do
    test "request_attestation rejects an oversized friendly_name (8MB attack) before use",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      # Send 8MB friendly_name (Bandit's default max_frame_size)
      view
      |> element("#signup-form")
      |> render_change(%{
        "tenant" => %{"name" => "", "slug" => "", "email" => ""},
        "friendly_name" => String.duplicate("A", 8 * 1024 * 1024)
      })

      # View should still be alive and no authenticator should be created
      assert has_element?(view, "#signup-form")
    end

    test "request_attestation caps friendly_name to @max_friendly_name_bytes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      # Send a 1000-byte friendly_name (well above the 200-byte cap)
      large_name = String.duplicate("X", 1000)

      view
      |> element("#signup-form")
      |> render_change(%{
        "tenant" => %{"name" => "", "slug" => "", "email" => ""},
        "friendly_name" => large_name
      })

      view |> element("#enroll-authenticator-btn") |> render_click()

      # Capture attestation with the oversized name
      render_hook(view, "attestation_captured", %{
        "attestation_object" => "YWJjZA",
        "client_data_json" => "eyJmb28iOiJiYXIifQ",
        "credential_id" => "Y3JlZC1pZA"
      })

      # Authenticator should be enrolled, but name should be truncated
      html = render(view)
      assert has_element?(view, "#authenticator-0")
      # The full 1000-byte name should NOT appear in the rendered output
      refute html =~ String.duplicate("X", 200)
    end

    test "attestation_error caps an 8MB reason before logging and draws the action budget",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      # An 8MB reason (Bandit's default max_frame_size). It must never be
      # inspected/logged in full — safe_reason/1 truncates it — and the process
      # must stay alive and surface the generic message.
      html =
        render_hook(view, "attestation_error", %{
          "reason" => String.duplicate("E", 8 * 1024 * 1024)
        })

      assert html =~ "Authenticator ceremony failed"
      assert has_element?(view, "#signup-form")
    end

    test "attestation_error is bounded by the shared per-connection action budget",
         %{conn: conn} do
      # When the shared action budget is exhausted, attestation_error stops
      # doing work (no logging) and reports the throttle message.
      stub(Loopctl.MockRateLimiter, :check_rate, fn
        "signup:actions:" <> _rest, _w, _l -> {:deny, 60}
        _bucket, _w, _l -> {:allow, 1}
      end)

      {:ok, view, _html} = live(conn, ~p"/signup")

      html = render_hook(view, "attestation_error", %{"reason" => "webauthn_unsupported"})

      assert html =~ "Too many attempts"
    end

    test "request_attestation draws the shared per-connection action budget", %{conn: conn} do
      # request_attestation draws the SHARED "signup:actions:" budget (so no
      # single handler is an unrated amplifier). Deny it and the handler reports
      # the rate-limit message.
      stub(Loopctl.MockRateLimiter, :check_rate, fn
        "signup:actions:" <> _rest, _w, _l -> {:deny, 60}
        _bucket, _w, _l -> {:allow, 1}
      end)

      {:ok, view, _html} = live(conn, ~p"/signup")

      view
      |> element("#signup-form")
      |> render_change(%{
        "tenant" => %{"name" => "", "slug" => "", "email" => ""},
        "friendly_name" => "Primary"
      })

      html = view |> element("#enroll-authenticator-btn") |> render_click()

      assert html =~ "Too many authenticator enrollment requests"
    end

    test "Fly XFF ordering regression: fly-client-ip wins over rightmost XFF entry",
         %{conn: conn} do
      test_pid = self()
      stub(Loopctl.MockRateLimiter, :check_rate, capture_bucket(test_pid))

      # Real Fly shape: fly-client-ip is the real client, XFF has app IP rightmost.
      # The old code's RemoteIp multi-header semantics could lose to the rightmost
      # XFF entry (66.241.125.10 = Fly app IP). Verify it doesn't.
      conn = fly_conn(conn, "203.0.113.100", xff: "203.0.113.100, 66.241.125.10")

      {:ok, view, _html} = live(conn, ~p"/signup")
      enroll_authenticator(view, "YubiKey")

      view
      |> form("#signup-form", %{
        "tenant" => %{
          "name" => "XFF Ordering Test",
          "slug" => "xff-order-test",
          "email" => "xff@order.test"
        }
      })
      |> render_submit()

      assert_receive {:bucket, bucket}
      # MUST resolve to the real client, NOT the app IP.
      assert bucket == "signup:ip:203.0.113.100"
      refute bucket == "signup:ip:66.241.125.10"
    end

    test "attestation_captured is bounded by the shared action budget before any crypto",
         %{conn: conn} do
      stub(Loopctl.MockRateLimiter, :check_rate, fn
        "signup:actions:" <> _rest, _w, _l -> {:deny, 60}
        _bucket, _w, _l -> {:allow, 1}
      end)

      {:ok, view, _html} = live(conn, ~p"/signup")

      html = render_hook(view, "attestation_captured", valid_attestation())

      assert html =~ "Too many attempts"
      refute has_element?(view, "#authenticator-0")
    end

    test "signup rejects oversized tenant fields before creating a tenant", %{conn: conn} do
      {:ok, view, _html} = live(fly_conn(conn, "203.0.113.7"), ~p"/signup")
      enroll_authenticator(view)

      html =
        view
        |> form("#signup-form", %{
          "tenant" => %{
            "name" => String.duplicate("N", 2000),
            "slug" => "oversized",
            "email" => "oversized@corp.example"
          }
        })
        |> render_submit()

      assert html =~ "Tenant details are too long"
      refute AdminRepo.get_by(Tenant, slug: "oversized")
    end

    test "validate caps an oversized tenant field so it is never echoed back", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      html =
        view
        |> element("#signup-form")
        |> render_change(%{
          "tenant" => %{"name" => String.duplicate("N", 2000), "slug" => "", "email" => ""},
          "friendly_name" => ""
        })

      # Truncated to @max_tenant_field_bytes (512); a 600-run can never appear.
      refute html =~ String.duplicate("N", 600)
    end
  end

  describe "/tenants/:id/onboarding" do
    test "renders onboarding checklist with a valid signed token", %{conn: conn} do
      tenant = fixture(:tenant, %{name: "Onboarding Target"})
      token = Phoenix.Token.sign(LoopctlWeb.Endpoint, "onboarding", tenant.id)
      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}/onboarding?token=#{token}")

      assert html =~ "Onboarding Target"
      assert html =~ "Generate audit signing key"
      assert html =~ "Provision your BYO LLM keys"
      assert html =~ "set_llm_config"
      assert html =~ "Create your first project"
      assert html =~ "Register your first agent"
    end

    test "redirects when token is missing", %{conn: conn} do
      tenant = fixture(:tenant, %{name: "Token Test"})

      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(conn, ~p"/tenants/#{tenant.id}/onboarding")
    end

    test "redirects when token is invalid", %{conn: conn} do
      tenant = fixture(:tenant, %{name: "Bad Token"})

      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(conn, ~p"/tenants/#{tenant.id}/onboarding?token=bogus")
    end

    test "redirects when token belongs to a different tenant", %{conn: conn} do
      tenant = fixture(:tenant, %{name: "Real Tenant"})
      other = fixture(:tenant, %{name: "Other Tenant"})
      token = Phoenix.Token.sign(LoopctlWeb.Endpoint, "onboarding", other.id)

      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(conn, ~p"/tenants/#{tenant.id}/onboarding?token=#{token}")
    end

    test "redirects when tenant not found", %{conn: conn} do
      missing_id = Ecto.UUID.generate()
      token = Phoenix.Token.sign(LoopctlWeb.Endpoint, "onboarding", missing_id)

      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(conn, ~p"/tenants/#{missing_id}/onboarding?token=#{token}")
    end
  end

  describe "resource-exhaustion backstops (byte truncation, bignum, type guards)" do
    test "an emoji friendly_name is BYTE-capped (not grapheme-capped) and does not crash",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      # 100 emoji = 400 bytes; the 120-byte cap keeps ≤ 30 emoji.
      view
      |> element("#signup-form")
      |> render_change(%{
        "tenant" => %{"name" => "", "slug" => "", "email" => ""},
        "friendly_name" => String.duplicate("😀", 100)
      })

      view |> element("#enroll-authenticator-btn") |> render_click()
      render_hook(view, "attestation_captured", valid_attestation())

      html = render(view)
      assert has_element?(view, "#authenticator-0")
      # A 40-emoji run (160 bytes) can never survive a 120-byte cap.
      refute html =~ String.duplicate("😀", 40)
    end

    test "a Zalgo (combining-mark) friendly_name is byte-capped and does not burn CPU / crash",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      # ~100 KB but ONE grapheme — the old grapheme cap returned it whole.
      zalgo = "e" <> String.duplicate("̃", 50_000)

      view
      |> element("#signup-form")
      |> render_change(%{
        "tenant" => %{"name" => "", "slug" => "", "email" => ""},
        "friendly_name" => zalgo
      })

      view |> element("#enroll-authenticator-btn") |> render_click()
      render_hook(view, "attestation_captured", valid_attestation())

      html = render(view)
      assert has_element?(view, "#authenticator-0")
      refute html =~ String.duplicate("̃", 1_000)
    end

    test "remove_authenticator with a ~2M-digit index is a no-op and does not crash",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")
      enroll_authenticator(view)

      # Without the O(1) byte guard, Integer.parse would raise SystemLimitError.
      render_hook(view, "remove_authenticator", %{"index" => String.duplicate("9", 2_000_000)})

      assert has_element?(view, "#authenticator-0")
    end

    test "validate with a non-map tenant is a no-op and does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      render_hook(view, "validate", %{"tenant" => ["not", "a", "map"]})

      assert has_element?(view, "#signup-form")
    end

    test "signup with a non-map tenant is a no-op and does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      render_hook(view, "signup", %{"tenant" => "not-a-map"})

      assert has_element?(view, "#signup-form")
    end

    test "request_attestation with a non-binary friendly_name does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      html = render_hook(view, "request_attestation", %{"friendly_name" => %{"x" => 1}})

      assert has_element?(view, "#signup-form")
      # cap_string returns "" for a non-binary -> the empty-name branch, no crash.
      assert html =~ "Please name this authenticator"
    end

    test "validate drops an oversized field as an O(1) no-op (not echoed back)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")

      # 100 KB > the 64 KB validate reject threshold: the whole event is a no-op
      # BEFORE any capping/echo, so the payload can never reach the re-render.
      oversized = String.duplicate("Z", 100_000)

      html =
        render_hook(view, "validate", %{
          "tenant" => %{"name" => oversized, "slug" => "", "email" => ""},
          "friendly_name" => ""
        })

      assert has_element?(view, "#signup-form")
      refute html =~ String.duplicate("Z", 1_000)
    end
  end

  # Drives the full enroll flow (name → request challenge → capture attestation)
  # so a signup submission has a valid authenticator. Relies on the default
  # `Loopctl.MockWebAuthn` stub wired via config/test.exs returning {:ok, _}.
  defp enroll_authenticator(view, name \\ "Primary Key") do
    view
    |> element("#signup-form")
    |> render_change(%{
      "tenant" => %{"name" => "", "slug" => "", "email" => ""},
      "friendly_name" => name
    })

    view |> element("#enroll-authenticator-btn") |> render_click()

    render_hook(view, "attestation_captured", valid_attestation())

    view
  end

  defp valid_attestation do
    %{
      "attestation_object" => "YWJjZA",
      "client_data_json" => "eyJmb28iOiJiYXIifQ",
      "credential_id" => "Y3JlZC1pZA"
    }
  end

  defp submit_tenant(view, name, slug, email) do
    view
    |> form("#signup-form", %{"tenant" => %{"name" => name, "slug" => slug, "email" => email}})
    |> render_submit()
  end

  # A request that arrived through fly-proxy: the unspoofable `fly-client-ip`
  # header carries the real client. Optionally include an attacker/Fly-shaped
  # `x-forwarded-for` (via `xff:`) to prove it is never consulted for the bucket.
  defp fly_conn(conn, client_ip, opts \\ []) do
    conn
    |> Plug.Conn.put_req_header("fly-client-ip", client_ip)
    |> maybe_put_xff(Keyword.get(opts, :xff))
  end

  # An off-Fly request with only `x-forwarded-for` (e.g. an nginx front end); the
  # HTTP-pipeline RemoteIp plug resolves conn.remote_ip from it.
  defp xff_conn(conn, xff), do: Plug.Conn.put_req_header(conn, "x-forwarded-for", xff)

  defp maybe_put_xff(conn, nil), do: conn
  defp maybe_put_xff(conn, xff), do: Plug.Conn.put_req_header(conn, "x-forwarded-for", xff)

  # Rate-limiter stub that reports only the primary signup submission bucket
  # (ignores the shared per-connection action budget and the per-verification
  # webauthn bucket) so bucket assertions are unambiguous.
  defp capture_bucket(test_pid) do
    fn
      "signup:webauthn:" <> _rest, _window, _limit ->
        {:allow, 1}

      "signup:actions:" <> _rest, _window, _limit ->
        {:allow, 1}

      bucket, _window, _limit ->
        send(test_pid, {:bucket, bucket})
        {:allow, 1}
    end
  end
end
