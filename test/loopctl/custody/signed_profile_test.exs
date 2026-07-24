defmodule Loopctl.Custody.SignedProfileTest do
  @moduledoc """
  Conformance tests for LCP-1 §9 signed-profile primitives and the enroll → sign
  → verify loop end to end. Every assertion cites the clause it exercises.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.Custody.SignedProfile
  alias Loopctl.Dispatches

  defp keypair, do: :crypto.generate_key(:eddsa, :ed25519)

  @tenant "88888888-8888-8888-8888-888888888888"
  @work "99999999-9999-9999-9999-999999999999"

  describe "LCP-1 §6.1 algorithm agility" do
    test "only ed25519 is defined this version" do
      assert SignedProfile.algorithms() == ["ed25519"]
      assert SignedProfile.known_alg?("ed25519")
      refute SignedProfile.known_alg?("secp256k1-schnorr")
      refute SignedProfile.known_alg?("rsa")
    end
  end

  describe "LCP-1 §9.3 custody-claim signature" do
    setup do
      {pub, priv} = keypair()
      %{pub: pub, priv: priv}
    end

    test "a valid claim signature verifies", %{pub: pub, priv: priv} do
      body = %{"findings" => "ok", "outcome" => "approved"}
      claimed_at = 1_760_000_000

      preimage =
        SignedProfile.claim_preimage(
          "ed25519",
          @tenant,
          "verify",
          @work,
          body,
          "cap-1",
          claimed_at
        )

      sig = SignedProfile.sign("ed25519", preimage, priv)

      assert :ok =
               SignedProfile.verify_claim(
                 alg: "ed25519",
                 dispatch_alg: "ed25519",
                 agent_pubkey: pub,
                 tenant_id: @tenant,
                 gate: "verify",
                 work_item_id: @work,
                 body: body,
                 capability_id: "cap-1",
                 claimed_at: claimed_at,
                 signature: sig
               )
    end

    test "a tampered body is rejected (signature binds the body)", %{pub: pub, priv: priv} do
      body = %{"outcome" => "approved"}
      claimed_at = 1_760_000_000

      preimage =
        SignedProfile.claim_preimage(
          "ed25519",
          @tenant,
          "verify",
          @work,
          body,
          "cap-1",
          claimed_at
        )

      sig = SignedProfile.sign("ed25519", preimage, priv)

      assert {:error, :invalid_signature} =
               SignedProfile.verify_claim(
                 alg: "ed25519",
                 dispatch_alg: "ed25519",
                 agent_pubkey: pub,
                 tenant_id: @tenant,
                 gate: "verify",
                 work_item_id: @work,
                 body: %{"outcome" => "rejected"},
                 capability_id: "cap-1",
                 claimed_at: claimed_at,
                 signature: sig
               )
    end

    test "an alg that differs from the dispatch's is rejected (§6.1 substitution guard)", %{
      pub: pub,
      priv: priv
    } do
      preimage = SignedProfile.claim_preimage("ed25519", @tenant, "verify", @work, %{}, "c", 1)
      sig = SignedProfile.sign("ed25519", preimage, priv)

      assert {:error, :alg_mismatch} =
               SignedProfile.verify_claim(
                 alg: "ed25519",
                 dispatch_alg: "secp256k1-schnorr",
                 agent_pubkey: pub,
                 tenant_id: @tenant,
                 gate: "verify",
                 work_item_id: @work,
                 body: %{},
                 capability_id: "c",
                 claimed_at: 1,
                 signature: sig
               )
    end

    test "an unknown alg is rejected", %{pub: pub} do
      assert {:error, :unknown_alg} =
               SignedProfile.verify_claim(
                 alg: "rsa",
                 dispatch_alg: "rsa",
                 agent_pubkey: pub,
                 tenant_id: @tenant,
                 gate: "verify",
                 work_item_id: @work,
                 body: %{},
                 capability_id: "c",
                 claimed_at: 1,
                 signature: <<0>>
               )
    end

    test "the body is canonicalized, so key order does not affect verification", %{
      pub: pub,
      priv: priv
    } do
      p1 =
        SignedProfile.claim_preimage(
          "ed25519",
          @tenant,
          "verify",
          @work,
          %{"a" => 1, "b" => 2},
          "c",
          1
        )

      p2 =
        SignedProfile.claim_preimage(
          "ed25519",
          @tenant,
          "verify",
          @work,
          %{"b" => 2, "a" => 1},
          "c",
          1
        )

      assert p1 == p2

      sig = SignedProfile.sign("ed25519", p1, priv)

      assert :ok =
               SignedProfile.verify_claim(
                 alg: "ed25519",
                 dispatch_alg: "ed25519",
                 agent_pubkey: pub,
                 tenant_id: @tenant,
                 gate: "verify",
                 work_item_id: @work,
                 body: %{"b" => 2, "a" => 1},
                 capability_id: "c",
                 claimed_at: 1,
                 signature: sig
               )
    end
  end

  describe "LCP-1 §9.2 dispatch attestation" do
    test "a valid owner attestation over an agent key verifies" do
      {agent_pub, _agent_priv} = keypair()
      {owner_pub, owner_priv} = keypair()
      lineage = ["11111111-1111-1111-1111-111111111111"]
      conditions = "gate=verify&expires<1760000000"

      preimage =
        SignedProfile.attestation_preimage("ed25519", @tenant, agent_pub, lineage, conditions)

      sig = SignedProfile.sign("ed25519", preimage, owner_priv)

      assert :ok =
               SignedProfile.verify_attestation(
                 alg: "ed25519",
                 tenant_id: @tenant,
                 agent_pubkey: agent_pub,
                 authorizer_pubkey: owner_pub,
                 lineage_path: lineage,
                 conditions: conditions,
                 signature: sig
               )
    end

    test "a self-attestation is rejected (§9.2)" do
      {pub, priv} = keypair()
      preimage = SignedProfile.attestation_preimage("ed25519", @tenant, pub, [], "")
      sig = SignedProfile.sign("ed25519", preimage, priv)

      assert {:error, :self_attestation} =
               SignedProfile.verify_attestation(
                 alg: "ed25519",
                 tenant_id: @tenant,
                 agent_pubkey: pub,
                 authorizer_pubkey: pub,
                 lineage_path: [],
                 conditions: "",
                 signature: sig
               )
    end

    test "a malformed conditions string is rejected before signature check" do
      {agent_pub, _} = keypair()
      {owner_pub, owner_priv} = keypair()

      preimage =
        SignedProfile.attestation_preimage("ed25519", @tenant, agent_pub, [], "gate=verify&")

      sig = SignedProfile.sign("ed25519", preimage, owner_priv)

      assert {:error, :malformed_conditions} =
               SignedProfile.verify_attestation(
                 alg: "ed25519",
                 tenant_id: @tenant,
                 agent_pubkey: agent_pub,
                 authorizer_pubkey: owner_pub,
                 lineage_path: [],
                 conditions: "gate=verify&",
                 signature: sig
               )
    end
  end

  describe "LCP-1 §9.2 conditions grammar" do
    test "valid strings" do
      assert SignedProfile.valid_conditions?("")
      assert SignedProfile.valid_conditions?("gate=verify")
      assert SignedProfile.valid_conditions?("gate=verify&expires<1760000000")
      assert SignedProfile.valid_conditions?("expires<0")
    end

    test "invalid strings" do
      refute SignedProfile.valid_conditions?("gate=verify&")
      refute SignedProfile.valid_conditions?("&gate=verify")
      refute SignedProfile.valid_conditions?("gate=verify&&expires<1")
      refute SignedProfile.valid_conditions?("gate=verify expires<1")
      refute SignedProfile.valid_conditions?("expires<01")
      refute SignedProfile.valid_conditions?("expires<-5")
      refute SignedProfile.valid_conditions?("unknown=x")
      refute SignedProfile.valid_conditions?(nil)
    end

    test "conditions evaluate against a concrete claim" do
      assert :ok = SignedProfile.conditions_met?("gate=verify", "verify", 100)

      assert {:error, :condition_unmet} =
               SignedProfile.conditions_met?("gate=verify", "report", 100)

      assert :ok = SignedProfile.conditions_met?("expires<200", "verify", 100)

      assert {:error, :condition_unmet} =
               SignedProfile.conditions_met?("expires<50", "verify", 100)

      # clause constrains the self-declared time; wall-clock freshness is the caller's job
      assert {:error, :condition_unmet} =
               SignedProfile.conditions_met?("unknown=x", "verify", 100)
    end
  end

  describe "LCP-1 §9.1.1 enrollment transparency (end to end)" do
    setup do
      %{tenant: fixture(:tenant), agent: nil}
    end

    test "enrolling an agent key records it on the audit chain, enumerable from the chain alone",
         %{tenant: tenant} do
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      {agent_pub, _priv} = keypair()

      {:ok, %{dispatch: dispatch}} =
        Dispatches.create_dispatch(tenant.id, %{
          role: :agent,
          agent_id: agent.id,
          agent_pubkey: agent_pub,
          alg: "ed25519"
        })

      assert dispatch.agent_pubkey == agent_pub
      assert dispatch.alg == "ed25519"

      # The transparency read side: reconstruct the enrolled-key set from the
      # hash-chained log, not the dispatches table.
      enrolled = Dispatches.enrolled_agent_keys(tenant.id)
      hexes = Enum.map(enrolled, & &1.agent_pubkey_hex)
      assert Base.encode16(agent_pub, case: :lower) in hexes

      entry = Enum.find(enrolled, &(&1.dispatch_id == dispatch.id))
      assert entry.alg == "ed25519"
    end

    test "a bearer dispatch enrolls no key and appears in no transparency listing", %{
      tenant: tenant
    } do
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      {:ok, %{dispatch: dispatch}} =
        Dispatches.create_dispatch(tenant.id, %{role: :agent, agent_id: agent.id})

      assert is_nil(dispatch.agent_pubkey)
      assert is_nil(dispatch.alg)

      assert Enum.all?(
               Dispatches.enrolled_agent_keys(tenant.id),
               &(&1.dispatch_id != dispatch.id)
             )
    end

    test "the full loop: enroll a key, sign a claim with the private half, server verifies it",
         %{tenant: tenant} do
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      {agent_pub, agent_priv} = keypair()

      {:ok, %{dispatch: dispatch}} =
        Dispatches.create_dispatch(tenant.id, %{
          role: :agent,
          agent_id: agent.id,
          agent_pubkey: agent_pub,
          alg: "ed25519"
        })

      # Agent side (private key never left the agent): sign the claim.
      body = %{"outcome" => "approved"}
      claimed_at = 1_760_000_000

      preimage =
        SignedProfile.claim_preimage(
          dispatch.alg,
          tenant.id,
          "verify",
          @work,
          body,
          "cap-x",
          claimed_at
        )

      sig = SignedProfile.sign(dispatch.alg, preimage, agent_priv)

      # Server side: verify against the ENROLLED public key, without the private key.
      reloaded = Loopctl.AdminRepo.get!(Loopctl.Dispatches.Dispatch, dispatch.id)

      assert :ok =
               SignedProfile.verify_claim(
                 alg: "ed25519",
                 dispatch_alg: reloaded.alg,
                 agent_pubkey: reloaded.agent_pubkey,
                 tenant_id: tenant.id,
                 gate: "verify",
                 work_item_id: @work,
                 body: body,
                 capability_id: "cap-x",
                 claimed_at: claimed_at,
                 signature: sig
               )
    end

    test "the both-or-neither DB CHECK rejects a half-enrolled dispatch", %{tenant: tenant} do
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      {agent_pub, _} = keypair()

      # alg without a pubkey — changeset validation catches it first.
      assert {:error, _} =
               Dispatches.create_dispatch(tenant.id, %{
                 role: :agent,
                 agent_id: agent.id,
                 alg: "ed25519"
               })

      # pubkey with an unknown alg — rejected.
      assert {:error, _} =
               Dispatches.create_dispatch(tenant.id, %{
                 role: :agent,
                 agent_id: agent.id,
                 agent_pubkey: agent_pub,
                 alg: "rsa"
               })
    end
  end
end
