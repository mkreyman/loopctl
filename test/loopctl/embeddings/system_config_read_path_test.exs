defmodule Loopctl.Embeddings.SystemConfigReadPathTest do
  @moduledoc """
  US-41.1 — the PRODUCTION read-path decision: the `SystemConfig` cutover flag
  (`0` = legacy column, `1` = side table) and, just as importantly, its REVERT
  (AC-41.1.8(ii)/(iii) — one operator UPDATE, no redeploy).

  This coverage used to live in `Loopctl.EmbeddingsSideTableReadsTest`. Once the
  decision moved behind `Loopctl.Embeddings.ReadPathBehaviour`, asserting it
  there would only have asserted the injected Mox mock — so it moved here, where
  it exercises the real implementation.

  ## Why `async: false`

  This module is the ONE place that still writes the VM-global flag, because the
  flag IS what it tests. That is now safe: every other test resolves the read
  path through the injected mock and no longer observes this value, so the
  mutation has nobody left to leak into. Keep it that way — if a future test
  needs the side-table path, stub `Loopctl.MockEmbeddingReadPath`, do not flip
  this flag.
  """

  use Loopctl.DataCase, async: false

  setup :verify_on_exit!

  alias Loopctl.Embeddings
  alias Loopctl.Embeddings.SystemConfigReadPath
  alias Loopctl.SystemConfig

  setup do
    on_exit(fn -> SystemConfig.put(Embeddings.read_flag_key(), 0) end)
    :ok
  end

  describe "side_table_reads_enabled?/0" do
    test "defaults to false (legacy column) when the flag is unset/0" do
      {:ok, _} = SystemConfig.put(Embeddings.read_flag_key(), 0)
      refute SystemConfigReadPath.side_table_reads_enabled?()
    end

    test "is true when the operator sets the flag to 1" do
      {:ok, _} = SystemConfig.put(Embeddings.read_flag_key(), 1)
      assert SystemConfigReadPath.side_table_reads_enabled?()
    end

    test "the cutover is REVERSIBLE with a single UPDATE (AC-41.1.8(iii))" do
      {:ok, _} = SystemConfig.put(Embeddings.read_flag_key(), 1)
      assert SystemConfigReadPath.side_table_reads_enabled?()

      {:ok, _} = SystemConfig.put(Embeddings.read_flag_key(), 0)
      refute SystemConfigReadPath.side_table_reads_enabled?()
    end

    test "any value other than 1 reads as legacy (fails safe)" do
      {:ok, _} = SystemConfig.put(Embeddings.read_flag_key(), 2)
      refute SystemConfigReadPath.side_table_reads_enabled?()
    end
  end

  describe "production wiring" do
    test "implements the read-path behaviour" do
      assert Loopctl.Embeddings.ReadPathBehaviour in SystemConfigReadPath.module_info(:attributes)[
               :behaviour
             ]
    end
  end
end
