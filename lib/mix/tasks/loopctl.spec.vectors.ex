defmodule Mix.Tasks.Loopctl.Spec.Vectors do
  @shortdoc "Emit LCP-1 test vectors from the implementation"

  @moduledoc """
  Generates the LCP-1 §11 test vectors by EXECUTING the reference implementation
  and writing them to `docs/spec/vectors/LCP-1/`. The spec requires vectors to be
  produced this way rather than hand-derived, so that they test the code and not
  the author's understanding (`docs/spec/LCP-1-custody-claims.md` §11).

      mix loopctl.spec.vectors

  Emits the pure-function sets that a third party can reproduce without a
  database: SHARES_ROOT (§5.2), canonical_json (§8.3), the v2 leaf hash (§8.2),
  and the signed profile (§9, using published fixed Ed25519 seeds). The gate
  decision matrix (§11 set 2) is database-dependent and lives as the executable
  suite `test/loopctl/spec/lcp1_conformance_test.exs`.
  """
  use Mix.Task

  alias Loopctl.AuditChain.LeafHash
  alias Loopctl.Custody.SignedProfile
  alias Loopctl.Dispatches

  @out "docs/spec/vectors/LCP-1"

  @root "11111111-1111-1111-1111-111111111111"
  @other "22222222-2222-2222-2222-222222222222"
  @child_a "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  @child_b "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    File.mkdir_p!(@out)

    write("shares_root.json", shares_root())
    write("canonical_json.json", canonical_json())
    write("leaf_hash_v2.json", leaf_hash_v2())
    write("signed_profile.json", signed_profile())

    Mix.shell().info("Wrote LCP-1 vectors to #{@out}/")
  end

  defp shares_root do
    cases = [
      {"empty vs empty", [], []},
      {"empty vs non-empty", [], [@root]},
      {"non-empty vs empty", [@root], []},
      {"same single root", [@root], [@root]},
      {"different single root", [@root], [@other]},
      {"siblings under one root", [@root, @child_a], [@root, @child_b]},
      {"same root different depth", [@root], [@root, @child_a]},
      {"different roots equal depth", [@root, @child_a], [@other, @child_a]},
      {"root of one equals child of other", [@child_a], [@root, @child_a]}
    ]

    %{
      spec: "LCP-1 §5.2 SHARES_ROOT",
      note: "shared-root test, not longest-common-prefix; siblings share a root",
      vectors:
        Enum.map(cases, fn {label, a, b} ->
          %{label: label, a: a, b: b, shares_root: Dispatches.lineage_shares_prefix?(a, b)}
        end)
    }
  end

  defp canonical_json do
    inputs = [
      {"sorted object", %{"z" => 1, "a" => 2, "m" => 3}},
      {"atom keys equal string keys", %{a: 1, b: 2}},
      {"octet-order uppercase before lowercase", %{"a" => 1, "Z" => 2}},
      {"prefix keys", %{"abc" => 1, "ab" => 2}},
      {"nested", %{"outer" => %{"z" => 1, "a" => 2}}},
      {"empty object", %{}},
      {"empty array", []},
      {"ordered array", [3, 1, 2]}
    ]

    %{
      spec: "LCP-1 §8.3 canonical_json",
      vectors:
        Enum.map(inputs, fn {label, input} ->
          %{label: label, canonical: LeafHash.canonical_json(input)}
        end)
    }
  end

  defp leaf_hash_v2 do
    base = %{
      tenant_id: "33333333-3333-3333-3333-333333333333",
      position: 0,
      prev_hash: :binary.copy(<<0>>, 32),
      action: "event_created",
      actor_lineage: ["dispatch-a"],
      entity_type: "story",
      entity_id: "44444444-4444-4444-4444-444444444444",
      payload: %{"a" => 1, "b" => 2},
      inserted_at: ~U[2026-07-23 00:00:00.000000Z]
    }

    genesis = Map.put(base, :entity_id, nil)
    present = base

    %{
      spec: "LCP-1 §8.2 v2 leaf hash",
      note: "prev_hash is 32 zero bytes here (genesis); hashes are lowercase hex of SHA-256",
      vectors: [
        vector("genesis, entity_id absent", genesis),
        vector("entity_id present", present)
      ]
    }
  end

  defp vector(label, fields) do
    %{
      label: label,
      fields: %{
        tenant_id: fields.tenant_id,
        position: fields.position,
        prev_hash: Base.encode16(fields.prev_hash, case: :lower),
        action: fields.action,
        actor_lineage: fields.actor_lineage,
        entity_type: fields.entity_type,
        entity_id: fields.entity_id,
        payload: fields.payload,
        inserted_at: DateTime.to_iso8601(fields.inserted_at)
      },
      leaf_hash: Base.encode16(LeafHash.compute(fields, 2), case: :lower)
    }
  end

  # LCP-1 §11 set 5 — signed profile. Uses published fixed Ed25519 seeds so a
  # third party can reproduce the attestation and claim signatures byte for byte.
  defp signed_profile do
    owner_seed = :binary.copy(<<1>>, 32)
    agent_seed = :binary.copy(<<2>>, 32)
    {owner_pub, _} = :crypto.generate_key(:eddsa, :ed25519, owner_seed)
    {agent_pub, agent_priv} = :crypto.generate_key(:eddsa, :ed25519, agent_seed)
    # For Ed25519 the Erlang private key IS the 32-byte seed.
    owner_priv = owner_seed

    tenant = "33333333-3333-3333-3333-333333333333"
    work = "99999999-9999-9999-9999-999999999999"
    lineage = ["11111111-1111-1111-1111-111111111111"]
    conditions = "gate=verify&expires<1760000000"

    att_preimage =
      SignedProfile.attestation_preimage("ed25519", tenant, agent_pub, lineage, conditions)

    att_sig = SignedProfile.sign("ed25519", att_preimage, owner_priv)

    body = %{"outcome" => "approved"}
    claimed_at = 1_760_000_000

    claim_preimage =
      SignedProfile.claim_preimage("ed25519", tenant, "verify", work, body, "cap-x", claimed_at)

    claim_sig = SignedProfile.sign("ed25519", claim_preimage, agent_priv)

    %{
      spec: "LCP-1 §9 signed profile",
      note: "hex encodings are lowercase; seeds are 32 bytes; signatures are 64 bytes",
      keys: %{
        owner_seed: Base.encode16(owner_seed, case: :lower),
        owner_pubkey: Base.encode16(owner_pub, case: :lower),
        agent_seed: Base.encode16(agent_seed, case: :lower),
        agent_pubkey: Base.encode16(agent_pub, case: :lower)
      },
      attestation: %{
        alg: "ed25519",
        tenant_id: tenant,
        agent_pubkey: Base.encode16(agent_pub, case: :lower),
        lineage_path: lineage,
        conditions: conditions,
        preimage_sha256: Base.encode16(:crypto.hash(:sha256, att_preimage), case: :lower),
        attestation_sig: Base.encode16(att_sig, case: :lower)
      },
      claim: %{
        alg: "ed25519",
        tenant_id: tenant,
        gate: "verify",
        work_item_id: work,
        body: body,
        capability_id: "cap-x",
        claimed_at: claimed_at,
        preimage_sha256: Base.encode16(:crypto.hash(:sha256, claim_preimage), case: :lower),
        claim_sig: Base.encode16(claim_sig, case: :lower)
      }
    }
  end

  defp write(name, data) do
    File.write!(Path.join(@out, name), Jason.encode!(data, pretty: true) <> "\n")
  end
end
