defmodule Loopctl.IndexHealthTest do
  @moduledoc """
  US-27.9a: the boot-time critical-index validity probe. In the test DB the keyset
  index is created by the migration and is valid; a bogus name is `:missing`.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.IndexHealth

  describe "index_validity/1" do
    test "reports :valid for the real keyset index (migration-created, valid)" do
      assert IndexHealth.index_validity("articles_tenant_inserted_id_idx") == :valid
    end

    test "reports :valid for the US-27.9b by-source keyset index (migration-created, valid)" do
      assert IndexHealth.index_validity("articles_tenant_source_inserted_id_idx") == :valid
    end

    test "reports :missing for an index that does not exist" do
      assert IndexHealth.index_validity(
               "definitely_not_an_index_#{System.unique_integer([:positive])}"
             ) ==
               :missing
    end
  end

  describe "which/0" do
    test "includes both keyset indexes in the critical list" do
      names = Enum.map(IndexHealth.which(), fn {name, _purpose} -> name end)
      assert "articles_tenant_inserted_id_idx" in names
      assert "articles_tenant_source_inserted_id_idx" in names
    end
  end

  describe "warn_if_invalid_indexes/0" do
    test "returns :ok and emits no telemetry when all critical indexes are valid" do
      ref = make_ref()
      test_pid = self()
      handler_id = {__MODULE__, ref}

      :telemetry.attach(
        handler_id,
        [:loopctl, :index_health, :invalid],
        fn _e, _m, meta, _ -> send(test_pid, {ref, meta}) end,
        nil
      )

      try do
        assert IndexHealth.warn_if_invalid_indexes() == :ok
      after
        :telemetry.detach(handler_id)
      end

      refute_received {^ref, _meta}
    end
  end
end
