// WebAuthn hook — US-26.0.1
//
// Wraps `navigator.credentials.create()` for the tenant signup ceremony.
// The server pushes a `webauthn:challenge` event into this hook with a
// base64url-encoded challenge; we feed it to the browser's WebAuthn API
// and ship the resulting attestation back via `pushEvent`.

const base64urlEncode = (buffer) => {
  const bytes = new Uint8Array(buffer);
  let str = "";
  for (let i = 0; i < bytes.byteLength; i++) {
    str += String.fromCharCode(bytes[i]);
  }
  return btoa(str)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
};

const base64urlDecode = (value) => {
  if (!value) return new Uint8Array();
  const padding = "=".repeat((4 - (value.length % 4)) % 4);
  const base64 = (value + padding).replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(base64);
  const output = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) {
    output[i] = raw.charCodeAt(i);
  }
  return output;
};

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
            attestation: "direct",
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
