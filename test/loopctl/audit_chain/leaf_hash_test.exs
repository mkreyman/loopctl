defmodule Loopctl.AuditChain.LeafHashTest do
  @moduledoc """
  Conformance tests for the LCP-1 §8 leaf-hash construction, and the §8.5
  guarantee that a v2 hash reproduces from stored content after a jsonb
  round-trip. Every assertion cites the clause it exercises.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.AuditChain.Entry
  alias Loopctl.AuditChain.LeafHash

  @tenant "33333333-3333-3333-3333-333333333333"
  @entity "44444444-4444-4444-4444-444444444444"
  @prev :binary.copy(<<0>>, 32)
  @at ~U[2026-07-23 00:00:00.000000Z]

  defp fields(overrides \\ %{}) do
    Map.merge(
      %{
        tenant_id: @tenant,
        position: 0,
        prev_hash: @prev,
        action: "event_created",
        actor_lineage: ["dispatch-a"],
        entity_type: "story",
        entity_id: @entity,
        payload: %{"a" => 1, "b" => 2},
        inserted_at: @at
      },
      overrides
    )
  end

  describe "LCP-1 §8.3 canonical_json" do
    test "object keys are sorted regardless of insertion order" do
      a = LeafHash.canonical_json(%{"z" => 1, "a" => 2, "m" => 3})
      b = LeafHash.canonical_json(%{"a" => 2, "m" => 3, "z" => 1})
      assert a == b
      assert a == ~s({"a":2,"m":3,"z":1})
    end

    test "atom keys and string keys produce identical output (the jsonb round-trip case)" do
      assert LeafHash.canonical_json(%{a: 1, b: 2}) ==
               LeafHash.canonical_json(%{"a" => 1, "b" => 2})
    end

    test "sorting is by UTF-8 octet order, so uppercase precedes lowercase" do
      # 'Z' (0x5A) < 'a' (0x61) in octet order, unlike a case-insensitive sort.
      assert LeafHash.canonical_json(%{"a" => 1, "Z" => 2}) == ~s({"Z":2,"a":1})
    end

    test "keys differing only past a common prefix sort correctly" do
      assert LeafHash.canonical_json(%{"abc" => 1, "ab" => 2}) == ~s({"ab":2,"abc":1})
    end

    test "nesting is canonicalized recursively" do
      assert LeafHash.canonical_json(%{"outer" => %{"z" => 1, "a" => 2}}) ==
               ~s({"outer":{"a":2,"z":1}})
    end

    test "empty object and empty array" do
      assert LeafHash.canonical_json(%{}) == "{}"
      assert LeafHash.canonical_json([]) == "[]"
    end

    test "array element order is preserved (arrays are ordered, objects are not)" do
      assert LeafHash.canonical_json([3, 1, 2]) == "[3,1,2]"
    end

    test "serialization failure raises rather than substituting a placeholder (§8.2)" do
      assert_raise Protocol.UndefinedError, fn ->
        LeafHash.canonical_json(%{"k" => self()})
      end
    end

    test "numbers are normalized so an integral float equals the integer jsonb decodes it to" do
      # PostgreSQL jsonb stores 1.0e22 and hands it back as the integer
      # 10000000000000000000000. Both must canonicalize identically or a legitimate
      # float payload becomes a FALSE tampering positive.
      assert LeafHash.canonical_json(1.0e22) ==
               LeafHash.canonical_json(10_000_000_000_000_000_000_000)

      assert LeafHash.canonical_json(100.0) == LeafHash.canonical_json(100)
      assert LeafHash.canonical_json(-1.5e3) == LeafHash.canonical_json(-1500)

      assert LeafHash.canonical_json(1.0e23) ==
               LeafHash.canonical_json(100_000_000_000_000_000_000_000)
    end

    test "fractional floats and Decimal scale normalize to one canonical decimal string" do
      assert LeafHash.canonical_json(3.14) == "3.14"
      assert LeafHash.canonical_json(1.0e-7) == "0.0000001"
      # A Decimal with trailing-zero scale collapses to the same string as its value.
      assert LeafHash.canonical_json(Decimal.new("100.00")) == LeafHash.canonical_json(100)
      assert LeafHash.canonical_json(Decimal.new("3.140")) == "3.14"
    end
  end

  describe "LCP-1 §8.2 v2 construction" do
    test "is deterministic" do
      assert LeafHash.compute(fields(), 2) == LeafHash.compute(fields(), 2)
      assert byte_size(LeafHash.compute(fields(), 2)) == 32
    end

    test "is independent of payload key insertion order" do
      ordered = LeafHash.compute(fields(%{payload: %{"a" => 1, "b" => 2}}), 2)
      reordered = LeafHash.compute(fields(%{payload: %{"b" => 2, "a" => 1}}), 2)
      assert ordered == reordered
    end

    test "PRESENT distinguishes an absent entity_id from a present-but-empty one (§8.2)" do
      absent = LeafHash.compute(fields(%{entity_id: nil}), 2)
      empty = LeafHash.compute(fields(%{entity_id: ""}), 2)
      refute absent == empty
    end

    test "is sensitive to every hashed field" do
      base = LeafHash.compute(fields(), 2)

      for override <- [
            %{tenant_id: "55555555-5555-5555-5555-555555555555"},
            %{position: 1},
            %{prev_hash: :binary.copy(<<1>>, 32)},
            %{action: "event_deleted"},
            %{actor_lineage: ["dispatch-b"]},
            %{entity_type: "epic"},
            %{entity_id: "66666666-6666-6666-6666-666666666666"},
            %{payload: %{"a" => 1, "b" => 3}},
            %{inserted_at: ~U[2026-07-23 00:00:01.000000Z]}
          ] do
        refute LeafHash.compute(fields(override), 2) == base,
               "hash was insensitive to #{inspect(override)}"
      end
    end

    test "the tenant_id leads the preimage — an entry cannot be replayed across tenants" do
      a = LeafHash.compute(fields(%{tenant_id: @tenant}), 2)
      b = LeafHash.compute(fields(%{tenant_id: "77777777-7777-7777-7777-777777777777"}), 2)
      refute a == b
    end
  end

  describe "LCP-1 §8.4 version separation" do
    test "v1 and v2 produce different hashes for the same fields" do
      refute LeafHash.compute(fields(), 1) == LeafHash.compute(fields(), 2)
    end

    test "current_version is 2" do
      assert LeafHash.current_version() == 2
    end

    test "an unknown hash_version raises instead of crashing with a FunctionClauseError" do
      # A tamper-detection path must fail loudly and legibly on a version it cannot
      # construct, not raise an opaque clause error (the DB CHECK keeps this
      # unreachable for well-formed rows).
      assert_raise ArgumentError, ~r/unknown leaf-hash version 3/, fn ->
        LeafHash.compute(fields(), 3)
      end
    end
  end

  describe "LCP-1 §8.5 independent recomputation across a jsonb round-trip" do
    setup do
      %{tenant: fixture(:tenant)}
    end

    test "a genesis entry reproduces from stored content", %{tenant: tenant} do
      {:ok, entry} =
        AuditChain.append(tenant.id, %{
          action: "event_created",
          actor_lineage: ["dispatch-root"],
          entity_type: "story",
          entity_id: @entity,
          payload: %{"nested" => %{"z" => 1, "a" => 2}, "n" => 3}
        })

      reloaded = AdminRepo.get!(Entry, entry.id)

      assert reloaded.hash_version == 2
      assert AuditChain.recompute_entry_hash(reloaded) == reloaded.entry_hash
      assert AuditChain.entry_hash_valid?(reloaded)
    end

    test "a successor entry reproduces and chains onto its predecessor", %{tenant: tenant} do
      {:ok, _genesis} =
        AuditChain.append(tenant.id, %{
          action: "event_created",
          actor_lineage: [],
          entity_type: "story",
          payload: %{}
        })

      {:ok, second} =
        AuditChain.append(tenant.id, %{
          action: "event_updated",
          actor_lineage: ["dispatch-x"],
          entity_type: "story",
          entity_id: @entity,
          payload: %{"b" => 2, "a" => 1}
        })

      reloaded = AdminRepo.get!(Entry, second.id)
      assert reloaded.chain_position == 1
      assert AuditChain.entry_hash_valid?(reloaded)
    end

    test "a float payload reproduces after the jsonb round-trip (no false positive)", %{
      tenant: tenant
    } do
      # jsonb normalizes numbers: an integral float is decoded back as an integer,
      # and exponent/scale forms are rewritten. Without number canonicalization the
      # write-time and read-back preimages diverge and entry_hash_valid?/1 returns a
      # FALSE tampering positive for a perfectly legitimate entry.
      {:ok, entry} =
        AuditChain.append(tenant.id, %{
          action: "score_recorded",
          actor_lineage: ["dispatch-root"],
          entity_type: "story",
          entity_id: @entity,
          payload: %{"big" => 1.0e22, "score" => 3.14, "small" => 1.0e-7, "round" => 100.0}
        })

      reloaded = AdminRepo.get!(Entry, entry.id)

      # Prove the round-trip actually changed a representation (big float -> integer),
      # so the assertion below is not vacuous.
      assert is_integer(reloaded.payload["big"])
      assert AuditChain.recompute_entry_hash(reloaded) == reloaded.entry_hash
      assert AuditChain.entry_hash_valid?(reloaded)
    end

    test "recompute detects a tampered payload", %{tenant: tenant} do
      {:ok, entry} =
        AuditChain.append(tenant.id, %{
          action: "event_created",
          actor_lineage: [],
          entity_type: "story",
          payload: %{"amount" => 100}
        })

      reloaded = AdminRepo.get!(Entry, entry.id)
      # The stored hash commits to the real payload; a verifier reading a doctored
      # in-memory copy recomputes a different hash. (The DB triggers make an
      # on-disk UPDATE impossible; this proves the hash itself carries the
      # content commitment, which §8.5 is about.)
      tampered = %{reloaded | payload: %{"amount" => 999}}
      refute AuditChain.entry_hash_valid?(tampered)
    end
  end
end
