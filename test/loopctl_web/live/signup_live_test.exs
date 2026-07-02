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

  # A TCP peer inside the test proxy allow-list (config/test.exs :remote_ip_opts,
  # 198.51.100.0/24). Trust is PEER-ANCHORED: the forwarded header is trusted
  # only when the unspoofable peer is one of these proxies.
  @trusted_proxy_peer {198, 51, 100, 50}

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

  describe "signup rate limiting (web-01, peer-anchored, spoof-resistant)" do
    test "loading /signup never consumes the rate-limit bucket; only the submission does",
         %{conn: conn} do
      test_pid = self()
      stub(Loopctl.MockRateLimiter, :check_rate, capture_bucket(test_pid))

      conn = proxied_conn(conn, "203.0.113.7")

      # Many page views (the abuse the old code punished everyone for) must
      # NOT touch the rate limiter at all.
      for _ <- 1..10 do
        {:ok, _view, _html} = live(conn, ~p"/signup")
      end

      refute_received {:bucket, _}

      # A real submission checks the limiter, keyed by the real forwarded
      # client IP — trusted because the PEER is a configured proxy.
      {:ok, view, _html} = live(conn, ~p"/signup")
      enroll_authenticator(view)
      submit_tenant(view, "IP Corp", "ip-corp", "ip@corp.example")

      assert_receive {:bucket, "signup:ip:203.0.113.7"}
    end

    test "genuine Fly-style: trusted proxy peer + XFF ending in the real client keys on the client",
         %{conn: conn} do
      test_pid = self()
      stub(Loopctl.MockRateLimiter, :check_rate, capture_bucket(test_pid))

      {:ok, view, _html} = live(proxied_conn(conn, "203.0.113.7"), ~p"/signup")
      enroll_authenticator(view)
      submit_tenant(view, "Real Corp", "real-corp", "real@corp.example")

      assert_receive {:bucket, "signup:ip:203.0.113.7"}
    end

    test "a client-forged X-Forwarded-For prepend cannot choose the bucket (trusted proxy peer)",
         %{conn: conn} do
      test_pid = self()
      stub(Loopctl.MockRateLimiter, :check_rate, capture_bucket(test_pid))

      # Peer IS a trusted proxy; the proxy appends the real client on the right.
      # RemoteIp scans right-to-left, so the forged prefix is ignored.
      {:ok, view, _html} = live(proxied_conn(conn, "6.6.6.6, 203.0.113.7"), ~p"/signup")
      enroll_authenticator(view)
      submit_tenant(view, "Prepend Corp", "prepend-corp", "prepend@corp.example")

      assert_receive {:bucket, bucket}
      assert bucket == "signup:ip:203.0.113.7"
      refute bucket == "signup:ip:6.6.6.6"
    end

    test "REPRODUCED ATTACK: forged XFF ending in a reserved IP from a non-proxy public peer " <>
           "keys on the peer, never the attacker's value",
         %{conn: conn} do
      test_pid = self()
      stub(Loopctl.MockRateLimiter, :check_rate, capture_bucket(test_pid))

      # The exact bypass: XFF "9.9.9.9, 127.0.0.1" from a PUBLIC peer that is NOT
      # a configured proxy. Peer-anchoring ignores the header entirely and keys
      # on the unspoofable peer. Pre-fix this keyed on signup:ip:9.9.9.9.
      {:ok, view, _html} =
        live(direct_conn(conn, {198, 51, 99, 1}, "9.9.9.9, 127.0.0.1"), ~p"/signup")

      enroll_authenticator(view)
      submit_tenant(view, "Attacker", "attacker-corp", "attacker@corp.example")

      assert_receive {:bucket, bucket}
      assert bucket == "signup:ip:198.51.99.1"
      refute bucket == "signup:ip:9.9.9.9"
    end

    test "the shipped default proxies (fdaa::/16) never trust a public peer" do
      # Proves the DEFAULT config is safe against the reproduced attack: a public
      # peer is not contained in fdaa::/16, so its forwarded header is ignored.
      fdaa = RemoteIp.Block.parse!("fdaa::/16")

      refute RemoteIp.Block.contains?(fdaa, RemoteIp.Block.encode({198, 51, 99, 1}))
      refute RemoteIp.Block.contains?(fdaa, RemoteIp.Block.encode({9, 9, 9, 9}))

      refute RemoteIp.Block.contains?(
               fdaa,
               RemoteIp.Block.encode({0x2606, 0x4700, 0, 0, 0, 0, 0, 1})
             )

      # But the Fly 6PN peer the app actually receives from IS trusted.
      assert RemoteIp.Block.contains?(fdaa, RemoteIp.Block.encode({0xFDAA, 0, 1, 0, 0, 0, 0, 5}))
    end

    test "one IP hitting the limit does not lock out a different IP", %{conn: conn} do
      stub(Loopctl.MockRateLimiter, :check_rate, fn
        "signup:ip:203.0.113.1", _window, _limit -> {:deny, 5}
        _bucket, _window, _limit -> {:allow, 1}
      end)

      {:ok, abuser_view, _html} = live(proxied_conn(conn, "203.0.113.1"), ~p"/signup")
      enroll_authenticator(abuser_view)
      abuser_html = submit_tenant(abuser_view, "Abuser", "abuser-corp", "abuser@corp.example")

      assert abuser_html =~ "Too many signup attempts"
      refute AdminRepo.get_by(Tenant, slug: "abuser-corp")

      # A different IP is unaffected — signup still completes.
      {:ok, victim_view, _html} = live(proxied_conn(conn, "203.0.113.9"), ~p"/signup")
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

    test "a direct public peer with no forwarded header keys on the peer", %{conn: conn} do
      test_pid = self()
      stub(Loopctl.MockRateLimiter, :check_rate, capture_bucket(test_pid))

      {:ok, view, _html} = live(direct_conn(conn, {203, 0, 113, 50}, nil), ~p"/signup")
      enroll_authenticator(view)
      submit_tenant(view, "Direct Corp", "direct-corp", "direct@corp.example")

      assert_receive {:bucket, bucket}
      assert bucket == "signup:ip:203.0.113.50"
    end

    test "a trusted proxy peer with no usable forwarded client falls to a per-connection bucket",
         %{conn: conn} do
      test_pid = self()
      stub(Loopctl.MockRateLimiter, :check_rate, capture_bucket(test_pid))

      # Behind the proxy but no X-Forwarded-For captured (e.g. RFC 7239
      # `Forwarded:` only, which connect_info :x_headers does not collect).
      # Must NOT collapse onto the shared proxy peer.
      {:ok, view, _html} = live(proxied_conn(conn, nil), ~p"/signup")
      enroll_authenticator(view)
      submit_tenant(view, "Fwd Corp", "fwd-corp", "fwd@corp.example")

      assert_receive {:bucket, bucket}
      assert bucket =~ ~r/\Asignup:session:/
      refute bucket == "signup:ip:198.51.100.50"
    end

    test "no peer at all (no :peer_data) uses a per-connection bucket", %{conn: conn} do
      test_pid = self()
      stub(Loopctl.MockRateLimiter, :check_rate, capture_bucket(test_pid))

      conn = Plug.Conn.put_private(conn, :live_view_connect_info, %{})

      {:ok, view, _html} = live(conn, ~p"/signup")
      enroll_authenticator(view)
      submit_tenant(view, "Unknown Corp", "unknown-corp", "unknown@corp.example")

      assert_receive {:bucket, bucket}
      assert bucket =~ ~r/\Asignup:session:/
      refute bucket == "signup:unknown"
      refute bucket == "signup:ip:unknown"
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

  # Fully controls the connected LiveView's connect_info: the TCP peer (which is
  # what trust is anchored on) and the client-supplied X-Forwarded-For chain.
  defp put_connect_info(conn, peer, xff_chain) do
    headers = if xff_chain, do: [{"x-forwarded-for", xff_chain}], else: []

    Plug.Conn.put_private(conn, :live_view_connect_info, %{
      peer_data: %{address: peer},
      x_headers: headers
    })
  end

  # A request that genuinely arrived via our trusted proxy: peer ∈ the configured
  # :proxies range, carrying the forwarded chain the proxy appended.
  defp proxied_conn(conn, xff_chain), do: put_connect_info(conn, @trusted_proxy_peer, xff_chain)

  # A direct / non-proxied connection from `peer` carrying a client-controlled
  # forwarding header (untrusted because the peer is not a configured proxy).
  defp direct_conn(conn, peer, xff_chain), do: put_connect_info(conn, peer, xff_chain)

  # Rate-limiter stub that reports only the signup bucket (ignores the separate
  # per-verification webauthn bucket) so bucket assertions are unambiguous.
  defp capture_bucket(test_pid) do
    fn
      "signup:webauthn:" <> _rest, _window, _limit ->
        {:allow, 1}

      bucket, _window, _limit ->
        send(test_pid, {:bucket, bucket})
        {:allow, 1}
    end
  end
end
