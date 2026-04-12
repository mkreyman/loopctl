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
      assert AdminRepo.aggregate(Tenant, :count, :id) == 0
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
      assert AdminRepo.aggregate(Tenant, :count, :id) == 0
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
    test "renders onboarding checklist for a valid tenant", %{conn: conn} do
      tenant = fixture(:tenant, %{name: "Onboarding Target"})
      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}/onboarding")

      assert html =~ "Onboarding Target"
      assert html =~ "Generate audit signing key"
      assert html =~ "Create your first project"
      assert html =~ "Register your first agent"
    end

    test "redirects when tenant not found", %{conn: conn} do
      missing_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(conn, ~p"/tenants/#{missing_id}/onboarding")
    end
  end
end
