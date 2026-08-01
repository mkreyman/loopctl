// Authenticator enrollment hook — #541
//
// Drives the opt-in WebAuthn trust-tier upgrade (agent_rooted ->
// human_anchored) for an EXISTING tenant. `navigator.credentials.create()`
// cannot be driven from curl or an MCP tool, so the browser half has to
// exist somewhere; this is it.
//
// ## Why the whole ceremony runs in the browser
//
// The server side is already complete and reviewed:
// `LoopctlWeb.TenantAuthenticatorController` owns the fail-closed rate
// limit, the two-phase challenge consumption, the `add_authenticator`
// reauth gate that closes the soft-recovery backdoor, and the attestation
// size caps. This hook calls THAT controller over the public API rather
// than having `EnrollLive` re-implement enrollment behind the LiveView
// socket, so there stays exactly one enrollment implementation and one
// place those gates can be got wrong.
//
// Two consequences worth stating plainly:
//
//   1. The operator's API key travels ONLY as an `Authorization: Bearer`
//      header on same-origin fetches. It is never pushed over the LiveView
//      socket, so it never reaches server-side assigns, Phoenix's
//      `handle_event` parameter logging, crash dumps, or telemetry.
//      `EnrollLive` holds no secret.
//
//   2. The client ORCHESTRATES; it never ENFORCES (CWE-602). Role,
//      tenant ownership, rate limiting, reauth, and attestation
//      verification are all decided server-side. Everything this file
//      does to the DOM is presentation of a decision the API already
//      made — bypassing this page by calling the API directly with curl
//      is not an escalation, it is the supported path.
//
// The `user` handle for `navigator.credentials.create()` is taken from the
// challenge response, NOT generated here: AC-26.7.2.2 requires it be
// derived server-side from the tenant. That is the one reason this hook
// cannot simply reuse `hooks/webauthn.js`, which mints a random handle for
// the new-tenant signup ceremony.

import { base64urlEncode, base64urlDecode } from "../webauthn/base64url";

const API = "/api/v1";
const CEREMONY_TIMEOUT_MS = 60000;
const FETCH_TIMEOUT_MS = 20000;
// Mirrors @max_friendly_name_bytes in TenantAuthenticatorController.
const MAX_FRIENDLY_NAME_BYTES = 120;
// A prepared challenge carries a 5-minute server TTL; re-request past this
// rather than spend a touch on one that expires mid-ceremony.
const PREPARED_TTL_MS = 120000;

// Only the witness plug's OWN rejections are safely replayable — it halts
// before the operation runs, so nothing committed. See request().
// prettier-ignore
const WITNESS_CODES = ["witness_divergence", "witness_bootstrap_already_consumed", "witness_header_missing", "witness_header_malformed"];

// Raw DOMException text is browser prose with no hint what to do. Name the two
// that matter: a refused already-enrolled device (excludeCredentials working),
// and the activation/timeout refusal — on WebKit that also covers a click whose
// user activation expired across an await.
const CEREMONY_ERRORS = {
  InvalidStateError:
    "That authenticator is already enrolled on this tenant — use a DIFFERENT device as a backup.",
  NotAllowedError:
    "The browser refused or timed out the ceremony. Click Enroll again and touch the device when prompted.",
};

const describe = (t) => (t.slug ? `${t.name} (${t.slug})` : t.name);
const byteLength = (value) => new TextEncoder().encode(value).length;
const reason = (error) => (error && error.message) || "Enrollment failed.";

