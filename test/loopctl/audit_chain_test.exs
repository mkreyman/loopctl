defmodule Loopctl.AuditChainTest do
  @moduledoc """
  Tests for US-26.1.1 — hash-chained, append-only audit chain.
  """

  use Loopctl.DataCase, async: true

  import Loopctl.Fixtures

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.AuditChain.Entry

  setup :verify_on_exit!

  defp make_entry_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        action: "test_action",
        actor_lineage: ["dispatch-1"],
        entity_type: "story",
        entity_id: Ecto.UUID.generate(),
        payload: %{"key" => "value"}
      },
      overrides
    )
  end

  describe "append/2" do
    test "genesis entry has position 0 and zero prev_entry_hash" do
      tenant = fixture(:tenant)

      assert {:ok, entry} =
               AuditChain.append(tenant.id, make_entry_attrs(%{action: "tenant_created"}))

      assert entry.chain_position == 0
      assert entry.prev_entry_hash == :binary.copy(<<0>>, 32)
      assert byte_size(entry.entry_hash) == 32
      assert entry.action == "tenant_created"
      assert entry.tenant_id == tenant.id
    end

    test "second entry references first entry's hash" do
      tenant = fixture(:tenant)

      {:ok, first} = AuditChain.append(tenant.id, make_entry_attrs(%{action: "first"}))
      {:ok, second} = AuditChain.append(tenant.id, make_entry_attrs(%{action: "second"}))

      assert second.chain_position == 1
      assert second.prev_entry_hash == first.entry_hash
      assert second.entry_hash != first.entry_hash
    end

    test "builds a chain of 5 entries with correct linkage" do
      tenant = fixture(:tenant)

      entries =
        Enum.map(0..4, fn i ->
          {:ok, entry} = AuditChain.append(tenant.id, make_entry_attrs(%{action: "action_#{i}"}))
          entry
        end)

      Enum.each(Enum.with_index(entries), fn {entry, i} ->
        assert entry.chain_position == i

        if i == 0 do
          assert entry.prev_entry_hash == :binary.copy(<<0>>, 32)
        else
          prev = Enum.at(entries, i - 1)
          assert entry.prev_entry_hash == prev.entry_hash
        end
      end)
    end
  end

  describe "trigger enforcement" do
    test "UPDATE trigger blocks any modification" do
      tenant = fixture(:tenant)
      {:ok, entry} = AuditChain.append(tenant.id, make_entry_attrs())

      assert_raise Postgrex.Error, ~r/cannot_modify_audit_chain/, fn ->
        from(e in Entry, where: e.id == ^entry.id)
        |> AdminRepo.update_all(set: [action: "tampered"])
      end
    end

    test "DELETE trigger blocks any row removal" do
      tenant = fixture(:tenant)
      {:ok, entry} = AuditChain.append(tenant.id, make_entry_attrs())

      assert_raise Postgrex.Error, ~r/cannot_delete_audit_chain/, fn ->
        from(e in Entry, where: e.id == ^entry.id)
        |> AdminRepo.delete_all()
      end
    end

    test "INSERT with wrong chain_position is rejected" do
      tenant = fixture(:tenant)
      {:ok, _first} = AuditChain.append(tenant.id, make_entry_attrs())
      {:ok, tenant_uuid} = Ecto.UUID.dump(tenant.id)

      assert_raise Postgrex.Error, ~r/audit_chain_position_violation/, fn ->
        SQL.query!(
          AdminRepo,
          """
          INSERT INTO audit_chain (id, tenant_id, chain_position, prev_entry_hash, action, actor_lineage, entity_type, payload, entry_hash, inserted_at)
          VALUES (gen_random_uuid(), $1, 5, $2, 'bad', '[]', 'test', '{}', $3, NOW())
          """,
          [tenant_uuid, :binary.copy(<<0>>, 32), :binary.copy(<<1>>, 32)]
        )
      end
    end

    test "INSERT with wrong prev_entry_hash is rejected" do
      tenant = fixture(:tenant)
      {:ok, first} = AuditChain.append(tenant.id, make_entry_attrs())
      {:ok, tenant_uuid} = Ecto.UUID.dump(tenant.id)

      wrong_hash = :binary.copy(<<42>>, 32)

      assert_raise Postgrex.Error, ~r/audit_chain_hash_violation/, fn ->
        SQL.query!(
          AdminRepo,
          """
          INSERT INTO audit_chain (id, tenant_id, chain_position, prev_entry_hash, action, actor_lineage, entity_type, payload, entry_hash, inserted_at)
          VALUES (gen_random_uuid(), $1, $2, $3, 'bad', '[]', 'test', '{}', $4, NOW())
          """,
          [tenant_uuid, first.chain_position + 1, wrong_hash, :binary.copy(<<1>>, 32)]
        )
      end
    end
  end

  describe "list_entries/2" do
    test "returns entries in chain order with pagination" do
      tenant = fixture(:tenant)

      for i <- 0..4 do
        AuditChain.append(tenant.id, make_entry_attrs(%{action: "action_#{i}"}))
      end

      result = AuditChain.list_entries(tenant.id, limit: 3, offset: 0)
      assert length(result.data) == 3
      assert result.meta.total_count == 5
      assert Enum.map(result.data, & &1.chain_position) == [0, 1, 2]

      result2 = AuditChain.list_entries(tenant.id, limit: 3, offset: 3)
      assert length(result2.data) == 2
      assert Enum.map(result2.data, & &1.chain_position) == [3, 4]
    end

    test "filters by action" do
      tenant = fixture(:tenant)
      AuditChain.append(tenant.id, make_entry_attrs(%{action: "story_claimed"}))
      AuditChain.append(tenant.id, make_entry_attrs(%{action: "story_verified"}))
      AuditChain.append(tenant.id, make_entry_attrs(%{action: "story_claimed"}))

      result = AuditChain.list_entries(tenant.id, action: "story_claimed")
      assert result.meta.total_count == 2
      assert Enum.all?(result.data, &(&1.action == "story_claimed"))
    end
  end

  describe "tenant isolation" do
    test "tenant A cannot see tenant B's entries" do
      tenant_a = fixture(:tenant, %{slug: "chain-iso-a"})
      tenant_b = fixture(:tenant, %{slug: "chain-iso-b"})

      AuditChain.append(tenant_a.id, make_entry_attrs(%{action: "a_event"}))
      AuditChain.append(tenant_a.id, make_entry_attrs(%{action: "a_event_2"}))
      AuditChain.append(tenant_b.id, make_entry_attrs(%{action: "b_event"}))

      result_a = AuditChain.list_entries(tenant_a.id)
      result_b = AuditChain.list_entries(tenant_b.id)

      assert result_a.meta.total_count == 2
      assert result_b.meta.total_count == 1
      assert Enum.all?(result_a.data, &(&1.tenant_id == tenant_a.id))
      assert Enum.all?(result_b.data, &(&1.tenant_id == tenant_b.id))
    end
  end

  describe "concurrent appends" do
    test "produce sequential positions with no gaps" do
      tenant = fixture(:tenant)
      parent = self()

      tasks =
        for i <- 0..9 do
          Task.async(fn ->
            result = AuditChain.append(tenant.id, make_entry_attrs(%{action: "concurrent_#{i}"}))
            send(parent, {:done, i, result})
            result
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # All should succeed
      assert Enum.all?(results, &match?({:ok, _}, &1))

      # Verify chain integrity
      all_entries = AuditChain.list_entries(tenant.id, limit: 100)
      positions = Enum.map(all_entries.data, & &1.chain_position) |> Enum.sort()
      assert positions == Enum.to_list(0..9)

      # Verify hash linkage
      sorted = Enum.sort_by(all_entries.data, & &1.chain_position)

      Enum.reduce(sorted, :binary.copy(<<0>>, 32), fn entry, expected_prev ->
        assert entry.prev_entry_hash == expected_prev
        entry.entry_hash
      end)
    end
  end

  describe "latest_entry/1" do
    test "returns the most recent entry" do
      tenant = fixture(:tenant)
      AuditChain.append(tenant.id, make_entry_attrs(%{action: "first"}))
      {:ok, second} = AuditChain.append(tenant.id, make_entry_attrs(%{action: "second"}))

      latest = AuditChain.latest_entry(tenant.id)
      assert latest.id == second.id
      assert latest.chain_position == 1
    end

    test "returns nil for empty chain" do
      tenant = fixture(:tenant)
      assert AuditChain.latest_entry(tenant.id) == nil
    end
  end
end
