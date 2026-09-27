// WebAuthnLogin hook — US-45.7
//
// The browser half of the thread page's login. The server pushes a
// `webauthn:login` event carrying a stored, single-use challenge and the
// tenant's enrolled credential ids; this hook asks the authenticator for an
// assertion and pushes it back. It decides nothing: the LiveView fills a form
// with it and the server verifies it on POST /login.

import { base64urlEncode, base64urlDecode } from "../webauthn/base64url";

const WebAuthnLogin = {
  mounted() {
    this.handleEvent("webauthn:login", async ({ challenge, allowed_credentials, rp_id }) => {
      if (!window.PublicKeyCredential) {
        this.pushEvent("login_error", { reason: "webauthn_unsupported" });
        return;
      }

      try {
        const publicKey = {
          challenge: base64urlDecode(challenge),
          allowCredentials: (allowed_credentials || []).map((id) => ({
            type: "public-key",
            id: base64urlDecode(id),
          })),
          userVerification: "preferred",
          timeout: 60000,
        };
        if (rp_id) publicKey.rpId = rp_id;

        const credential = await navigator.credentials.get({ publicKey });

        if (!credential) {
          this.pushEvent("login_error", { reason: "no_credential" });
          return;
        }

        this.pushEvent("assertion_captured", {
          credential_id: base64urlEncode(credential.rawId),
          authenticator_data: base64urlEncode(credential.response.authenticatorData),
          signature: base64urlEncode(credential.response.signature),
          client_data_json: base64urlEncode(credential.response.clientDataJSON),
        });
      } catch (err) {
        this.pushEvent("login_error", { reason: (err && err.name) || "unknown_error" });
      }
    });
  },
};

export default WebAuthnLogin;
