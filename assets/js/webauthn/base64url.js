// base64url codec shared by the WebAuthn ceremonies.
//
// Every WebAuthn field the loopctl API exchanges — challenges, credential
// ids, attestation objects, assertion signatures — is base64url WITHOUT
// padding (`Base.url_encode64(.., padding: false)` server-side). Both the
// signup hook (`hooks/webauthn.js`) and the enrollment hook
// (`hooks/authenticator_enroll.js`) need the same pair, so it lives here
// rather than being copied: a divergence between the two would surface as
// an opaque attestation-verification failure, not as a decode error.

export const base64urlEncode = (buffer) => {
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

export const base64urlDecode = (value) => {
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
