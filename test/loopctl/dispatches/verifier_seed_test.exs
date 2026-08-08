defmodule Loopctl.Dispatches.VerifierSeedTest do
  @moduledoc """
  `select_verifier/3` is deterministic on purpose — the orchestrator must not be able
  to re-roll until it likes the answer. Determinism is only safe while the SEED is
  secret: the candidate pool is enumerable by any agent key and the story id is known,
  so everything else in the computation is already public.

  The seed is keyed by the tenant's audit signing PRIVATE key (secret store,
  server-side only), never by the public key that the discovery endpoint serves
  unauthenticated. With no secret available there is nothing to fall back on that
  would not restore predictability, so selection fails closed.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.Dispatches

  setup :verify_on_exit!

  # Fixed, valid UUIDs so the test's inputs — and therefore its outcome — are identical
  # on every run: this comparison must never be able to flake.
  defp story_ids do
    for i <- 1..20, do: "00000000-0000-4000-8000-#{String.pad_leading("#{i}", 12, "0")}"
  end

  # TenantKeys caches per tenant for 5 minutes, so a test that swaps the key must
  # invalidate — otherwise it would silently measure the first key twice.
  defp stub_tenant_key(tenant_id, key) do
    Mox.stub(Loopctl.MockSecrets, :get, fn _name -> {:ok, Base.encode64(key)} end)
    Loopctl.TenantKeys.invalidate(tenant_id)
  end

  defp tenant_with_pubkey do
    {pub, _priv} = :crypto.generate_key(:eddsa, :ed25519)
    fixture(:tenant, %{audit_signing_public_key: pub})
  end

  defp root_dispatch(tenant_id) do
    agent = fixture(:agent, %{tenant_id: tenant_id, agent_type: :implementer})

    {:ok, %{dispatch: dispatch}} =
      Dispatches.create_dispatch(tenant_id, %{role: :agent, agent_id: agent.id})

    dispatch
  end

  describe "select_verifier/3 seeding" do
    test "fails closed when no server-side seed secret is available" do
      # The DataCase default stubs MockSecrets.get to {:error, :not_found}, i.e. a
      # tenant whose audit key is not provisioned.
      tenant = tenant_with_pubkey()
      _pool = [root_dispatch(tenant.id), root_dispatch(tenant.id)]

      assert {:error, :verifier_seed_unavailable} =
               Dispatches.select_verifier(tenant.id, Enum.at(story_ids(), 0), [])
    end

    test "selects from the eligible pool when the tenant key is available" do
      tenant = tenant_with_pubkey()
      pool = [root_dispatch(tenant.id), root_dispatch(tenant.id)]
      stub_tenant_key(tenant.id, :crypto.strong_rand_bytes(32))

      assert {:ok, picked} = Dispatches.select_verifier(tenant.id, Enum.at(story_ids(), 0), [])
      assert picked.id in Enum.map(pool, & &1.id)
    end

    test "is deterministic for the same tenant key and story" do
      tenant = tenant_with_pubkey()
      _pool = [root_dispatch(tenant.id), root_dispatch(tenant.id)]
      stub_tenant_key(tenant.id, :crypto.strong_rand_bytes(32))
      story_id = Enum.at(story_ids(), 0)

      assert {:ok, first} = Dispatches.select_verifier(tenant.id, story_id, [])
      assert {:ok, second} = Dispatches.select_verifier(tenant.id, story_id, [])
      assert first.id == second.id
    end

    test "the pick depends on the PRIVATE key, not on the public one" do
      # Same tenant (so the same public key, the same pool, the same story ids) under
      # two different private keys. If the seed were derived from anything public, every
      # pick would be identical across the two runs.
      tenant = tenant_with_pubkey()
      _pool = [root_dispatch(tenant.id), root_dispatch(tenant.id)]

      picks_a = picks_with_key(tenant.id, <<1::256>>)
      picks_b = picks_with_key(tenant.id, <<2::256>>)

      assert picks_a != picks_b
    end
  end

  describe "select_verifier/3 empty-pool causes" do
    test "no active dispatch at all is :no_eligible_verifier" do
      tenant = tenant_with_pubkey()

      assert {:error, :no_eligible_verifier} =
               Dispatches.select_verifier(tenant.id, Enum.at(story_ids(), 0), [])
    end

    test "a single-root tenant is :no_independent_root, not a pool miss" do
      # Only the OPERATOR key may start a tree, so a tenant whose orchestrator runs on
      # its own dispatch has exactly one root and no principal that can verify: the
      # verify gate is root-separated. That is a standing operator action (mint an
      # independently-rooted verifier tree), not a transient shortage, so it must not
      # be reported as one.
      tenant = tenant_with_pubkey()
      impl = root_dispatch(tenant.id)

      assert {:error, :no_independent_root} =
               Dispatches.select_verifier(tenant.id, Enum.at(story_ids(), 0), impl.lineage_path)
    end
  end

  defp picks_with_key(tenant_id, key) do
    stub_tenant_key(tenant_id, key)

    Enum.map(story_ids(), fn story_id ->
      {:ok, picked} = Dispatches.select_verifier(tenant_id, story_id, [])
      picked.id
    end)
  end
end