const AuthenticatorEnroll = {
  mounted() {
    this.keyInput = this.el.querySelector("#enroll-api-key");
    this.nameInput = this.el.querySelector("#enroll-friendly-name");
    this.button = this.el.querySelector("#enroll-submit");
    this.statusEl = this.el.querySelector("#enroll-status");
    this.resultEl = this.el.querySelector("#enroll-result");

    // #enroll-app is phx-update="ignore", so these nodes SURVIVE a LiveView
    // reconnect while the hook instance does not. Bind through an owned signal
    // or the old instance's listeners stay attached and one click runs two
    // concurrent ceremonies — `this.running` cannot help, since each stale
    // listener closes over its own `this`. destroyed() cuts them.
    this.listeners = new AbortController();
    const signal = this.listeners.signal;

    this.button.addEventListener("click", () => this.run(), { signal });

    // Enter in either field starts the ceremony. There is deliberately NO
    // <form> element on this page: a form with no action does a native GET
    // submit if JS fails to load, which would put the API key in the URL,
    // the query string, the browser history, and any access log in front
    // of us.
    const enter = (event) => {
      if (event.key !== "Enter") return;
      event.preventDefault();
      this.run();
    };

    [this.keyInput, this.nameInput].forEach((el) =>
      el.addEventListener("keydown", enter, { signal })
    );

    // Resolve tenant + challenge as soon as the key is committed, not on the
    // click — see prepare().
    this.keyInput.addEventListener(
      "change",
      () => this.running || this.prepare().catch((e) => this.fail(reason(e))),
      { signal }
    );
  },

  destroyed() {
    this.listeners.abort();
  },

  async run() {
    if (this.running) return;

    const apiKey = (this.keyInput.value || "").trim();

    if (!apiKey) {
      this.fail("Paste a user-role API key to continue.");
      return;
    }

    const friendlyName = (this.nameInput.value || "").trim();

    // The server enforces this too, but only AFTER the touch — and by then the
    // challenge is spent, so a 422 there costs a whole second ceremony.
    if (byteLength(friendlyName) > MAX_FRIENDLY_NAME_BYTES) {
      this.fail(`Authenticator name must be at most ${MAX_FRIENDLY_NAME_BYTES} bytes.`);
      return;
    }

    if (!window.PublicKeyCredential) {
      this.fail(
        "This browser does not support WebAuthn — try Safari, Chrome, or Firefox."
      );
      return;
    }

    this.busy(true);
    this.clearResult();

    try {
      const { tenant, path, challenge } = await this.prepare(apiKey);

      // A tenant that is ALREADY human_anchored must prove possession of an
      // already-enrolled device before a second one is grafted on. The
      // server decides this (`reauth_required`) and re-checks it under a
      // row lock in Phase 3 — we only run the ceremony it asks for.
      let reauthAssertion = null;

      if (challenge.reauth_required) {
        this.status(
          "This tenant is already anchored — touch an ALREADY-ENROLLED authenticator to authorize adding another…"
        );
        reauthAssertion = await this.assert(challenge.reauth_challenge);
      }

      this.status(`Touch your authenticator to anchor ${describe(tenant)}…`);
      const attestation = await this.create(challenge);

      this.status("Verifying attestation…");

      const body = {
        ...attestation,
        challenge_id: challenge.challenge_id,
        friendly_name: friendlyName,
      };

      if (reauthAssertion) body.reauth_assertion = reauthAssertion;

      const enrolled = await this.post(path, apiKey, body);

      // The key is a live credential and the ceremony is over: drop it from
      // the DOM rather than leaving it in a field on an unattended screen.
      // Only on success — clearing after a failure would force a re-paste
      // for a retry that is usually a typo in the friendly name.
      this.prepared = null;
      this.keyInput.value = "";
      this.succeed(enrolled, tenant);
    } catch (error) {
      // Whatever failed, the challenge is spent or suspect — force a fresh one.
      this.prepared = null;
      this.fail(reason(error));
    } finally {
      this.busy(false);
    }
  },

  // Resolved BEFORE the click, for two reasons. WebKit does not carry transient
  // user activation across awaited network work, so `credentials.create()` has
  // to be the first await after the button press or Safari answers
  // NotAllowedError. And it NAMES the tenant on screen ahead of a one-way door
  // that a mis-pasted key otherwise walks through irreversibly, unconfirmed.
  async prepare(apiKey) {
    const key = apiKey || (this.keyInput.value || "").trim();
    const cached = this.prepared;

    if (cached && cached.apiKey === key && Date.now() - cached.at < PREPARED_TTL_MS) {
      return cached;
    }

    this.prepared = null;

    this.status("Resolving tenant…");
    const tenant = await this.getTenant(key);
    const path = `${API}/tenants/${encodeURIComponent(tenant.id)}/authenticators`;

    this.status(`Requesting an enrollment challenge for ${describe(tenant)}…`);
    const challenge = await this.post(`${path}/challenge`, key, {});

    this.status(`Ready — this will anchor ${describe(tenant)}. Click Enroll and touch.`);
    this.prepared = { apiKey: key, tenant, path, challenge, at: Date.now() };
    return this.prepared;
  },

  // --- API calls ---

  async getTenant(apiKey) {
    const response = await this.request(`${API}/tenants/me`, {
      headers: this.headers(apiKey),
    });

    const tenant = response.tenant;

    if (!tenant || !tenant.id) {
      throw new Error("Unexpected response from the tenant endpoint.");
    }

    return tenant;
  },

  async post(url, apiKey, payload) {
    const response = await this.request(url, {
      method: "POST",
      headers: { ...this.headers(apiKey), "content-type": "application/json" },
      body: JSON.stringify(payload),
    });

    return response.data;
  },

  // Every call here goes through the `:authenticated` pipeline, which means
  // `ValidateWitnessHeader` (US-26.5.2): an authenticated request must carry
  // `X-Loopctl-Last-Known-STH`, or a one-time-per-key
  // `X-Loopctl-STH-Bootstrap: true` grace. A browser tab has no cached STH on
  // load, and the ceremony makes three authenticated calls, so "just bootstrap"
  // is not enough on its own — the grace is spent after one request, and any key
  // that has ever been used by the MCP server or curl has already spent it.
  //
  // So: bootstrap when we hold no STH, capture the server's STH off every
  // response, and on a WITNESS rejection adopt the STH it hands back and replay
  // ONCE. That is the documented resync contract (#298), not a workaround.
  async request(url, options, retried = false) {
    const witness = this.sth
      ? { "x-loopctl-last-known-sth": this.sth }
      : { "x-loopctl-sth-bootstrap": "true" };

    // Without a deadline an API that accepts the connection and never answers
    // leaves the page busy forever, with a live credential in a disabled field
    // on an unattended screen and no cancel path but a reload.
    const deadline = new AbortController();
    const timer = setTimeout(() => deadline.abort(), FETCH_TIMEOUT_MS);

    let response;

    try {
      response = await fetch(url, {
        ...options,
        credentials: "omit",
        signal: deadline.signal,
        headers: { ...options.headers, ...witness },
      });
    } catch (_error) {
      // Network-level failure: no response was produced, so there is
      // nothing server-side to report.
      throw new Error(
        deadline.signal.aborted
          ? "The loopctl API did not respond in time — try again."
          : "Could not reach the loopctl API — check your connection."
      );
    } finally {
      clearTimeout(timer);
    }

    const currentSth = response.headers.get("x-loopctl-current-sth");
    if (currentSth) this.sth = currentSth;

    const body = await this.parseJson(response);

    if (response.ok) return body || {};

    // The STATUS alone does not identify a witness rejection. 409 is also how
    // the controller reports `too_many_authenticators`, and the header rides
    // along whenever the plug granted bootstrap grace on that same request;
    // replaying THAT re-sends a POST whose challenge Phase 1 already consumed,
    // so the operator sees `challenge_invalid` instead of the real error.
    const code = (body && body.error && body.error.code) || "";
    const resyncable = WITNESS_CODES.includes(code);

    if (resyncable && currentSth && !retried) {
      return this.request(url, options, true);
    }

    throw new Error(this.apiError(body, response.status));
  },

  headers(apiKey) {
    return { authorization: `Bearer ${apiKey}`, accept: "application/json" };
  },

  async parseJson(response) {
    try {
      return await response.json();
    } catch (_error) {
      return null;
    }
  },

  // Surface the API's own error text verbatim. Those messages are already
  // written to avoid distinguishing "no such tenant" from "not yours" —
  // both are a flat 403 — so paraphrasing them here could only make the
  // page leak more than the endpoint does.
  apiError(body, status) {
    const error = body && body.error;
    const message = error && error.message;
    const code = error && error.code;

    if (message) return code ? `${message} (${code})` : message;

    return `Request failed with status ${status}.`;
  },

  // --- WebAuthn ceremonies ---

  // Translates the DOMExceptions worth translating — see CEREMONY_ERRORS.
  async ceremony(fun) {
    try {
      return await fun();
    } catch (error) {
      const known = CEREMONY_ERRORS[error && error.name];
      if (known) throw new Error(known);
      throw error;
    }
  },

  async create(challenge) {
    // An authenticator that ALREADY holds a credential for this RP will happily
    // mint a second one, under a fresh credential_id the (tenant_id,
    // credential_id) index cannot catch — so the tenant believes it holds a
    // backup when both live on the one key it can lose, and losing it is
    // terminal. The reauth challenge carries exactly the set to exclude.
    const enrolled = ((challenge.reauth_challenge || {}).allowed_credentials || []).map(
      (id) => ({ type: "public-key", id: base64urlDecode(id) })
    );

    const credential = await this.ceremony(() =>
      navigator.credentials.create({
        publicKey: {
          challenge: base64urlDecode(challenge.challenge),
          rp: { id: challenge.rp.id, name: challenge.rp.name },
          excludeCredentials: enrolled,
          // AC-26.7.2.2 — the handle is derived server-side from the tenant
          // and is never client-supplied. Do not substitute a random id here.
          user: {
            id: base64urlDecode(challenge.user.id),
            name: challenge.user.name,
            displayName: challenge.user.display_name,
          },
          pubKeyCredParams: (challenge.pub_key_cred_params || []).map(
            ({ type, alg }) => ({ type, alg })
          ),
          authenticatorSelection: {
            residentKey: "preferred",
            userVerification: "preferred",
          },
          // MUST match the server's attestation conveyance preference. Wax
          // defaults `attestation` to "none" and the app configures no override
          // (`config :loopctl, :webauthn` sets only rp_id/rp_name/origin/
          // user_verification), so a client asking for "direct" gets a packed
          // attestation statement that `Wax.register/3` then rejects with
          // :invalid_attestation_conveyance_preference. Bound by
          // webauthn_attestation_conveyance_test.exs.
          attestation: "none",
          timeout: CEREMONY_TIMEOUT_MS,
        },
      })
    );

    if (!credential) {
      throw new Error("The authenticator returned no credential.");
    }

    return {
      credential_id: base64urlEncode(credential.rawId),
      attestation_object: base64urlEncode(credential.response.attestationObject),
      client_data_json: base64urlEncode(credential.response.clientDataJSON),
    };
  },

  async assert(reauth) {
    if (!reauth) {
      throw new Error(
        "The server required a fresh assertion but issued no challenge for it."
      );
    }

    const credential = await this.ceremony(() =>
      navigator.credentials.get({
        publicKey: {
          challenge: base64urlDecode(reauth.challenge),
          rpId: reauth.rp_id,
          allowCredentials: (reauth.allowed_credentials || []).map((id) => ({
            type: "public-key",
            id: base64urlDecode(id),
          })),
          userVerification: "preferred",
          timeout: CEREMONY_TIMEOUT_MS,
        },
      })
    );

    if (!credential) {
      throw new Error("The authenticator returned no assertion.");
    }

    return {
      challenge_id: reauth.challenge_id,
      credential_id: base64urlEncode(credential.rawId),
      authenticator_data: base64urlEncode(credential.response.authenticatorData),
      signature: base64urlEncode(credential.response.signature),
      client_data_json: base64urlEncode(credential.response.clientDataJSON),
    };
  },

  // --- Rendering ---
  //
  // Built with createElement/textContent throughout. Every string below
  // originates from an API response, and innerHTML on API-supplied text
  // (a tenant-controlled friendly_name, say) would be an XSS sink.

  busy(running) {
    this.running = running;
    this.button.disabled = running;
    this.keyInput.disabled = running;
    this.nameInput.disabled = running;
  },

  status(message) {
    this.statusEl.textContent = message;
    this.statusEl.className = "mt-4 font-mono text-xs text-slate-400";
  },

  clearResult() {
    this.resultEl.replaceChildren();
  },

  fail(message) {
    this.statusEl.textContent = "";
    this.clearResult();

    const box = document.createElement("div");
    box.id = "enroll-error";
    box.setAttribute("role", "alert");
    box.className =
      "rounded-md border border-rose-500/40 bg-rose-950/30 px-4 py-3 text-sm text-rose-200";
    box.textContent = message;

    this.resultEl.appendChild(box);
  },

  succeed(enrolled, tenant) {
    this.statusEl.textContent = "";
    this.clearResult();

    const box = document.createElement("div");
    box.id = "enroll-success";
    box.setAttribute("role", "status");
    box.className =
      "space-y-4 rounded-md border border-accent-500/40 bg-slate-950 px-4 py-4 text-sm text-slate-200";

    const heading = document.createElement("p");
    heading.className = "font-display text-sm uppercase tracking-wide text-accent-300";
    heading.textContent = enrolled.upgraded
      ? "Tenant anchored — trust tier upgraded"
      : "Authenticator enrolled";
    box.appendChild(heading);

    // Name the tenant that was actually anchored — the only place the operator
    // can confirm the one-way door closed on the tenant they meant.
    const anchored = document.createElement("p");
    anchored.id = "enroll-tenant";
    anchored.className = "font-mono text-xs text-slate-400";
    anchored.textContent = `tenant: ${describe(tenant)}`;
    box.appendChild(anchored);

    const tier = document.createElement("p");
    tier.className = "font-mono text-xs text-slate-400";
    tier.textContent = `trust_tier: ${enrolled.trust_tier}`;
    box.appendChild(tier);

    const name = document.createElement("p");
    name.className = "font-mono text-xs text-slate-400";
    name.textContent = `authenticator: ${enrolled.authenticator.friendly_name} (${enrolled.authenticator.attestation_format})`;
    box.appendChild(name);

    const surfaces = (enrolled.capabilities && enrolled.capabilities.surfaces) || {};
    const names = Object.keys(surfaces).sort();

    if (names.length > 0) {
      const label = document.createElement("p");
      label.className = "pt-2 font-display text-xs uppercase tracking-wide text-slate-500";
      label.textContent = "Surfaces";
      box.appendChild(label);

      const list = document.createElement("ul");
      list.id = "enroll-surfaces";
      list.className = "space-y-1";

      names.forEach((surface) => {
        const item = document.createElement("li");
        const allowed = surfaces[surface] === "allowed";
        item.className = `font-mono text-xs ${allowed ? "text-accent-200" : "text-slate-500"}`;
        item.textContent = `${allowed ? "✓" : "·"} ${surface}: ${surfaces[surface]}`;
        list.appendChild(item);
      });

      box.appendChild(list);
    }

    this.resultEl.appendChild(box);
  },
};

export default AuthenticatorEnroll;
