defmodule Loopctl.Tenants.CustodyOwnerKeyTest do
  @moduledoc """
  LCP-1 §9.2 owner-key registration/rotation: the root of the custody-attestation
  chain must be tamper-evidently recorded (AuditChain) and its prior keys retained
  (history) so root attestations stay offline-verifiable after a rotation.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query
  import Loopctl.Fixtures

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.Custody.SignedProfile
  alias Loopctl.Tenants
  alias Loopctl.Tenants.CustodyOwnerKeyHistory

  setup :verify_on_exit!

  # A rotation must prove possession of the OUTGOING owner private key: a signature
  # over owner_rotation_preimage(tenant_id, OLD_pubkey, OLD_set_at, new_pubkey, new_alg).
  # The outgoing key + its set_at are read from the CURRENT tenant row.
  defp rotation_proof(tenant_id, old_priv, new_pub, new_alg \\ "ed25519") do
    {:ok, tenant} = Tenants.get_tenant(tenant_id)

    preimage =
      SignedProfile.owner_rotation_preimage(
        tenant_id,
        tenant.custody_owner_pubkey,
        DateTime.to_unix(tenant.custody_owner_key_set_at, :microsecond),
        new_pub,
        new_alg
      )

    SignedProfile.sign("ed25519", preimage, old_priv)
  end

  defp owner_key_events(tenant_id) do
    tenant_id
    |> AuditChain.list_entries(action: "custody_owner_key_registered")
    |> Map.fetch!(:data)
  end

  defp history_rows(tenant_id) do
    from(h in CustodyOwnerKeyHistory, where: h.tenant_id == ^tenant_id, order_by: h.rotated_out)
    |> AdminRepo.all()
  end

  describe "register_custody_owner_key/4 — first registration" do
    test "stores the key, records an audit-chain event, and writes no history row" do
      tenant = fixture(:tenant)
      {pub, _priv} = :crypto.generate_key(:eddsa, :ed25519)

      assert {:ok, updated} = Tenants.register_custody_owner_key(tenant.id, pub, "ed25519")
      assert updated.custody_owner_pubkey == pub
      assert updated.custody_owner_alg == "ed25519"
      assert updated.custody_owner_key_set_at != nil

      assert [event] = owner_key_events(tenant.id)
      assert event.action == "custody_owner_key_registered"
      assert event.payload["owner_pubkey"] == Base.encode16(pub, case: :lower)
      assert event.payload["rotated"] == false

      assert history_rows(tenant.id) == []
    end
  end

  describe "register_custody_owner_key/4 — rotation" do
    test "archives the prior key with a validity window and records a second event" do
      tenant = fixture(:tenant)
      {pub1, priv1} = :crypto.generate_key(:eddsa, :ed25519)
      {pub2, _} = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, _} = Tenants.register_custody_owner_key(tenant.id, pub1, "ed25519")

      {:ok, rotated} =
        Tenants.register_custody_owner_key(tenant.id, pub2, "ed25519",
          rotation_proof: rotation_proof(tenant.id, priv1, pub2)
        )

      assert rotated.custody_owner_pubkey == pub2

      # The retired key is preserved so its root attestations stay verifiable.
      assert [old] = history_rows(tenant.id)
      assert old.public_key == pub1
      assert old.alg == "ed25519"
      assert old.rotated_in != nil
      assert old.rotated_out != nil

      # Both the initial registration and the rotation are on the hash-chained log.
      events = owner_key_events(tenant.id)
      assert length(events) == 2
      rotation_event = Enum.find(events, &(&1.payload["rotated"] == true))
      assert rotation_event.payload["owner_pubkey"] == Base.encode16(pub2, case: :lower)
      assert rotation_event.payload["previous_owner_pubkey"] == Base.encode16(pub1, case: :lower)
    end

    test "rotation without a rotation_proof is rejected" do
      tenant = fixture(:tenant)
      {pub1, _} = :crypto.generate_key(:eddsa, :ed25519)
      {pub2, _} = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, _} = Tenants.register_custody_owner_key(tenant.id, pub1, "ed25519")

      assert {:error, :owner_rotation_proof_required} =
               Tenants.register_custody_owner_key(tenant.id, pub2, "ed25519")

      # The owner key is unchanged and no phantom rotation was recorded.
      assert history_rows(tenant.id) == []
      assert length(owner_key_events(tenant.id)) == 1
    end

    test "rotation with a proof signed by the WRONG key is rejected" do
      tenant = fixture(:tenant)
      {pub1, _priv1} = :crypto.generate_key(:eddsa, :ed25519)
      {pub2, _} = :crypto.generate_key(:eddsa, :ed25519)
      {_wrong_pub, wrong_priv} = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, _} = Tenants.register_custody_owner_key(tenant.id, pub1, "ed25519")

      assert {:error, :owner_rotation_proof_invalid} =
               Tenants.register_custody_owner_key(tenant.id, pub2, "ed25519",
                 rotation_proof: rotation_proof(tenant.id, wrong_priv, pub2)
               )

      assert history_rows(tenant.id) == []
      assert length(owner_key_events(tenant.id)) == 1
    end

    test "a captured rotation proof cannot be REPLAYED after a rotate-back (freshness bound)" do
      tenant = fixture(:tenant)
      {pub_a, priv_a} = :crypto.generate_key(:eddsa, :ed25519)
      {pub_b, priv_b} = :crypto.generate_key(:eddsa, :ed25519)

      # A -> B: capture the A-signed proof.
      {:ok, _} = Tenants.register_custody_owner_key(tenant.id, pub_a, "ed25519")
      proof_a_to_b = rotation_proof(tenant.id, priv_a, pub_b)

      {:ok, _} =
        Tenants.register_custody_owner_key(tenant.id, pub_b, "ed25519",
          rotation_proof: proof_a_to_b
        )

      # B -> A (B is later "compromised", so the owner rotates back to A).
      {:ok, _} =
        Tenants.register_custody_owner_key(tenant.id, pub_a, "ed25519",
          rotation_proof: rotation_proof(tenant.id, priv_b, pub_a)
        )

      # Attacker holding compromised B replays the OLD A->B proof. Current key is A
      # again, but A's set_at has advanced, so the captured proof no longer matches
      # the reconstructed preimage → rejected. Trust is NOT re-rooted to B.
      assert {:error, :owner_rotation_proof_invalid} =
               Tenants.register_custody_owner_key(tenant.id, pub_b, "ed25519",
                 rotation_proof: proof_a_to_b
               )

      {:ok, final} = Tenants.get_tenant(tenant.id)
      assert final.custody_owner_pubkey == pub_a
    end
  end

  describe "register_custody_owner_key/4 — idempotent re-registration" do
    test "re-submitting the SAME key writes no history row and forges no rotation event" do
      tenant = fixture(:tenant)
      {pub, _} = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, _} = Tenants.register_custody_owner_key(tenant.id, pub, "ed25519")
      {:ok, again} = Tenants.register_custody_owner_key(tenant.id, pub, "ed25519")

      assert again.custody_owner_pubkey == pub
      assert history_rows(tenant.id) == []
      # Only the original registration event exists — no phantom rotation.
      assert [event] = owner_key_events(tenant.id)
      assert event.payload["rotated"] == false
    end
  end
end
