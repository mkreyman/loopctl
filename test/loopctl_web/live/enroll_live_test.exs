defmodule LoopctlWeb.EnrollLiveTest do
  @moduledoc """
  #541 — coverage for the authenticator-enrollment page.

  The ceremony itself runs in the browser against
  `LoopctlWeb.TenantAuthenticatorController`, which has its own
  (extensive) test suite. What is testable HERE, and what these tests are
  for, is the set of structural properties that make that split safe:

    * the page reaches an unauthenticated visitor at all;
    * it cannot receive the operator's API key, because its only event
      handler is a terminal no-op;
    * it cannot leak the key into a URL, because it has no form;
    * the hook that does the work is actually wired into the bundle; and
    * the hook takes the WebAuthn user handle from the server rather than
      minting one (AC-26.7.2.2).

  The last two are source scans. That is deliberate: they assert facts
  about files ExUnit cannot otherwise reach, and each one guards a failure
  that is SILENT — an unregistered hook renders a page whose button does
  nothing, and a client-minted handle produces a credential bound to the
  wrong user with no error anywhere.
  """

  use LoopctlWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @hook_path "assets/js/hooks/authenticator_enroll.js"
  @app_js_path "assets/js/app.js"

  setup :verify_on_exit!

  describe "GET /enroll" do
    test "renders unauthenticated, with the ceremony controls", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/enroll")

      assert html =~ ~s(id="enroll-page")
      assert html =~ ~s(id="enroll-api-key")
      assert html =~ ~s(id="enroll-friendly-name")
      assert html =~ ~s(id="enroll-submit")
      assert html =~ ~s(id="enroll-status")
      assert html =~ ~s(id="enroll-result")
    end

    test "explains the PHYSICAL action, naming all three authenticator kinds", %{conn: conn} do
      # The first version of this page described the trust-tier semantics and
      # never said what the operator would be asked to DO, which sent a real
      # operator looking for a QR code that loopctl does not issue. Each of the
      # three device classes behaves differently enough that omitting one
      # strands whoever is on that hardware.
      {:ok, _view, html} = live(conn, ~p"/enroll")

      assert html =~ "Touch ID"
      assert html =~ "Windows Hello"
      assert html =~ "QR code"
      assert html =~ "YubiKey"

      # The QR path silently fails without Bluetooth on both ends, and that is
      # invisible in the browser's own dialog.
      assert html =~ "Bluetooth"

      # Name-the-device guidance: a label naming the PERSON becomes a
      # revoke-the-wrong-device trap once a backup is enrolled.
      assert html =~ "Name it after the DEVICE"
    end

    test "body copy is not rendered at the failing slate-500 contrast", %{conn: conn} do
      # slate-500 on this page's near-black panels measures ~4.3:1, under the
      # 4.5:1 WCAG AA floor, and it was previously paired with text-xs for the
      # whole instructions block. Placeholder text is exempt (it is not content).
      {:ok, _view, html} = live(conn, ~p"/enroll")

      offenders =
        html
        |> String.split(~r/\s+/)
        |> Enum.filter(&(&1 =~ "slate-500" and not (&1 =~ "placeholder:")))

      assert offenders == [], "low-contrast slate-500 body text on /enroll: #{inspect(offenders)}"
    end

    test "mounts the AuthenticatorEnroll hook and lets it own its DOM", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/enroll")

      assert has_element?(view, ~s(#enroll-app[phx-hook="AuthenticatorEnroll"]))

      # The hook writes status and results into its own subtree; without
      # phx-update="ignore" a LiveView patch would wipe them mid-ceremony.
      assert has_element?(view, ~s(#enroll-app[phx-update="ignore"]))
    end

    test "the key field is a password input the browser will not offer to save",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/enroll")

      assert has_element?(view, ~s(input#enroll-api-key[type="password"]))
      assert has_element?(view, ~s(input#enroll-api-key[spellcheck="false"]))

      # NOT autocomplete="off": Chrome and Firefox deliberately ignore it on
      # password fields and will persist the value — here a live, long-lived
      # user-role key — into the password manager. "one-time-code" is the value
      # browsers actually treat as never-persist.
      assert has_element?(view, ~s(input#enroll-api-key[autocomplete="one-time-code"]))
      refute has_element?(view, ~s(input#enroll-api-key[autocomplete="off"]))
    end

    test "renders NO form element — a native GET submit would put the key in the URL",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/enroll")

      # A <form> with no action submits to the current URL as GET if JS fails
      # to load, which would write the pasted API key into the query string,
      # browser history, and every access log in front of the app. The page
      # therefore uses bare inputs plus a click/keydown handler.
      refute html =~ "<form"
    end
  end

  describe "the LiveView cannot receive the API key" do
    test "its only handle_event/3 is a terminal no-op that stores nothing", %{conn: conn} do
      # This is the whole security argument for the page's shape, expressed as
      # a property rather than a comment: no event handler RETAINS anything, so
      # there is no path by which a pasted credential reaches socket assigns,
      # Phoenix's event parameter logging, a crash dump, or telemetry.
      #
      # It is a no-op rather than ABSENT because /enroll is public and outside
      # any authenticated pipeline: with no clause at all, LiveView raises on
      # any pushed frame and a visitor can kill the channel process at will
      # (the same hardening SignupLive already carries).
      {:ok, view, _html} = live(conn, ~p"/enroll")

      # Survives the frame (no FunctionClauseError killing the channel)...
      assert render_hook(view, "junk", %{"api_key" => "lc_user_leaked_secret"}) =~
               ~s(id="enroll-page")

      assert Process.alive?(view.pid)

      # ...and retained nothing from it.
      refute render(view) =~ "lc_user_leaked_secret"
    end

    test "the hook never pushes anything over the LiveView socket" do
      source = File.read!(@hook_path)

      refute source =~ "pushEvent"
      refute source =~ "pushEventTo"
    end

    test "the hook sends the key only as an Authorization header" do
      source = File.read!(@hook_path)

      assert source =~ "authorization: `Bearer ${apiKey}`"

      # Same-origin fetch with credentials omitted: the ambient session cookie
      # is irrelevant to an API-key-authenticated call and must not ride along.
      assert source =~ ~s(credentials: "omit")
    end
  end

  describe "the hook is wired into the bundle" do
    test "app.js imports and registers AuthenticatorEnroll" do
      source = File.read!(@app_js_path)

      assert source =~ ~s(import AuthenticatorEnroll from "./hooks/authenticator_enroll")

      assert source =~ "AuthenticatorEnroll,",
             "AuthenticatorEnroll must be registered in the Hooks map, or the " <>
               "enroll button silently does nothing"
    end

    test "the hook file exists and exports a hook object" do
      source = File.read!(@hook_path)

      assert source =~ "export default AuthenticatorEnroll"
      assert source =~ "mounted()"
    end
  end

  describe "the hook's silent-failure guards" do
    test "create() excludes already-enrolled credentials and the hook unbinds on destroy" do
      source = File.read!(@hook_path)

      # Anchored to the load-bearing expressions, not the identifiers: a guard
      # reduced to `excludeCredentials: []` or an empty `destroyed() {}` is
      # exactly the regression these tests exist to catch, and a bare substring
      # scan passes on both.
      #
      # Without a POPULATED excludeCredentials a "backup" authenticator can be
      # the SAME physical device: the second credential gets a fresh
      # credential_id, so the (tenant_id, credential_id) unique index never sees
      # a duplicate and the tenant believes in redundancy it does not have.
      assert source =~ ~r/const enrolled = [^;]{0,200}allowed_credentials/
      assert source =~ ~r/excludeCredentials: enrolled/

      # #enroll-app is phx-update="ignore", so its DOM outlives the hook across
      # a LiveView reconnect. A destroyed() that does not ABORT the listener
      # controller leaves the old instance bound and one click runs two
      # concurrent ceremonies.
      assert source =~ ~r/destroyed\(\)\s*\{[^}]*this\.listeners\.abort\(\)/
    end

    test "the fetch deadline spans the response BODY, not just its headers" do
      source = File.read!(@hook_path)

      # fetch() resolves when the HEADERS arrive. Clearing the abort timer there
      # moves the unbounded wait into response.json(), which is the same hang
      # the deadline exists to close — so the body read must happen inside the
      # timer's try, and an abort during it must propagate rather than be read
      # as "no body".
      assert source =~ ~r/body = await this\.parseJson\(response, deadline\);\s*\}\s*catch/
      assert source =~ ~r/if \(deadline\.signal\.aborted\) throw error;/
    end
  end

  describe "AC-26.7.2.2 — the WebAuthn user handle is server-derived" do
    test "the hook takes user.id from the challenge response" do
      source = File.read!(@hook_path)

      assert source =~ "base64urlDecode(challenge.user.id)"
    end

    test "the hook does NOT mint its own user handle" do
      source = File.read!(@hook_path)

      # `hooks/webauthn.js` legitimately generates a random handle — it enrolls
      # an authenticator for a tenant that does not exist yet. This hook enrolls
      # against an EXISTING tenant, where the handle is derived server-side from
      # the tenant row and is never client-supplied. Copying the signup hook
      # wholesale is the easy mistake here, and it produces a credential bound
      # to a handle the server did not issue.
      refute source =~ "crypto.getRandomValues"
    end
  end
end
