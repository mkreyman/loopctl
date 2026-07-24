defmodule Loopctl.Custody.SignedProfileTest do
  @moduledoc """
  Conformance tests for LCP-1 §9 signed-profile primitives and the enroll → sign
  → verify loop end to end. Every assertion cites the clause it exercises.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Custody.SignedProfile
  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Test.CustodyEnrollment

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

    test "a bearer dispatch (no enrolled key) is rejected as :not_enrolled, not :alg_mismatch" do
      assert {:error, :not_enrolled} =
               SignedProfile.verify_claim(
                 alg: "ed25519",
                 dispatch_alg: nil,
                 agent_pubkey: nil,
                 tenant_id: @tenant,
                 gate: "verify",
                 work_item_id: @work,
                 body: %{},
                 capability_id: "c",
                 claimed_at: 1,
                 signature: <<0>>
               )
    end

    test "a malformed body yields {:error, :malformed_body}, honoring the verify contract", %{
      pub: pub
    } do
      # A map mixing an atom and a string key of the same name makes canonical_json
      # raise; verify_claim must translate that to the error contract, not crash.
      mixed = Map.merge(%{"k" => 1}, %{k: 2})

      assert {:error, :malformed_body} =
               SignedProfile.verify_claim(
                 alg: "ed25519",
                 dispatch_alg: "ed25519",
                 agent_pubkey: pub,
                 tenant_id: @tenant,
                 gate: "verify",
                 work_item_id: @work,
                 body: mixed,
                 capability_id: "c",
                 claimed_at: 1,
                 signature: <<0>>
               )
    end

    test "a wrong-typed body/optional yields {:error, :malformed_body}, never a crash", %{
      pub: pub
    } do
      base = [
        alg: "ed25519",
        dispatch_alg: "ed25519",
        agent_pubkey: pub,
        tenant_id: @tenant,
        gate: "verify",
        work_item_id: @work,
        capability_id: "c",
        claimed_at: 1,
        signature: <<0>>
      ]

      # A non-map body fails `claim_preimage/7`'s `is_map(body)` guard
      # (FunctionClauseError) — must be mapped to the contract, not escape.
      assert {:error, :malformed_body} =
               SignedProfile.verify_claim(Keyword.put(base, :body, nil))

      assert {:error, :malformed_body} =
               SignedProfile.verify_claim(Keyword.put(base, :body, [1, 2, 3]))

      # A falsy-but-non-nil optional (`false`) previously hit `present(false)` with
      # no clause; the guard now makes it a clean malformed_body.
      assert {:error, :malformed_body} =
               SignedProfile.verify_claim(
                 base
                 |> Keyword.put(:body, %{})
                 |> Keyword.put(:work_item_id, false)
               )
    end

    test "verify_attestation maps a wrong-typed lineage_path to {:error, :malformed_body}" do
      {agent_pub, _} = keypair()
      {owner_pub, _} = keypair()

      assert {:error, :malformed_body} =
               SignedProfile.verify_attestation(
                 alg: "ed25519",
                 tenant_id: @tenant,
                 agent_pubkey: agent_pub,
                 authorizer_pubkey: owner_pub,
                 # non-list lineage_path fails `attestation_preimage/5`'s is_list guard
                 lineage_path: "not-a-list",
                 conditions: "",
                 signature: <<0>>
               )
    end

    test "claim_preimage distinguishes a nil optional field from an empty string" do
      nil_cap = SignedProfile.claim_preimage("ed25519", @tenant, "verify", @work, %{}, nil, 1)
      empty_cap = SignedProfile.claim_preimage("ed25519", @tenant, "verify", @work, %{}, "", 1)
      refute nil_cap == empty_cap

      nil_wi = SignedProfile.claim_preimage("ed25519", @tenant, "verify", nil, %{}, "c", 1)
      empty_wi = SignedProfile.claim_preimage("ed25519", @tenant, "verify", "", %{}, "c", 1)
      refute nil_wi == empty_wi
    end

    test "claimed_at outside [0, 2^64) is a clean :malformed_body, not a silently-wrapped sig", %{
      pub: pub
    } do
      base = [
        alg: "ed25519",
        dispatch_alg: "ed25519",
        agent_pubkey: pub,
        tenant_id: @tenant,
        gate: "verify",
        work_item_id: @work,
        body: %{},
        capability_id: "c",
        signature: <<0>>
      ]

      assert {:error, :malformed_body} =
               SignedProfile.verify_claim(Keyword.put(base, :claimed_at, -1))

      assert {:error, :malformed_body} =
               SignedProfile.verify_claim(Keyword.put(base, :claimed_at, 0x1_0000_0000_0000_0000))
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

  describe "LCP-1 §11 published vectors reproduce against the shipped code" do
    # This is the guard that was missing: it loads the checked-in signed_profile.json
    # and asserts the published signatures verify. Without it, a change to the
    # preimage construction (as happened in a review round) can silently diverge the
    # code from the spec vectors and break offline third-party verification.
    setup do
      path = Path.join(File.cwd!(), "docs/spec/vectors/LCP-1/signed_profile.json")
      %{v: path |> File.read!() |> Jason.decode!()}
    end

    defp hex(s), do: Base.decode16!(s, case: :lower)

    test "the published attestation signature verifies", %{v: v} do
      a = v["attestation"]

      assert :ok =
               SignedProfile.verify_attestation(
                 alg: a["alg"],
                 tenant_id: a["tenant_id"],
                 agent_pubkey: hex(a["agent_pubkey"]),
                 authorizer_pubkey: hex(v["keys"]["owner_pubkey"]),
                 lineage_path: a["lineage_path"],
                 conditions: a["conditions"],
                 signature: hex(a["attestation_sig"])
               )
    end

    test "the published claim signature verifies (spec §9.3 preimage matches the code)", %{v: v} do
      c = v["claim"]

      assert :ok =
               SignedProfile.verify_claim(
                 alg: c["alg"],
                 dispatch_alg: c["alg"],
                 agent_pubkey: hex(v["keys"]["agent_pubkey"]),
                 tenant_id: c["tenant_id"],
                 gate: c["gate"],
                 work_item_id: c["work_item_id"],
                 body: c["body"],
                 capability_id: c["capability_id"],
                 claimed_at: c["claimed_at"],
                 signature: hex(c["claim_sig"])
               )
    end

    test "the published preimage_sha256 values match a fresh recompute", %{v: v} do
      a = v["attestation"]

      att_preimage =
        SignedProfile.attestation_preimage(
          a["alg"],
          a["tenant_id"],
          hex(a["agent_pubkey"]),
          a["lineage_path"],
          a["conditions"]
        )

      assert Base.encode16(:crypto.hash(:sha256, att_preimage), case: :lower) ==
               a["preimage_sha256"]

      c = v["claim"]

      claim_preimage =
        SignedProfile.claim_preimage(
          c["alg"],
          c["tenant_id"],
          c["gate"],
          c["work_item_id"],
          c["body"],
          c["capability_id"],
          c["claimed_at"]
        )

      assert Base.encode16(:crypto.hash(:sha256, claim_preimage), case: :lower) ==
               c["preimage_sha256"]
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

    test "the DB backstop rejects a signed dispatch inserted with no transparency audit entry",
         %{tenant: tenant} do
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      {pub, _} = keypair()
      now = DateTime.utc_now()

      # Insert a signed dispatch DIRECTLY — bypassing create_dispatch, so no matching
      # `dispatch_created_with_agent_key` audit entry is written (the operator-with-DB
      # -access threat §9.1.1 defends against). The deferred constraint trigger must
      # reject it when constraints are checked. `SET CONSTRAINTS ALL IMMEDIATE` forces
      # the check inside the sandbox transaction, which otherwise never commits.
      assert_raise Postgrex.Error, ~r/dispatch_enrollment_transparency_violation/, fn ->
        %Dispatch{tenant_id: tenant.id, id: Ecto.UUID.generate()}
        |> Dispatch.changeset(%{
          role: :agent,
          agent_id: agent.id,
          lineage_path: [Ecto.UUID.generate()],
          expires_at: DateTime.add(now, 3600, :second),
          created_at: now,
          agent_pubkey: pub,
          alg: "ed25519"
        })
        |> AdminRepo.insert!()

        AdminRepo.query!("SET CONSTRAINTS ALL IMMEDIATE")
      end
    end

    test "the DB backstop passes a signed dispatch created through the sanctioned Multi", %{
      tenant: tenant
    } do
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      CustodyEnrollment.enroll_root(tenant.id, %{agent_id: agent.id})

      # Forcing the deferred backstop to check must NOT raise — the Multi wrote the
      # matching transparency audit entry in the same transaction as the dispatch.
      assert {:ok, _} = AdminRepo.query("SET CONSTRAINTS ALL IMMEDIATE")
    end

    test "enrolling an agent key records it on the audit chain, enumerable from the chain alone",
         %{tenant: tenant} do
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      %{dispatch: dispatch, agent_pub: agent_pub} =
        CustodyEnrollment.enroll_root(tenant.id, %{agent_id: agent.id})

      assert dispatch.agent_pubkey == agent_pub
      assert dispatch.alg == "ed25519"

      # The transparency read side: reconstruct the enrolled-key set from the
      # hash-chained log, not the dispatches table.
      %{data: enrolled} = Dispatches.enrolled_agent_keys(tenant.id)
      hexes = Enum.map(enrolled, & &1.agent_pubkey_hex)
      assert Base.encode16(agent_pub, case: :lower) in hexes

      entry = Enum.find(enrolled, &(&1.dispatch_id == dispatch.id))
      assert entry.alg == "ed25519"
      # LCP-1 §8.5: the transparency row's stored leaf hash recomputes from content.
      assert entry.integrity_ok
    end

    test "the transparency listing is keyset-paged: each page is bounded and streams via cursor",
         %{tenant: tenant} do
      # Enroll three keys (distinct agents — one active key per agent+role); the
      # listing must page rather than load them all at once.
      for _ <- 1..3 do
        agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
        CustodyEnrollment.enroll_root(tenant.id, %{agent_id: agent.id})
      end

      page1 = Dispatches.enrolled_agent_keys(tenant.id, limit: 2)
      assert length(page1.data) == 2
      assert page1.meta.has_more
      assert is_integer(page1.meta.next_cursor)

      page2 = Dispatches.enrolled_agent_keys(tenant.id, limit: 2, cursor: page1.meta.next_cursor)
      assert length(page2.data) == 1
      refute page2.meta.has_more
      assert is_nil(page2.meta.next_cursor)

      # The union across pages is the full enrolled set, with no overlap (newest first).
      all_positions = Enum.map(page1.data ++ page2.data, & &1.chain_position)
      assert all_positions == Enum.sort(all_positions, :desc)
      assert length(Enum.uniq(all_positions)) == 3
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
               Dispatches.enrolled_agent_keys(tenant.id).data,
               &(&1.dispatch_id != dispatch.id)
             )
    end

    test "the full loop: enroll a key, sign a claim with the private half, server verifies it",
         %{tenant: tenant} do
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      %{dispatch: dispatch, agent_priv: agent_priv} =
        CustodyEnrollment.enroll_root(tenant.id, %{agent_id: agent.id})

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

    test "a malformed / wrong-length agent_pubkey is rejected at enrollment", %{tenant: tenant} do
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      {_owner_pub, owner_priv} = CustodyEnrollment.ensure_owner_key(tenant.id)

      # A VALID attestation over the (malformed) key — so the rejection comes from
      # the 32-byte length validation, not from attestation-required masking it.
      short = :crypto.strong_rand_bytes(8)

      assert {:error, _} =
               Dispatches.create_dispatch(tenant.id, %{
                 role: :agent,
                 agent_id: agent.id,
                 agent_pubkey: Base.encode16(short, case: :lower),
                 alg: "ed25519",
                 attestation: CustodyEnrollment.root_attestation(tenant.id, short, owner_priv)
               })

      # An undecodable, non-hex junk string is rejected too — never persisted raw.
      assert {:error, _} =
               Dispatches.create_dispatch(tenant.id, %{
                 role: :agent,
                 agent_id: agent.id,
                 agent_pubkey: "notakey",
                 alg: "ed25519",
                 attestation: CustodyEnrollment.root_attestation(tenant.id, "notakey", owner_priv)
               })

      # And nothing bogus was recorded on the transparency log.
      assert Dispatches.enrolled_agent_keys(tenant.id).data == []
    end

    test "the both-or-neither DB CHECK rejects a half-enrolled dispatch", %{tenant: tenant} do
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      {_owner_pub, owner_priv} = CustodyEnrollment.ensure_owner_key(tenant.id)
      {agent_pub, _} = keypair()

      # alg without a pubkey — no attestation needed (bearer path), changeset catches it.
      assert {:error, _} =
               Dispatches.create_dispatch(tenant.id, %{
                 role: :agent,
                 agent_id: agent.id,
                 alg: "ed25519"
               })

      # pubkey with an unknown alg — rejected (a valid attestation is present so the
      # rejection is the alg check, not attestation-required).
      assert {:error, _} =
               Dispatches.create_dispatch(tenant.id, %{
                 role: :agent,
                 agent_id: agent.id,
                 agent_pubkey: agent_pub,
                 alg: "rsa",
                 attestation: CustodyEnrollment.root_attestation(tenant.id, agent_pub, owner_priv)
               })
    end

    test "enrolling an agent key with NO attestation is rejected (§9.2)", %{tenant: tenant} do
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      {agent_pub, _} = keypair()
      CustodyEnrollment.ensure_owner_key(tenant.id)

      assert {:error, :attestation_required} =
               Dispatches.create_dispatch(tenant.id, %{
                 role: :agent,
                 agent_id: agent.id,
                 agent_pubkey: agent_pub,
                 alg: "ed25519"
               })
    end

    test "a root enrollment with no owner key registered is rejected (§9.2 root of trust)", %{
      tenant: tenant
    } do
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      {agent_pub, _} = keypair()
      # No owner key registered → cannot resolve a root authorizer.
      assert {:error, :owner_key_not_registered} =
               Dispatches.create_dispatch(tenant.id, %{
                 role: :agent,
                 agent_id: agent.id,
                 agent_pubkey: agent_pub,
                 alg: "ed25519",
                 attestation: :binary.copy(<<0>>, 64)
               })
    end

    test "a root attestation signed by the WRONG key is rejected", %{tenant: tenant} do
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      CustodyEnrollment.ensure_owner_key(tenant.id)
      {agent_pub, _} = keypair()
      {_wrong_pub, wrong_priv} = keypair()

      assert {:error, {:attestation_invalid, _}} =
               Dispatches.create_dispatch(tenant.id, %{
                 role: :agent,
                 agent_id: agent.id,
                 agent_pubkey: agent_pub,
                 alg: "ed25519",
                 attestation: CustodyEnrollment.root_attestation(tenant.id, agent_pub, wrong_priv)
               })
    end

    test "delegation: a CHILD agent key is attested by the PARENT's agent key, not the owner", %{
      tenant: tenant
    } do
      # Root enrollment, owner-attested.
      parent_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      %{dispatch: parent, agent_priv: parent_priv} =
        CustodyEnrollment.enroll_root(tenant.id, %{
          role: :orchestrator,
          agent_id: parent_agent.id
        })

      # Child enrollment: the PARENT signs the attestation over the child key, over
      # the PARENT's lineage. No owner signature involved.
      child_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      {child_pub, _child_priv} = keypair()

      child_preimage =
        SignedProfile.attestation_preimage(
          "ed25519",
          tenant.id,
          child_pub,
          parent.lineage_path,
          ""
        )

      child_attestation = SignedProfile.sign("ed25519", child_preimage, parent_priv)

      assert {:ok, %{dispatch: child}} =
               Dispatches.create_dispatch(tenant.id, %{
                 role: :agent,
                 agent_id: child_agent.id,
                 parent_dispatch_id: parent.id,
                 agent_pubkey: child_pub,
                 alg: "ed25519",
                 attestation: child_attestation
               })

      assert child.agent_pubkey == child_pub
      assert List.first(child.lineage_path) == List.first(parent.lineage_path)

      # A child attestation signed by the OWNER (not the parent) is rejected — the
      # authorizer for a child is specifically the parent's key.
      {_o, owner_priv} = CustodyEnrollment.ensure_owner_key(tenant.id)
      {child2_pub, _} = keypair()
      child2_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      wrong_preimage =
        SignedProfile.attestation_preimage(
          "ed25519",
          tenant.id,
          child2_pub,
          parent.lineage_path,
          ""
        )

      assert {:error, {:attestation_invalid, _}} =
               Dispatches.create_dispatch(tenant.id, %{
                 role: :agent,
                 agent_id: child2_agent.id,
                 parent_dispatch_id: parent.id,
                 agent_pubkey: child2_pub,
                 alg: "ed25519",
                 attestation: SignedProfile.sign("ed25519", wrong_preimage, owner_priv)
               })
    end
  end

  describe "LCP-1 §9.2 attestation-gate coupling (tripwire)" do
    test "verify_claim cannot be gated in production without verify_attestation at enrollment" do
      # POST-ACTIVATION invariant (the "unattested is acceptable, transparency-only"
      # scope was OVERTURNED for owner-attested enrollment — KB 64a6aecd / f683e6f9):
      # `Dispatches.create_dispatch` NOW verifies the owner/parent attestation
      # (`verify_attestation`) at enrollment, and `SignedProfilePolicy` IS a
      # production `verify_claim` caller. This tripwire keeps the two coupled so the
      # guarantee cannot be silently REMOVED: if any production module under `lib/`
      # (other than the pure `SignedProfile` core itself) gates `verify_claim`,
      # enrollment MUST still call `SignedProfile.verify_attestation` (LCP-1 §9.2).
      # Ripping verify_attestation out of enrollment while a claim gate remains would
      # let an operator forge agent-attributable claims with a self-enrolled key. The
      # scan matches a CALL (`name(`), not a docstring reference.
      claim_callers =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.reject(&String.ends_with?(&1, "custody/signed_profile.ex"))
        |> Enum.filter(&(File.read!(&1) =~ ~r/verify_claim\(/))

      enrollment_attests? =
        File.read!("lib/loopctl/dispatches.ex") =~ ~r/verify_attestation\(/

      if claim_callers != [] and not enrollment_attests? do
        flunk("""
        SignedProfile.verify_claim is consulted by #{inspect(claim_callers)} but
        enrollment (Loopctl.Dispatches.create_dispatch) does not call
        SignedProfile.verify_attestation. Gating agent-signed claims without the
        §9.2 owner-attestation check at enrollment lets an operator forge
        agent-attributable claims. Wire verify_attestation into the enrollment/claim
        path before trusting verify_claim in a custody gate.
        """)
      end
    end
  end
end
