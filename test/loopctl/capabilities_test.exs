defmodule Loopctl.CapabilitiesTest do
  @moduledoc """
  Tests for US-26.3.1 — Capability token mint/verify/consume.
  """

  use Loopctl.DataCase, async: true

  import Loopctl.Fixtures

  alias Loopctl.Capabilities
  alias Loopctl.Tenants.AuditKeyHistory

  setup :verify_on_exit!

  defp setup_cap_context do
    tenant = fixture(:tenant, %{audit_signing_public_key: :crypto.strong_rand_bytes(32)})
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

    # Mock secrets for the tenant's signing key
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    tenant =
      tenant
      |> Ecto.Changeset.change(audit_signing_public_key: pub)
      |> Loopctl.AdminRepo.update!()

    Mox.expect(Loopctl.MockSecrets, :get, fn _name -> {:ok, priv} end)
    Loopctl.TenantKeys.init_cache()

    lineage = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    %{tenant: tenant, story: story, lineage: lineage, pub: pub, priv: priv}
  end

  defp verify_start_cap(tenant, cap, story, lineage) do
    Capabilities.verify(tenant.id, %{
      "cap_id" => cap.id,
      "typ" => "start_cap",
      "story_id" => story.id,
      "lineage" => lineage
    })
  end

  defp archive_key(tenant_id, public_key, rotated_in, rotated_out) do
    %AuditKeyHistory{tenant_id: tenant_id}
    |> AuditKeyHistory.changeset(%{
      public_key: public_key,
      rotated_in: rotated_in,
      rotated_out: rotated_out
    })
    |> Loopctl.AdminRepo.insert!()
  end

  describe "mint/4" do
    test "creates a signed capability token" do
      %{tenant: tenant, story: story, lineage: lineage} = setup_cap_context()

      assert {:ok, cap} = Capabilities.mint(tenant.id, "start_cap", story.id, lineage)

      assert cap.typ == "start_cap"
      assert cap.story_id == story.id
      assert cap.issued_to_lineage == lineage
      assert cap.consumed_at == nil
      assert byte_size(cap.nonce) == 32
      assert byte_size(cap.signature) > 0
    end
  end

  describe "verify/2" do
    test "accepts a valid token" do
      %{tenant: tenant, story: story, lineage: lineage} = setup_cap_context()
      {:ok, cap} = Capabilities.mint(tenant.id, "start_cap", story.id, lineage)

      assert {:ok, verified} =
               Capabilities.verify(tenant.id, %{
                 "cap_id" => cap.id,
                 "typ" => "start_cap",
                 "story_id" => story.id,
                 "lineage" => lineage
               })

      assert verified.id == cap.id
    end

    test "rejects wrong type" do
      %{tenant: tenant, story: story, lineage: lineage} = setup_cap_context()
      {:ok, cap} = Capabilities.mint(tenant.id, "start_cap", story.id, lineage)

      assert {:error, :wrong_type} =
               Capabilities.verify(tenant.id, %{
                 "cap_id" => cap.id,
                 "typ" => "verify_cap",
                 "story_id" => story.id,
                 "lineage" => lineage
               })
    end

    test "rejects wrong lineage" do
      %{tenant: tenant, story: story, lineage: lineage} = setup_cap_context()
      {:ok, cap} = Capabilities.mint(tenant.id, "start_cap", story.id, lineage)

      wrong_lineage = [Ecto.UUID.generate()]

      assert {:error, :wrong_lineage} =
               Capabilities.verify(tenant.id, %{
                 "cap_id" => cap.id,
                 "typ" => "start_cap",
                 "story_id" => story.id,
                 "lineage" => wrong_lineage
               })
    end
  end

  describe "consume/1" do
    test "marks token as consumed" do
      %{tenant: tenant, story: story, lineage: lineage} = setup_cap_context()
      {:ok, cap} = Capabilities.mint(tenant.id, "start_cap", story.id, lineage)

      assert {:ok, consumed} = Capabilities.consume(cap)
      # consume/1 returns a freshly-built struct; assert a DateTime via a match
      # (not `!= nil`, which the 1.19 type-checker flags as an always-true
      # comparison since consumed_at is typed non-null on the {:ok, _} path) and
      # re-read the row so we verify the update was actually PERSISTED, not just
      # that the returned struct carries the timestamp.
      assert %DateTime{} = consumed.consumed_at

      persisted = Loopctl.AdminRepo.get!(Loopctl.Capabilities.CapabilityToken, cap.id)
      assert %DateTime{} = persisted.consumed_at
    end

    test "rejects replay (double consume)" do
      %{tenant: tenant, story: story, lineage: lineage} = setup_cap_context()
      {:ok, cap} = Capabilities.mint(tenant.id, "start_cap", story.id, lineage)

      {:ok, consumed} = Capabilities.consume(cap)
      assert {:error, :replay} = Capabilities.consume(consumed)
    end
  end

  describe "mint/4 — never issue a token the tenant's advertised key cannot check" do
    test "refuses to mint when the signing key no longer matches the advertised one" do
      # A rotation commits the new public key to the tenant row BEFORE the new
      # secret is readable, so the signer is the RETIRED half. Minting there
      # produces a token that verifies against nothing and is refused later as
      # `capability_forged`/`byzantine: true` — a permanent false accusation about
      # an agent that did nothing. The mint fails instead, as an operator fault.
      %{tenant: tenant, story: story, lineage: lineage} = setup_cap_context()
      assert {:ok, _cap} = Capabilities.mint(tenant.id, "start_cap", story.id, lineage)

      {new_pub, _new_priv} = :crypto.generate_key(:eddsa, :ed25519)

      tenant
      |> Ecto.Changeset.change(audit_signing_public_key: new_pub)
      |> Loopctl.AdminRepo.update!()

      assert {:error, {:key_unavailable, :signing_key_superseded}} =
               Capabilities.mint(tenant.id, "start_cap", story.id, lineage)

      # And it is classified as the PERSISTENT condition it is: retrying cannot
      # clear it, so it must not be answered with a retry-after.
      assert Capabilities.mint_failure_class({:key_unavailable, :signing_key_superseded}) ==
               :capability_key_unavailable

      assert Capabilities.mint_failure_class({:key_unavailable, :secret_store_unavailable}) ==
               :capability_mint_failed
    end
  end

  describe "verify/2 — signature failure is split by KEY STATE, not lumped as forgery" do
    # `:invalid_signature` is recorded as `capability_forged` with
    # `byzantine: true` in the APPEND-ONLY audit chain. Returning it when the
    # tenant simply has no key to check against writes a permanent false
    # accusation about an agent that did nothing wrong — and an authentic token
    # fails identically in that state, so the reason carries no information about
    # the caller at all.

    test "a CLEARED audit key yields :signing_key_unavailable, never :invalid_signature" do
      %{tenant: tenant, story: story, lineage: lineage} = setup_cap_context()
      {:ok, cap} = Capabilities.mint(tenant.id, "start_cap", story.id, lineage)

      tenant
      |> Ecto.Changeset.change(audit_signing_public_key: nil)
      |> Loopctl.AdminRepo.update!()

      assert {:error, :signing_key_unavailable} = verify_start_cap(tenant, cap, story, lineage)
    end

    test "a key ROTATED WITHOUT HISTORY yields :signing_key_unavailable" do
      %{tenant: tenant, story: story, lineage: lineage} = setup_cap_context()
      {:ok, cap} = Capabilities.mint(tenant.id, "start_cap", story.id, lineage)

      # An out-of-band replacement: the tenant row carries a new key rotated in
      # AFTER this token was issued, and nothing archived the key that signed it.
      {new_pub, _new_priv} = :crypto.generate_key(:eddsa, :ed25519)

      tenant
      |> Ecto.Changeset.change(
        audit_signing_public_key: new_pub,
        audit_key_rotated_at: DateTime.add(cap.issued_at, 1, :second)
      )
      |> Loopctl.AdminRepo.update!()

      assert {:error, :signing_key_unavailable} = verify_start_cap(tenant, cap, story, lineage)
    end

    test "a rotation WITH history covering issuance still VERIFIES (#630 stays fixed)" do
      %{tenant: tenant, story: story, lineage: lineage, pub: pub} = setup_cap_context()
      {:ok, cap} = Capabilities.mint(tenant.id, "start_cap", story.id, lineage)

      {new_pub, _new_priv} = :crypto.generate_key(:eddsa, :ed25519)
      rotated_at = DateTime.add(cap.issued_at, 1, :second)

      archive_key(tenant.id, pub, DateTime.add(cap.issued_at, -60, :second), rotated_at)

      tenant
      |> Ecto.Changeset.change(
        audit_signing_public_key: new_pub,
        audit_key_rotated_at: rotated_at
      )
      |> Loopctl.AdminRepo.update!()

      assert {:ok, _verified} = verify_start_cap(tenant, cap, story, lineage)
    end

    test "a rotation WITH history but a TAMPERED signature is still :invalid_signature" do
      # The forgery signal must survive the split: when the issuance-time key IS
      # available and the signature does not verify against it, that is evidence
      # about the caller and keeps its byzantine label.
      %{tenant: tenant, story: story, lineage: lineage, pub: pub} = setup_cap_context()
      {:ok, cap} = Capabilities.mint(tenant.id, "start_cap", story.id, lineage)

      {new_pub, _new_priv} = :crypto.generate_key(:eddsa, :ed25519)
      rotated_at = DateTime.add(cap.issued_at, 1, :second)

      archive_key(tenant.id, pub, DateTime.add(cap.issued_at, -60, :second), rotated_at)

      tenant
      |> Ecto.Changeset.change(
        audit_signing_public_key: new_pub,
        audit_key_rotated_at: rotated_at
      )
      |> Loopctl.AdminRepo.update!()

      cap
      |> Ecto.Changeset.change(signature: :crypto.strong_rand_bytes(64))
      |> Loopctl.AdminRepo.update!()

      assert {:error, :invalid_signature} = verify_start_cap(tenant, cap, story, lineage)
    end

    test "an OUT-OF-BAND key replacement is :signing_key_unavailable, not a forgery" do
      # The replacement leaves `audit_key_rotated_at` exactly as it was, so a
      # timestamp comparison reads the new key as "in force since before
      # issuance" and brands every outstanding token a forgery. Only the keypair
      # coherence check can tell this from a tampered signature: the tenant still
      # SIGNS with the old private half, so the advertised key is not the one that
      # was in force and no authentic token could verify against it either.
      %{tenant: tenant, story: story, lineage: lineage} = setup_cap_context()
      {:ok, cap} = Capabilities.mint(tenant.id, "start_cap", story.id, lineage)

      {new_pub, _new_priv} = :crypto.generate_key(:eddsa, :ed25519)

      tenant
      |> Ecto.Changeset.change(audit_signing_public_key: new_pub)
      |> Loopctl.AdminRepo.update!()

      assert {:error, :signing_key_unavailable} = verify_start_cap(tenant, cap, story, lineage)
    end

    test "a TAMPERED signature under the CURRENT, unrotated key is :invalid_signature" do
      %{tenant: tenant, story: story, lineage: lineage} = setup_cap_context()
      {:ok, cap} = Capabilities.mint(tenant.id, "start_cap", story.id, lineage)

      cap
      |> Ecto.Changeset.change(signature: :crypto.strong_rand_bytes(64))
      |> Loopctl.AdminRepo.update!()

      assert {:error, :invalid_signature} = verify_start_cap(tenant, cap, story, lineage)
    end
  end

  describe "serialize/1" do
    test "returns JSON-serializable map" do
      %{tenant: tenant, story: story, lineage: lineage} = setup_cap_context()
      {:ok, cap} = Capabilities.mint(tenant.id, "start_cap", story.id, lineage)

      serialized = Capabilities.serialize(cap)
      assert serialized.cap_id == cap.id
      assert serialized.typ == "start_cap"
      assert is_binary(serialized.nonce)
      assert is_binary(serialized.signature)

      # Ensure base64url encoded
      assert {:ok, _} = Base.url_decode64(serialized.nonce, padding: false)
    end
  end
end
