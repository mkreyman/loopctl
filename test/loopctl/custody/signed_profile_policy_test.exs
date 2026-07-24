defmodule Loopctl.Custody.SignedProfilePolicyTest do
  @moduledoc """
  LCP-1 §9.3 deployment-level enforcement: the profile switch, the enrolled-only
  gradual-rollout waiver, and signature acceptance/rejection. `verify_request/7`
  takes the profile explicitly so these run async without VM-global config.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.Custody.SignedProfile
  alias Loopctl.Custody.SignedProfilePolicy, as: Policy
  alias Loopctl.Dispatches
  alias Loopctl.Test.CustodyEnrollment

  @gate "verify"
  @work "99999999-9999-9999-9999-999999999999"

  defp enrolled_dispatch(tenant) do
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

    %{dispatch: dispatch, agent_pub: pub, agent_priv: priv} =
      CustodyEnrollment.enroll_root(tenant.id, %{agent_id: agent.id})

    %{dispatch: dispatch, pub: pub, priv: priv}
  end

  defp bearer_dispatch(tenant) do
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

    {:ok, %{dispatch: dispatch}} =
      Dispatches.create_dispatch(tenant.id, %{role: :agent, agent_id: agent.id})

    dispatch
  end

  defp signed_claim(tenant_id, priv, opts \\ []) do
    gate = Keyword.get(opts, :gate, @gate)
    work = Keyword.get(opts, :work, @work)
    cap = Keyword.get(opts, :cap, "cap-1")
    claimed_at = Keyword.get(opts, :claimed_at, 1_760_000_000)

    preimage =
      SignedProfile.claim_preimage("ed25519", tenant_id, gate, work, %{}, cap, claimed_at)

    sig = SignedProfile.sign("ed25519", preimage, priv)

    %{
      "alg" => "ed25519",
      "claim_sig" => Base.encode16(sig, case: :lower),
      "claimed_at" => claimed_at
    }
  end

  setup do
    %{tenant: fixture(:tenant)}
  end

  describe "bearer profile" do
    test "waives the signature entirely, even for an enrolled dispatch", %{tenant: t} do
      %{dispatch: d} = enrolled_dispatch(t)

      assert :ok =
               Policy.verify_request(:bearer, t.id, d.api_key_id, @gate, @work, "cap-1", %{})
    end
  end

  describe "signed profile — gradual rollout" do
    test "a bearer dispatch (no enrolled key) is NOT forced to sign", %{tenant: t} do
      d = bearer_dispatch(t)

      assert :ok =
               Policy.verify_request(:signed, t.id, d.api_key_id, @gate, @work, "cap-1", %{})
    end

    test "a legacy key with no dispatch is NOT forced to sign", %{tenant: t} do
      assert :ok =
               Policy.verify_request(
                 :signed,
                 t.id,
                 Ecto.UUID.generate(),
                 @gate,
                 @work,
                 "cap-1",
                 %{}
               )
    end
  end

  describe "signed profile — enrolled dispatch must sign" do
    test "a valid signature is accepted", %{tenant: t} do
      %{dispatch: d, priv: priv} = enrolled_dispatch(t)
      claim = signed_claim(t.id, priv)

      assert :ok =
               Policy.verify_request(:signed, t.id, d.api_key_id, @gate, @work, "cap-1", claim)
    end

    test "a missing signature is rejected with :claim_signature_required", %{tenant: t} do
      %{dispatch: d} = enrolled_dispatch(t)

      assert {:error, :claim_signature_required} =
               Policy.verify_request(:signed, t.id, d.api_key_id, @gate, @work, "cap-1", %{})
    end

    test "a signature over a DIFFERENT gate does not verify (gate is server-bound)", %{tenant: t} do
      %{dispatch: d, priv: priv} = enrolled_dispatch(t)
      # signed for "report", presented at the "verify" gate
      claim = signed_claim(t.id, priv, gate: "report")

      assert {:error, :invalid_claim_signature} =
               Policy.verify_request(:signed, t.id, d.api_key_id, "verify", @work, "cap-1", claim)
    end

    test "a signature over a DIFFERENT work item does not verify", %{tenant: t} do
      %{dispatch: d, priv: priv} = enrolled_dispatch(t)
      claim = signed_claim(t.id, priv, work: "00000000-0000-0000-0000-000000000000")

      assert {:error, :invalid_claim_signature} =
               Policy.verify_request(:signed, t.id, d.api_key_id, @gate, @work, "cap-1", claim)
    end

    test "a signature by a DIFFERENT agent's key does not verify", %{tenant: t} do
      %{dispatch: d} = enrolled_dispatch(t)
      {_other_pub, other_priv} = :crypto.generate_key(:eddsa, :ed25519)
      claim = signed_claim(t.id, other_priv)

      assert {:error, :invalid_claim_signature} =
               Policy.verify_request(:signed, t.id, d.api_key_id, @gate, @work, "cap-1", claim)
    end

    test "a malformed (non-hex) signature is a clean required-error, not a crash", %{tenant: t} do
      %{dispatch: d} = enrolled_dispatch(t)
      claim = %{"alg" => "ed25519", "claim_sig" => "nothex", "claimed_at" => 1}

      assert {:error, :claim_signature_required} =
               Policy.verify_request(:signed, t.id, d.api_key_id, @gate, @work, "cap-1", claim)
    end

    test "tenant isolation: an enrolled dispatch in tenant A is not resolvable from tenant B", %{
      tenant: t
    } do
      %{dispatch: d, priv: priv} = enrolled_dispatch(t)
      other = fixture(:tenant)
      claim = signed_claim(t.id, priv)

      # Under tenant B, the api_key_id does not resolve to an enrolled dispatch, so
      # the gradual-rollout waiver applies (no cross-tenant key leak).
      assert :ok =
               Policy.verify_request(
                 :signed,
                 other.id,
                 d.api_key_id,
                 @gate,
                 @work,
                 "cap-1",
                 claim
               )
    end
  end

  describe "profile/0 default" do
    test "defaults to :bearer when unconfigured" do
      assert Policy.profile() == :bearer
      assert Policy.profile_string() == "bearer"
    end
  end
end
