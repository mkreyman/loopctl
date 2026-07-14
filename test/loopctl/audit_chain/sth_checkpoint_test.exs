defmodule Loopctl.AuditChain.SthCheckpointTest do
  @moduledoc """
  US-35.1 — Incremental STH: checkpointed Merkle peaks, byte-identical root.

  The BYTE-IDENTICAL invariant (AC-35.1.2) is the gate: the incremental fold
  over a checkpoint's stable peaks must reproduce the current `merkle_tree/2`
  construction EXACTLY, for every chain length and every checkpoint split point,
  or historical STHs / external witness caches stop verifying.
  """

  use Loopctl.DataCase, async: true

  import Loopctl.Fixtures

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.AuditChain.SthCheckpoint
  alias Loopctl.AuditChain.Verifier

  setup :verify_on_exit!

  # --- helpers ---

  defp make_entry(overrides \\ %{}) do
    Map.merge(
      %{
        action: "test_event",
        actor_lineage: ["test"],
        entity_type: "test",
        payload: %{"k" => "v"}
      },
      overrides
    )
  end

  defp build_chain(tenant_id, count) do
    for _ <- 1..count, do: {:ok, _} = AuditChain.append(tenant_id, make_entry())
    :ok
  end

  defp entry_hashes(tenant_id) do
    import Ecto.Query

    from(e in AuditChain.Entry,
      where: e.tenant_id == ^tenant_id,
      order_by: [asc: e.chain_position],
      select: e.entry_hash
    )
    |> AdminRepo.all()
  end

  # Independent oracle — a direct transcription of `AuditChain.merkle_tree/2`
  # (the reference construction), used ONLY in tests to build expected peaks and
  # roots without touching the module-under-test's internal fold.
  defp oracle_root([single]), do: single

  defp oracle_root(hashes) do
    padded =
      if rem(length(hashes), 2) == 1, do: hashes ++ [List.last(hashes)], else: hashes

    padded
    |> Enum.chunk_every(2)
    |> Enum.map(fn [a, b] -> :crypto.hash(:sha256, a <> b) end)
    |> oracle_root()
  end

  # Independent construction of a checkpoint's stable peaks for the first `count`
  # leaves: slice into descending power-of-2 blocks (the set bits of `count`) and
  # take the oracle Merkle root of each complete block. This does NOT reuse the
  # module's MMR fold, so agreement is a real cross-check.
  defp expected_peaks(hashes, count) do
    import Bitwise

    heights =
      0..63 |> Enum.filter(fn b -> (count >>> b &&& 1) == 1 end) |> Enum.reverse()

    {peaks, _rest} =
      Enum.reduce(heights, {[], hashes}, fn h, {acc, remaining} ->
        {block, rest} = Enum.split(remaining, Bitwise.bsl(1, h))
        {[oracle_root(block) | acc], rest}
      end)

    Enum.reverse(peaks)
  end

  defp put_checkpoint(tenant_id, chain_position, peaks) do
    %SthCheckpoint{tenant_id: tenant_id}
    |> SthCheckpoint.changeset(%{chain_position: chain_position, peaks: peaks})
    |> AdminRepo.insert!(
      on_conflict: {:replace, [:chain_position, :peaks, :updated_at]},
      conflict_target: [:tenant_id]
    )
  end

  defp get_checkpoint(tenant_id) do
    import Ecto.Query
    AdminRepo.one(from(c in SthCheckpoint, where: c.tenant_id == ^tenant_id))
  end

  # STH-signing setup mirroring sth_test.exs: a tenant whose audit public key
  # matches the mocked ed25519 private key, so signatures verify.
  defp setup_signing_tenant(count) do
    tenant = fixture(:tenant, %{slug: "sth-cp-#{System.unique_integer([:positive])}"})
    {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    Mox.expect(Loopctl.MockSecrets, :get, fn _name -> {:ok, priv} end)
    Loopctl.TenantKeys.init_cache()

    {matching_pub, _} = :crypto.generate_key(:eddsa, :ed25519, priv)

    tenant =
      tenant
      |> Ecto.Changeset.change(audit_signing_public_key: matching_pub)
      |> AdminRepo.update!()

    :ok = build_chain(tenant.id, count)
    {tenant, matching_pub}
  end

  # --- TC-35.1.1 — BYTE-IDENTICAL ROOT (the gate) ---

  describe "compute_merkle_root_incremental/1 — byte-identical to merkle_tree/2 (AC-35.1.2)" do
    @ns [1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31, 32, 33, 40]

    test "matches the full-rebuild oracle for a wide range of N and every split point" do
      for n <- @ns do
        tenant = fixture(:tenant, %{slug: "sth-prop-#{n}-#{System.unique_integer([:positive])}"})
        :ok = build_chain(tenant.id, n)

        hashes = entry_hashes(tenant.id)
        expected = oracle_root(hashes)

        # sanity: the current full construction equals our independent oracle
        assert {:ok, ^expected} = AuditChain.compute_merkle_root(tenant.id)

        # For every checkpoint split point p (leaves covered, 1..n-1), persist a
        # checkpoint at position p-1 and assert the incremental fold reproduces
        # the same root byte-for-byte. p = 0 (no checkpoint) is covered by the
        # fallback test below.
        for p <- 1..(n - 1)//1 do
          {prefix, _tail} = Enum.split(hashes, p)
          put_checkpoint(tenant.id, p - 1, expected_peaks(prefix, p))

          assert {:ok, root, %{chain_position: pos, peaks: _}} =
                   AuditChain.compute_merkle_root_incremental(tenant.id)

          assert pos == n - 1
          assert root == expected, "N=#{n}, split p=#{p}: incremental root diverged from oracle"
          assert byte_size(root) == 32
        end
      end
    end

    test "folds the empty tail (checkpoint already at head) to the same root" do
      n = 33
      tenant = fixture(:tenant)
      :ok = build_chain(tenant.id, n)
      hashes = entry_hashes(tenant.id)
      expected = oracle_root(hashes)

      # checkpoint covers ALL leaves — no tail to fold, peaks bagged directly
      put_checkpoint(tenant.id, n - 1, expected_peaks(hashes, n))

      assert {:ok, ^expected, %{chain_position: 32}} =
               AuditChain.compute_merkle_root_incremental(tenant.id)
    end

    test "returns {:ok, nil, nil} for an empty chain" do
      tenant = fixture(:tenant)
      assert {:ok, nil, nil} = AuditChain.compute_merkle_root_incremental(tenant.id)
    end
  end

  # --- TC-35.1.3 — no checkpoint falls back, then persists (AC-35.1.1 / AC-35.1.3) ---

  describe "no checkpoint (AC-35.1.1)" do
    test "falls back to the full construction and equals merkle_tree/2 output" do
      tenant = fixture(:tenant)
      :ok = build_chain(tenant.id, 6)

      refute get_checkpoint(tenant.id)

      {:ok, full} = AuditChain.compute_merkle_root(tenant.id)

      assert {:ok, root, %{chain_position: 5, peaks: peaks}} =
               AuditChain.compute_merkle_root_incremental(tenant.id)

      assert root == full
      # 6 = 0b110 → two peaks
      assert length(peaks) == 2
    end

    test "sign_and_store_tree_head persists a consistent checkpoint for next time (AC-35.1.3)" do
      {tenant, _pub} = setup_signing_tenant(5)

      refute get_checkpoint(tenant.id)

      assert {:ok, sth} = AuditChain.sign_and_store_tree_head(tenant.id)

      checkpoint = get_checkpoint(tenant.id)
      assert checkpoint.chain_position == sth.chain_position
      assert checkpoint.chain_position == 4
      # 5 leaves = 0b101 → two peaks, each a 32-byte hash
      assert length(checkpoint.peaks) == 2
      assert Enum.all?(checkpoint.peaks, &(byte_size(&1) == 32))

      # the stored root still equals the full oracle at that position
      {:ok, full} = AuditChain.compute_merkle_root(tenant.id)
      assert sth.merkle_root == full
    end
  end

  # --- TC-35.1.2 — end-to-end sign + verify via incremental path (AC-35.1.4) ---

  describe "sign_and_store_tree_head/1 via the incremental path (AC-35.1.4)" do
    test "signs an STH whose root matches the full rebuild and verifies with Verifier" do
      {tenant, pub_key} = setup_signing_tenant(3)

      assert {:ok, sth} = AuditChain.sign_and_store_tree_head(tenant.id)

      {:ok, full_root} = AuditChain.compute_merkle_root(tenant.id)
      assert sth.merkle_root == full_root
      assert sth.chain_position == 2
      assert {:ok, true} = Verifier.verify_sth(sth, pub_key)
    end

    test "a later STH after more appends folds the tail and still verifies" do
      {tenant, pub_key} = setup_signing_tenant(3)

      {:ok, _first} = AuditChain.sign_and_store_tree_head(tenant.id)

      # append past the checkpoint, then re-sign incrementally
      :ok = build_chain(tenant.id, 4)

      assert {:ok, sth2} = AuditChain.sign_and_store_tree_head(tenant.id)

      {:ok, full_root} = AuditChain.compute_merkle_root(tenant.id)
      assert sth2.chain_position == 6
      assert sth2.merkle_root == full_root
      assert {:ok, true} = Verifier.verify_sth(sth2, pub_key)

      # checkpoint advanced to the head
      assert get_checkpoint(tenant.id).chain_position == 6
    end
  end

  # --- TC-35.1.4 — stale/corrupt checkpoint degrades to a correct rebuild (AC-35.1.5) ---

  describe "corrupt/stale checkpoint (AC-35.1.5)" do
    test "position ahead of the chain head → full rebuild, correct root" do
      tenant = fixture(:tenant)
      :ok = build_chain(tenant.id, 9)
      {:ok, full} = AuditChain.compute_merkle_root(tenant.id)

      # checkpoint claims a head 10 positions past reality (partial/stale write)
      hashes = entry_hashes(tenant.id)
      put_checkpoint(tenant.id, 18, expected_peaks(hashes, 9))

      assert {:ok, root, %{chain_position: 8}} =
               AuditChain.compute_merkle_root_incremental(tenant.id)

      assert root == full
    end

    test "peaks count inconsistent with the covered leaf count → full rebuild, correct root" do
      tenant = fixture(:tenant)
      :ok = build_chain(tenant.id, 9)
      {:ok, full} = AuditChain.compute_merkle_root(tenant.id)

      # position 4 ⇒ 5 leaves ⇒ popcount(5)=2 peaks expected; store garbage 3
      put_checkpoint(tenant.id, 4, [
        :crypto.strong_rand_bytes(32),
        :crypto.strong_rand_bytes(32),
        :crypto.strong_rand_bytes(32)
      ])

      assert {:ok, root, %{chain_position: 8}} =
               AuditChain.compute_merkle_root_incremental(tenant.id)

      assert root == full
    end

    test "a malformed (non-32-byte) peak → full rebuild, correct root" do
      tenant = fixture(:tenant)
      :ok = build_chain(tenant.id, 4)
      {:ok, full} = AuditChain.compute_merkle_root(tenant.id)

      # position 3 ⇒ 4 leaves ⇒ 1 peak expected, but it's the wrong size
      put_checkpoint(tenant.id, 3, [<<0, 1, 2>>])

      assert {:ok, root, _} = AuditChain.compute_merkle_root_incremental(tenant.id)
      assert root == full
    end
  end

  # --- TC-35.1.5 — tenant isolation (AC-35.1.6) ---

  describe "tenant isolation (AC-35.1.6)" do
    test "incremental compute for tenant A never reads tenant B's entries or peaks" do
      tenant_a = fixture(:tenant, %{slug: "sth-iso-a-#{System.unique_integer([:positive])}"})
      tenant_b = fixture(:tenant, %{slug: "sth-iso-b-#{System.unique_integer([:positive])}"})

      :ok = build_chain(tenant_a.id, 7)
      :ok = build_chain(tenant_b.id, 5)

      hashes_a = entry_hashes(tenant_a.id)
      hashes_b = entry_hashes(tenant_b.id)
      {:ok, full_a} = AuditChain.compute_merkle_root(tenant_a.id)
      {:ok, full_b} = AuditChain.compute_merkle_root(tenant_b.id)

      # both tenants carry a checkpoint at an intermediate split
      put_checkpoint(tenant_a.id, 3, expected_peaks(Enum.take(hashes_a, 4), 4))
      put_checkpoint(tenant_b.id, 1, expected_peaks(Enum.take(hashes_b, 2), 2))

      assert {:ok, root_a, %{chain_position: 6}} =
               AuditChain.compute_merkle_root_incremental(tenant_a.id)

      assert root_a == full_a
      # A's root is derived only from A's chain, distinct from B's
      refute root_a == full_b

      # B is unaffected and independently correct
      assert {:ok, ^full_b, %{chain_position: 4}} =
               AuditChain.compute_merkle_root_incremental(tenant_b.id)
    end

    test "checkpoints are one-per-tenant and isolated by tenant_id" do
      tenant_a = fixture(:tenant, %{slug: "sth-iso2-a-#{System.unique_integer([:positive])}"})
      tenant_b = fixture(:tenant, %{slug: "sth-iso2-b-#{System.unique_integer([:positive])}"})

      :ok = build_chain(tenant_a.id, 4)
      :ok = build_chain(tenant_b.id, 4)

      put_checkpoint(tenant_a.id, 3, expected_peaks(entry_hashes(tenant_a.id), 4))

      assert get_checkpoint(tenant_a.id)
      refute get_checkpoint(tenant_b.id)
    end
  end
end
