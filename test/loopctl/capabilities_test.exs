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
      assert consumed.consumed_at != nil
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
