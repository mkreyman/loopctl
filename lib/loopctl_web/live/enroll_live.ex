defmodule LoopctlWeb.EnrollLive do
  @moduledoc """
  #541 — the browser half of the opt-in trust-tier upgrade
  (`agent_rooted -> human_anchored`) for an EXISTING tenant.

  `GET /api/v1/tenants/me` on an agent-rooted tenant advertises an
  `enrollment_upgrade` remediation naming `request_authenticator_challenge` /
  `enroll_authenticator`, but `navigator.credentials.create()` cannot be driven
  from curl or an MCP tool, and the only page that ran a WebAuthn ceremony was
  `LoopctlWeb.SignupLive`, which creates a NEW tenant. The advertised upgrade
  path therefore could not be walked by anyone, which left every human-anchored
  surface — chain of custody, work breakdown, dispatch, token budgets —
  permanently unreachable for a tenant created before the signup ceremony
  existed.

  ## This LiveView holds no state and makes no authorization decision

  It renders a static shell and mounts the `AuthenticatorEnroll` hook. The
  entire ceremony runs in the browser against the PUBLIC API
  (`LoopctlWeb.TenantAuthenticatorController`), which already owns every gate:
  `role: :user`, `owns_tenant?/2`, the fail-closed rate limit, the two-phase
  challenge consumption, the `add_authenticator` reauth gate for a subsequent
  enrollment, and the attestation size caps.

  Two properties follow, and both are the reason it is shaped this way rather
  than as a LiveView that resolves a pasted key server-side:

    * **The operator's API key never reaches this process.** It is sent only as
      an `Authorization: Bearer` header on same-origin `fetch` calls from the
      hook. It is never a `handle_event` parameter, so it cannot land in socket
      assigns, Phoenix's event logging, a crash dump, or telemetry. There is
      deliberately no `handle_event/3` clause on this module at all.

    * **There is exactly one enrollment implementation.** Re-implementing the
      ceremony behind the LiveView socket would have duplicated the reauth gate
      that closes the "stolen role:user key grafts an attacker's own hardware
      onto the tenant's root of trust" backdoor
      (`docs/chain-of-custody-v2.md` §9.3) — the single worst thing to have two
      copies of.

  The client orchestrates; it never enforces (CWE-602). Calling the API
  directly with curl instead of using this page is not a bypass — it is the
  supported path, and this page is a convenience wrapper around it for the one
  step (`navigator.credentials.*`) that requires a browser.

  ## Route placement

  `/enroll` sits in the existing `:public_signup` live_session, outside any
  authenticated pipeline. loopctl has no browser session auth — the API key IS
  the credential, and it is presented per-request to the API, not to this page.
  The live_session is what supplies the root layout (and therefore `app.js`,
  which carries the hook).
  """

  use LoopctlWeb, :live_view

  @docs_url "https://loopctl.com/wiki/chain-of-custody"

  @impl true
  def mount(_params, _session, socket) do
    # No rate limiting here, matching SignupLive: merely LOADING the page must
    # never consume a bucket. The abusable work — challenge issuance and
    # attestation verification — is throttled fail-closed per tenant inside
    # TenantAuthenticatorController, which is the only path that reaches it.
    {:ok,
     socket
     |> assign(:page_title, "Enroll an authenticator")
     |> assign(:docs_url, @docs_url)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="mx-auto w-full max-w-2xl px-6 py-16" id="enroll-page">
      <header class="mb-10 flex items-center gap-4">
        <.icon name="hero-finger-print" class="h-10 w-10 text-accent-500" />
        <div>
          <h1 class="font-display text-2xl font-semibold text-slate-100">
            Enroll an authenticator
          </h1>
          <p class="mt-1 text-sm text-slate-400">
            Anchor an existing tenant to hardware. This upgrades its trust tier from
            <span class="font-mono text-slate-300">agent_rooted</span>
            to <span class="font-mono text-slate-300">human_anchored</span>, which unlocks the
            chain-of-custody, work-breakdown, dispatch, and token-budget surfaces.
          </p>
        </div>
      </header>

      <div
        id="enroll-app"
        phx-hook="AuthenticatorEnroll"
        phx-update="ignore"
        class="space-y-8"
      >
        <div class="space-y-6 rounded-md border border-slate-800 bg-slate-900/60 p-6">
          <div>
            <h2 class="font-display text-sm uppercase tracking-wide text-slate-400">
              Authorize
            </h2>
            <p class="mt-1 text-xs text-slate-500">
              Paste a <span class="font-mono">user</span>-role API key for the tenant you are
              anchoring. It is sent straight to the loopctl API as a bearer token from your
              browser — this page never transmits it over its own connection, and never stores it.
            </p>
          </div>

          <div>
            <label
              for="enroll-api-key"
              class="block font-mono text-xs uppercase tracking-wide text-slate-500"
            >
              User-role API key
            </label>
            <input
              id="enroll-api-key"
              type="password"
              autocomplete="off"
              autocapitalize="off"
              autocorrect="off"
              spellcheck="false"
              placeholder="lc_user_…"
              class="mt-2 block w-full rounded-md border border-slate-800 bg-slate-950 px-3 py-2 font-mono text-sm text-slate-100 placeholder:text-slate-600 focus:border-accent-500 focus:outline-none focus:ring-1 focus:ring-accent-500"
            />
          </div>

          <div>
            <label
              for="enroll-friendly-name"
              class="block font-mono text-xs uppercase tracking-wide text-slate-500"
            >
              Authenticator name
            </label>
            <input
              id="enroll-friendly-name"
              type="text"
              placeholder="Primary YubiKey"
              class="mt-2 block w-full rounded-md border border-slate-800 bg-slate-900 px-3 py-2 font-mono text-sm text-slate-100 placeholder:text-slate-600 focus:border-accent-500 focus:outline-none focus:ring-1 focus:ring-accent-500"
            />
          </div>

          <button
            id="enroll-submit"
            type="button"
            class="inline-flex w-full items-center justify-center gap-2 rounded-md border border-accent-500 bg-accent-600 px-6 py-2 font-mono text-sm uppercase tracking-wide text-slate-50 hover:bg-accent-500 disabled:cursor-not-allowed disabled:opacity-50"
          >
            <.icon name="hero-key" class="h-4 w-4" /> Enroll authenticator
          </button>

          <p id="enroll-status" role="status" class="mt-4 font-mono text-xs text-slate-400"></p>
        </div>

        <div id="enroll-result"></div>

        <div class="rounded-md border border-slate-800 bg-slate-900/40 p-6 text-xs text-slate-500">
          <p class="font-display uppercase tracking-wide text-slate-400">Before you start</p>
          <ul class="mt-3 space-y-2">
            <li>
              The key must be <span class="font-mono text-slate-400">user</span>
              role and belong to the tenant being anchored. Agent and orchestrator keys are
              refused — trust-tier operations are not delegable.
            </li>
            <li>
              Enrolling on an <span class="font-mono text-slate-400">agent_rooted</span>
              tenant needs only the key and a touch. Adding a SECOND authenticator to an
              already-anchored tenant additionally requires a touch from one that is already
              enrolled, so keep the existing device to hand.
            </li>
            <li>
              This is a one-way door in practice: a human-anchored tenant will not drop back to
              agent-rooted, and its last authenticator cannot be revoked. Enroll a backup once
              the first one is in.
            </li>
          </ul>
          <p class="mt-4">
            <.link href={@docs_url} class="font-mono text-accent-400 hover:text-accent-300">
              Read the chain-of-custody model →
            </.link>
          </p>
        </div>
      </div>
    </section>
    """
  end
end
