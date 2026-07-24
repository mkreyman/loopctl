/**
 * LCP-1 §9 cross-language signing conformance.
 *
 * The MCP signing helpers (custody_sign_claim / custody_sign_attestation) MUST
 * produce byte-identical signatures to the Elixir reference implementation, or an
 * agent's signed claims will be rejected by the server. This test reimplements the
 * §9.2/§9.3 wire format (mirroring index.js) and asserts it reproduces the
 * checked-in Elixir-generated vectors at docs/spec/vectors/LCP-1/signed_profile.json.
 *
 * If this fails, the MCP preimage construction has drifted from the spec/server.
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const vectors = JSON.parse(
  readFileSync(
    path.join(__dirname, "..", "..", "docs", "spec", "vectors", "LCP-1", "signed_profile.json"),
    "utf8",
  ),
);

function lp(buf) {
  const l = Buffer.alloc(8);
  l.writeBigUInt64BE(BigInt(buf.length));
  return Buffer.concat([l, Buffer.from(buf)]);
}
function present(s) {
  if (s === null || s === undefined || s === "") return Buffer.from([0]);
  return Buffer.concat([Buffer.from([1]), lp(Buffer.from(s, "utf8"))]);
}
function canon(v) {
  if (Array.isArray(v)) return "[" + v.map(canon).join(",") + "]";
  if (v && typeof v === "object") {
    const k = Object.keys(v).sort();
    return "{" + k.map((x) => JSON.stringify(x) + ":" + canon(v[x])).join(",") + "}";
  }
  return JSON.stringify(v);
}
function privFromSeedHex(hex) {
  const pkcs8 = Buffer.concat([
    Buffer.from("302e020100300506032b657004220420", "hex"),
    Buffer.from(hex, "hex"),
  ]);
  return crypto.createPrivateKey({ key: pkcs8, format: "der", type: "pkcs8" });
}
function pubHexFromSeedHex(hex) {
  const priv = privFromSeedHex(hex);
  return crypto.createPublicKey(priv).export({ format: "der", type: "spki" }).slice(-32).toString("hex");
}
function sign(preimage, seedHex) {
  const digest = crypto.createHash("sha256").update(preimage).digest();
  return { sig: crypto.sign(null, digest, privFromSeedHex(seedHex)), digest };
}

describe("LCP-1 §9 MCP signing reproduces the Elixir vectors", () => {
  test("keypair derivation matches (agent + owner pubkeys)", () => {
    assert.equal(pubHexFromSeedHex(vectors.keys.agent_seed), vectors.keys.agent_pubkey);
    assert.equal(pubHexFromSeedHex(vectors.keys.owner_seed), vectors.keys.owner_pubkey);
  });

  test("claim signature (§9.3) is byte-identical", () => {
    const c = vectors.claim;
    const ts = Buffer.alloc(8);
    ts.writeBigUInt64BE(BigInt(c.claimed_at));
    const preimage = Buffer.concat([
      lp(Buffer.from("loopctl/custody-claim/1", "utf8")),
      lp(Buffer.from(c.alg, "utf8")),
      lp(Buffer.from(c.tenant_id, "utf8")),
      lp(Buffer.from(c.gate, "utf8")),
      present(c.work_item_id),
      lp(Buffer.from(canon(c.body), "utf8")),
      present(c.capability_id),
      ts,
    ]);
    const { sig, digest } = sign(preimage, vectors.keys.agent_seed);
    assert.equal(digest.toString("hex"), c.preimage_sha256);
    assert.equal(sig.toString("hex"), c.claim_sig);
  });

  test("attestation signature (§9.2) is byte-identical", () => {
    const a = vectors.attestation;
    const preimage = Buffer.concat([
      lp(Buffer.from("loopctl/dispatch-attestation/1", "utf8")),
      lp(Buffer.from(a.alg, "utf8")),
      lp(Buffer.from(a.tenant_id, "utf8")),
      lp(Buffer.from(a.agent_pubkey, "hex")),
      lp(Buffer.from(canon(a.lineage_path), "utf8")),
      lp(Buffer.from(a.conditions, "utf8")),
    ]);
    const { sig, digest } = sign(preimage, vectors.keys.owner_seed);
    assert.equal(digest.toString("hex"), a.preimage_sha256);
    assert.equal(sig.toString("hex"), a.attestation_sig);
  });
});
