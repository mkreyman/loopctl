defmodule Loopctl.ReleaseCustodyProfileTest do
  @moduledoc """
  The signed-custody-profile release command (`bin/loopctl eval
  Loopctl.Release.custody_signed_profile/1`). The `:enable`/`:disable`/`:status`
  helpers are exercised directly (not through `with_admin_repo/1`, which manages
  the repo lifecycle for the ephemeral eval node) so the LOGIC runs in the test
  sandbox.

  Each test hands the helpers its OWN `SystemConfig` namespace (`set_custody_profile/2`,
  `print_custody_profile_status/1`), so the row they write and refresh is cached where no
  other test reads it, and the node-wide custody profile every custody test reads never
  moves.
  """
  use Loopctl.DataCase, async: true

  import ExUnit.CaptureIO

  alias Loopctl.Custody.SignedProfilePolicy
  alias Loopctl.Release
  alias Loopctl.SystemConfig
  alias Loopctl.Tenants
  alias Loopctl.Test.CustodyEnrollment

  setup do
    # `refresh/1` loads EVERY row this test's sandbox can see into its namespace — an ETS
    # table this test process owns, so all of it is gone when the test exits.
    {:ok, cache: :ets.new(:custody_profile_config, [:set, :public])}
  end

  # `SignedProfilePolicy.profile/0` is redirected through a process-dict stub in
  # the test env (config/test.exs `:custody_profile_source`), so it does NOT reflect
  # the SystemConfig row the command writes. Assert on the STORED SystemConfig value
  # directly — that is the deployment source of truth the running nodes refresh from
  # and, in prod (no stub), exactly what `profile/0` reads.
  defp stored_profile_code(cache),
    do: SystemConfig.get_int(SignedProfilePolicy.profile_key(), 0, cache)

  describe "custody_signed_profile enable/disable" do
    test "enable writes signed (1); disable restores bearer (0)", %{cache: cache} do
      node_wide = {SystemConfig, SignedProfilePolicy.profile_key()}
      before = :persistent_term.get(node_wide, :unset)

      assert capture_io(fn -> Release.set_custody_profile(1, cache) end) =~ "signed"
      assert stored_profile_code(cache) == 1

      assert :persistent_term.get(node_wide, :unset) == before,
             "the flip must land in this test's namespace, never the node-wide profile " <>
               "every custody test reads"

      assert capture_io(fn -> Release.set_custody_profile(0, cache) end) =~ "bearer"
      assert stored_profile_code(cache) == 0
    end

    test "the written value survives a cache refresh (it is persisted, not just cached)", %{
      cache: cache
    } do
      capture_io(fn -> Release.set_custody_profile(1, cache) end)
      # Drop the local cache entirely, then reload from the DB — proves the write
      # landed in the durable SystemConfig row the running nodes refresh from.
      :ets.delete(cache, SignedProfilePolicy.profile_key())
      SystemConfig.refresh(cache)
      assert stored_profile_code(cache) == 1
    end
  end

  describe "custody_signed_profile status" do
    test "status reports the profile and the enforcement/KB-safety boundary", %{cache: cache} do
      out = capture_io(fn -> Release.print_custody_profile_status(cache) end)

      assert out =~ "signed custody profile"
      assert out =~ "enrolled dispatches"
      # The line that answers 'can this lock me out of my KB?' — it must be explicit.
      assert out =~ "NOT gated by this switch"
      assert out =~ "Knowledge Wiki"
    end

    test "status flags a signed-but-inert deployment (0 enrolled agents)", %{cache: cache} do
      capture_io(fn -> Release.set_custody_profile(1, cache) end)
      out = capture_io(fn -> Release.print_custody_profile_status(cache) end)
      assert out =~ "INERT"
    end

    test "status names the bulk-refusal footgun under signed", %{cache: cache} do
      out = capture_io(fn -> Release.print_custody_profile_status(cache) end)
      assert out =~ "bulk custody paths"
      assert out =~ "bulk_signature_unsupported"
    end

    test "status does not crash on an out-of-range stored value (fail-safe, not FunctionClauseError)",
         %{cache: cache} do
      # Reachable out-of-band: direct SQL, a raw SystemConfig.put/2, a future admin
      # API — set_custody_profile/1 guards [0,1] but the row is not otherwise pinned.
      {:ok, _} = SystemConfig.put(SignedProfilePolicy.profile_key(), 7, cache)
      SystemConfig.refresh(cache)

      out = capture_io(fn -> assert Release.print_custody_profile_status(cache) == :ok end)
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

  # SCOPE LIMIT (same as the TierCapabilities scan): matches `plug
  # RequireSignedClaim` in SOURCE TEXT under lib/loopctl_web with/without the full
  # alias and with/without parens. A mount injected by a shared `use`/macro would
  # be invisible to it. Defined BEFORE the describe that reads them (module
  # attributes are positional).
  @signed_claim_scan_glob "lib/loopctl_web/**/*.ex"
  @signed_claim_plug "lib/loopctl_web/plugs/require_signed_claim.ex"

  # The custody controllers that legitimately gate a report/review-complete/verify
  # (single-item or bulk) transition — the ONLY places RequireSignedClaim belongs.
  @custody_controllers ~w(
    LoopctlWeb.StoryStatusController
    LoopctlWeb.ReviewRecordController
    LoopctlWeb.StoryVerificationController
    LoopctlWeb.BulkOperationsController
  )

  describe "KB-safety invariant — RequireSignedClaim mount set (drift guard)" do
    # The :status output above promises the signed switch does NOT gate the
    # Knowledge Wiki, memory, the context retriever, or ANY read path ("NOT gated
    # by this switch", "KB access cannot be lost by enabling this"). That claim is
    # only TRUE while RequireSignedClaim is mounted ONLY on the single-item + bulk
    # CUSTODY controllers. The status test above asserts the CLAIM text is printed;
    # this test binds the claim to the real mount set — mirroring the
    # TierCapabilities RequireHumanAnchor source-scan — so a future mount on a
    # KB/read/memory route fails HERE, loudly, instead of silently falsifying the
    # operator-facing safety text.
    test "RequireSignedClaim is mounted ONLY on the custody controllers" do
      mounted =
        @signed_claim_scan_glob
        |> Path.wildcard()
        |> Enum.reject(&(&1 == @signed_claim_plug))
        |> Enum.filter(&(&1 |> File.read!() |> mounts_signed_claim?()))
        |> Enum.map(&defmodule_name/1)
        |> Enum.sort()

      assert mounted == Enum.sort(@custody_controllers),
             """
             RequireSignedClaim mount set drifted from the custody controllers.

             The release :status output promises the signed switch does NOT gate the
             Knowledge Wiki, agent memory, the context retriever, or any read path.
             A mount OUTSIDE the custody set breaks that safety claim — fix the mount
             (or, if a new custody controller is legitimate, update @custody_controllers
             AND the status text together). Do NOT relax this test.

             Unexpected mounts (breaks the KB-safety claim): #{inspect(mounted -- Enum.sort(@custody_controllers))}
             Missing expected mounts:                        #{inspect(Enum.sort(@custody_controllers) -- mounted)}
             """
    end
  end

  defp mounts_signed_claim?(source) do
    String.match?(source, ~r/^\s*plug[\s(]+(LoopctlWeb\.Plugs\.)?RequireSignedClaim\b/m)
  end

  defp defmodule_name(path) do
    case Regex.run(~r/^defmodule\s+([\w.]+)\s+do/m, File.read!(path)) do
      [_, module] -> module
      nil -> flunk("could not read a defmodule name out of #{path}")
    end
  end
end
