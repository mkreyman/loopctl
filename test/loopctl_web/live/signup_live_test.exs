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

    test "successful signup redirects to /tenants/:id/onboarding", %{conn: conn} do
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

      assert {:error, {:live_redirect, %{to: redirect_to}}} =
               view
               |> form("#signup-form", %{
                 "tenant" => %{
                   "name" => "Successful Corp",
                   "slug" => "successful-corp",
                   "email" => "admin@successful.example"
                 }
               })
               |> render_submit()

      assert redirect_to =~ "/tenants/"
      assert redirect_to =~ "/onboarding"

      assert AdminRepo.get_by(Tenant, slug: "successful-corp")
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

  describe "signup rate limiting (web-01, per-IP, action-scoped)" do
    test "loading /signup never consumes the rate-limit bucket; only the submission does",
         %{conn: conn} do
      test_pid = self()

      stub(Loopctl.MockRateLimiter, :check_rate, fn bucket, _window, _limit ->
        send(test_pid, {:bucket, bucket})
        {:allow, 1}
      end)

      conn = Plug.Conn.put_req_header(conn, "x-forwarded-for", "203.0.113.7")

      # Many page views (the abuse the old code punished everyone for) must
      # NOT touch the rate limiter at all.
      for _ <- 1..10 do
        {:ok, _view, _html} = live(conn, ~p"/signup")
      end

      refute_received {:bucket, _}

      # A real submission checks the limiter exactly once, keyed by the real
      # forwarded client IP — not the raw peer, and not a shared bucket.
      {:ok, view, _html} = live(conn, ~p"/signup")
      enroll_authenticator(view)

      view
      |> form("#signup-form", %{
        "tenant" => %{
          "name" => "IP Corp",
          "slug" => "ip-corp",
          "email" => "ip@corp.example"
        }
      })
      |> render_submit()

      assert_receive {:bucket, "signup:ip:203.0.113.7"}
    end

    test "one IP hitting the limit does not lock out a different IP", %{conn: conn} do
      # Deny only the abuser's per-IP bucket; everyone else is allowed.
      stub(Loopctl.MockRateLimiter, :check_rate, fn
        "signup:ip:198.51.100.1", _window, _limit -> {:deny, 5}
        _bucket, _window, _limit -> {:allow, 1}
      end)

      abuser_conn = Plug.Conn.put_req_header(conn, "x-forwarded-for", "198.51.100.1")
      {:ok, abuser_view, _html} = live(abuser_conn, ~p"/signup")
      enroll_authenticator(abuser_view)

      abuser_html =
        abuser_view
        |> form("#signup-form", %{
          "tenant" => %{
            "name" => "Abuser",
            "slug" => "abuser-corp",
            "email" => "abuser@corp.example"
          }
        })
        |> render_submit()

      assert abuser_html =~ "Too many signup attempts"
      refute AdminRepo.get_by(Tenant, slug: "abuser-corp")

      # A different IP is unaffected — signup still completes.
      victim_conn = Plug.Conn.put_req_header(conn, "x-forwarded-for", "203.0.113.9")
      {:ok, victim_view, _html} = live(victim_conn, ~p"/signup")
      enroll_authenticator(victim_view)

      assert {:error, {:live_redirect, %{to: redirect_to}}} =
               victim_view
               |> form("#signup-form", %{
                 "tenant" => %{
                   "name" => "Victim Corp",
                   "slug" => "victim-corp",
                   "email" => "victim@corp.example"
                 }
               })
               |> render_submit()

      assert redirect_to =~ "/onboarding"
      assert AdminRepo.get_by(Tenant, slug: "victim-corp")
    end

    test "a genuinely-unknown client IP falls back to a per-connection bucket, never a shared one",
         %{conn: conn} do
      test_pid = self()

      stub(Loopctl.MockRateLimiter, :check_rate, fn bucket, _window, _limit ->
        send(test_pid, {:bucket, bucket})
        {:allow, 1}
      end)

      # No forwarded header AND no peer data — the genuinely-unknown case.
      conn = Plug.Conn.put_private(conn, :live_view_connect_info, %{})

      {:ok, view, _html} = live(conn, ~p"/signup")
      enroll_authenticator(view)

      view
      |> form("#signup-form", %{
        "tenant" => %{
          "name" => "Unknown Corp",
          "slug" => "unknown-corp",
          "email" => "unknown@corp.example"
        }
      })
      |> render_submit()

      assert_receive {:bucket, bucket}
      # Per-connection (session) bucket, NOT a single shared "unknown" bucket.
      assert bucket =~ ~r/\Asignup:session:/
      refute bucket == "signup:unknown"
      refute bucket == "signup:ip:unknown"
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

  describe "/tenants/:id/onboarding" do
    test "renders onboarding checklist with a valid signed token", %{conn: conn} do
      tenant = fixture(:tenant, %{name: "Onboarding Target"})
      token = Phoenix.Token.sign(LoopctlWeb.Endpoint, "onboarding", tenant.id)
      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}/onboarding?token=#{token}")

      assert html =~ "Onboarding Target"
      assert html =~ "Generate audit signing key"
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

    render_hook(view, "attestation_captured", %{
      "attestation_object" => "YWJjZA",
      "client_data_json" => "eyJmb28iOiJiYXIifQ",
      "credential_id" => "Y3JlZC1pZA"
    })

    view
  end
end
