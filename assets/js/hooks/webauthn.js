// WebAuthn hook — US-26.0.1
//
// Wraps `navigator.credentials.create()` for the tenant signup ceremony.
// The server pushes a `webauthn:challenge` event into this hook with a
// base64url-encoded challenge; we feed it to the browser's WebAuthn API
// and ship the resulting attestation back via `pushEvent`.

import { base64urlEncode, base64urlDecode } from "../webauthn/base64url";

const WebAuthn = {
  mounted() {
    this.handleEvent("webauthn:challenge", async ({ challenge, friendly_name, rp_id }) => {
      if (!window.PublicKeyCredential) {
        this.pushEvent("attestation_error", { reason: "webauthn_unsupported" });
        return;
      }

      try {
        const credential = await navigator.credentials.create({
          publicKey: {
            challenge: base64urlDecode(challenge),
            rp: {
              id: rp_id || this.el.dataset.rpId || "loopctl.com",
              name: this.el.dataset.rpName || "loopctl",
            },
            user: {
              id: crypto.getRandomValues(new Uint8Array(16)),
              name: friendly_name || "loopctl-operator",
              displayName: friendly_name || "loopctl operator",
            },
            pubKeyCredParams: [
              { type: "public-key", alg: -7 }, // ES256
              { type: "public-key", alg: -257 }, // RS256
            ],
            authenticatorSelection: {
              residentKey: "preferred",
              userVerification: "preferred",
            },
            // "none", not "direct" — must match the server's conveyance
            // preference. Wax defaults to "none" and the app configures no
            // override, so a "direct" request yields a packed attestation
            // statement that `Wax.register/3` rejects outright with
            // :invalid_attestation_conveyance_preference. This silently
            // worked for platform authenticators (Touch ID / Windows Hello
            // typically return fmt "none" regardless) and failed for exactly
            // the hardware keys the signup page recommends — a YubiKey
            // returns a packed statement. Bound by
            // webauthn_attestation_conveyance_test.exs.
            attestation: "none",
            timeout: 60000,
          },
        });

        if (!credential) {
          this.pushEvent("attestation_error", { reason: "no_credential" });
          return;
        }

        const response = credential.response;

        this.pushEvent("attestation_captured", {
          credential_id: base64urlEncode(credential.rawId),
          attestation_object: base64urlEncode(response.attestationObject),
          client_data_json: base64urlEncode(response.clientDataJSON),
        });
      } catch (err) {
        this.pushEvent("attestation_error", {
          reason: (err && err.name) || "unknown_error",
        });
      }
    });
  },
};

export default WebAuthn;
