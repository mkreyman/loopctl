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
  alias Loopctl.Tenants
  alias Loopctl.Tenants.CustodyOwnerKeyHistory

  setup :verify_on_exit!

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
      {pub1, _} = :crypto.generate_key(:eddsa, :ed25519)
      {pub2, _} = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, _} = Tenants.register_custody_owner_key(tenant.id, pub1, "ed25519")
      {:ok, rotated} = Tenants.register_custody_owner_key(tenant.id, pub2, "ed25519")

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
  end
end
