defmodule Loopctl.ReleaseCustodyProfileTest do
  @moduledoc """
  The signed-custody-profile release command (`bin/loopctl eval
  Loopctl.Release.custody_signed_profile/1`). The `:enable`/`:disable`/`:status`
  helpers are exercised directly (not through `with_admin_repo/1`, which manages
  the repo lifecycle for the ephemeral eval node) so the LOGIC runs in the test
  sandbox.

  `async: false` DELIBERATELY: `set_custody_profile/1` writes the VM-global
  `SystemConfig` `:persistent_term` cache (the same key every deployment node
  reads), so priming it from an `async: true` module would bleed the profile into
  a concurrently-running custody test — mirrors `heavy_read_hnsw_ef_search_test`.
  """
  use Loopctl.DataCase, async: false

  import ExUnit.CaptureIO

  alias Loopctl.Custody.SignedProfilePolicy
  alias Loopctl.Release
  alias Loopctl.SystemConfig
  alias Loopctl.Tenants
  alias Loopctl.Test.CustodyEnrollment

  setup do
    # Restore the shipped default (bearer) after each test so a primed `signed`
    # never leaks past this module — erase mirrors the #488 prime helpers.
    on_exit(fn -> :persistent_term.erase({SystemConfig, SignedProfilePolicy.profile_key()}) end)
    :ok
  end

  # `SignedProfilePolicy.profile/0` is redirected through a process-dict stub in
  # the test env (config/test.exs `:custody_profile_source`), so it does NOT reflect
  # the SystemConfig row the command writes. Assert on the STORED SystemConfig value
  # directly — that is the deployment source of truth the running nodes refresh from
  # and, in prod (no stub), exactly what `profile/0` reads.
  defp stored_profile_code,
    do: SystemConfig.get_int(SignedProfilePolicy.profile_key(), 0)

  describe "custody_signed_profile enable/disable" do
    test "enable writes signed (1); disable restores bearer (0)" do
      assert capture_io(fn -> Release.set_custody_profile(1) end) =~ "signed"
      assert stored_profile_code() == 1

      assert capture_io(fn -> Release.set_custody_profile(0) end) =~ "bearer"
      assert stored_profile_code() == 0
    end

    test "the written value survives a cache refresh (it is persisted, not just cached)" do
      capture_io(fn -> Release.set_custody_profile(1) end)
      # Drop the local cache entirely, then reload from the DB — proves the write
      # landed in the durable SystemConfig row the running nodes refresh from.
      :persistent_term.erase({SystemConfig, SignedProfilePolicy.profile_key()})
      SystemConfig.refresh()
      assert stored_profile_code() == 1
    end
  end

  describe "custody_signed_profile status" do
    test "status reports the profile and the enforcement/KB-safety boundary" do
      out = capture_io(fn -> Release.print_custody_profile_status() end)

      assert out =~ "signed custody profile"
      assert out =~ "enrolled agent keys"
      # The line that answers 'can this lock me out of my KB?' — it must be explicit.
      assert out =~ "NOT gated by this switch"
      assert out =~ "Knowledge Wiki"
    end

    test "status flags a signed-but-inert deployment (0 enrolled agents)" do
      capture_io(fn -> Release.set_custody_profile(1) end)
      out = capture_io(fn -> Release.print_custody_profile_status() end)
      assert out =~ "INERT"
    end

    test "status names the bulk-refusal footgun under signed" do
      out = capture_io(fn -> Release.print_custody_profile_status() end)
      assert out =~ "bulk custody paths"
      assert out =~ "bulk_signature_unsupported"
    end

    test "status does not crash on an out-of-range stored value (fail-safe, not FunctionClauseError)" do
      # Reachable out-of-band: direct SQL, a raw SystemConfig.put/2, a future admin
      # API — set_custody_profile/1 guards [0,1] but the row is not otherwise pinned.
      {:ok, _} = SystemConfig.put(SignedProfilePolicy.profile_key(), 7)
      SystemConfig.refresh()

      out = capture_io(fn -> assert Release.print_custody_profile_status() == :ok end)
      assert out =~ "unknown"
      assert out =~ "custody_signed_profile_enforcement=7"
    end
  end

  describe "deployment counters" do
    test "count_enrolled_agent_keys counts active signing keys" do
      assert Release.count_enrolled_agent_keys() == 0

      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      CustodyEnrollment.enroll_root(tenant.id, %{agent_id: agent.id})

      assert Release.count_enrolled_agent_keys() == 1
    end

    test "count_owner_key_tenants counts tenants that registered an owner key" do
      assert Release.count_owner_key_tenants() == 0

      tenant = fixture(:tenant)
      {pub, _priv} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, _} = Tenants.register_custody_owner_key(tenant.id, pub, "ed25519")

      assert Release.count_owner_key_tenants() == 1
    end
  end

  test "an unknown action is rejected without touching config" do
    assert capture_io(fn ->
             assert Release.custody_signed_profile(:bogus) == {:error, :unknown_action}
           end) =~ "Unknown action"
  end
end
