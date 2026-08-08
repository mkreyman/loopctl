defmodule Loopctl.CapabilitiesTest do
  @moduledoc """
  Tests for US-26.3.1 — Capability token mint/verify/consume.
  """

  use Loopctl.DataCase, async: true

  import Loopctl.Fixtures

  alias Loopctl.Capabilities

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

  describe "mint/4 checks its own signature against the advertised key" do
    # The private key comes from a node-LOCAL ETS cache. A rotation reaches peers over
    # PubSub, but a DROPPED broadcast would leave this node signing with the superseded
    # key — and a token signed by a retired key is chained as `capability_forged`
    # (`byzantine: true`) when it is spent. The mint refuses to be the source of that.

    defp mint_context do
      tenant = fixture(:tenant, %{audit_signing_public_key: :crypto.strong_rand_bytes(32)})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      {advertised_pub, live_priv} = :crypto.generate_key(:eddsa, :ed25519)
      {_retired_pub, retired_priv} = :crypto.generate_key(:eddsa, :ed25519)

      tenant =
        tenant
        |> Ecto.Changeset.change(audit_signing_public_key: advertised_pub)
        |> Loopctl.AdminRepo.update!()

      Loopctl.TenantKeys.init_cache()

      %{
        tenant: tenant,
        story: story,
        lineage: [Ecto.UUID.generate()],
        live_priv: live_priv,
        retired_priv: retired_priv
      }
    end

    test "a stale cached key busts the entry and re-signs off the rotated-in key" do
      %{tenant: tenant, story: story, lineage: lineage} =
        ctx = mint_context()

      # First fetch answers with the key the rotation RETIRED (this node's cache had not
      # observed the rotation); the second, after the self-check busts it, is current.
      Mox.expect(Loopctl.MockSecrets, :get, fn _name -> {:ok, ctx.retired_priv} end)
      Mox.expect(Loopctl.MockSecrets, :get, fn _name -> {:ok, ctx.live_priv} end)

      assert {:ok, cap} = Capabilities.mint(tenant.id, "start_cap", story.id, lineage)

      # And the token it did persist is one the tenant's advertised key verifies — i.e. the
      # recovery re-signed rather than merely retrying the insert.
      assert {:ok, _} =
               Capabilities.verify(tenant.id, %{
                 "cap_id" => cap.id,
                 "typ" => "start_cap",
                 "story_id" => story.id,
                 "lineage" => lineage
               })
    end

    test "a key that still mismatches after a fresh fetch refuses to mint" do
      %{tenant: tenant, story: story, lineage: lineage} = ctx = mint_context()

      Mox.stub(Loopctl.MockSecrets, :get, fn _name -> {:ok, ctx.retired_priv} end)

      # Refusing is strictly better than persisting a token that reads as a forgery: a mint
      # failure is already handled (the custody op proceeds capability-less and says so).
      assert {:error, {:key_unavailable, :signing_key_mismatch}} =
               Capabilities.mint(tenant.id, "start_cap", story.id, lineage)

      assert Capabilities.list_for_lineage(tenant.id, story.id, lineage) == []
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
