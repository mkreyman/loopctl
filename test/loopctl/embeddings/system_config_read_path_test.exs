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
  flag IS what it tests. Isolation comes from `async: false` ORDERING, not from
  the injected mock: `DataCase.stub_embedding_read_path/0` DELEGATES to the real
  `SystemConfigReadPath`, so a leaked `1` would reroute every other test onto the
  side-table path. That is exactly why cleanup below resets the
  `:persistent_term` cache DIRECTLY rather than through a DB write that can
  silently no-op during sandbox teardown, and why
  `Loopctl.ConfigEmbeddingReadPathTest` fails the build on a second writer. If a
  future test needs the side-table path, stub `Loopctl.MockEmbeddingReadPath`,
  do not flip this flag.
  """

  use Loopctl.DataCase, async: false

  setup :verify_on_exit!

  alias Loopctl.Embeddings
  alias Loopctl.Embeddings.SystemConfigReadPath
  alias Loopctl.Knowledge
  alias Loopctl.SystemConfig

  setup do
    # Reset the VM-global flag DETERMINISTICALLY. `SystemConfig.put/2` only updates the
    # `:persistent_term` cache on a successful DB write, and its result was discarded here —
    # so an ownership blip or a closed connection during sandbox teardown (on_exit runs in
    # ANOTHER process, after the test) would leave the flag pinned at 1 for the rest of the
    # VM, silently rerouting every later test onto the side-table path. The sibling
    # `heavy_read_hnsw_ef_search_test.exs` primes/erases `:persistent_term` directly for the
    # same reason.
    on_exit(fn -> :persistent_term.put({SystemConfig, Embeddings.read_flag_key()}, 0) end)
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

    # END-TO-END, and the ONLY test that proves AC-41.1.8's operator promise as a whole:
    # ONE `UPDATE` of the real `SystemConfig` row, no redeploy, and the REAL request-path
    # query moves onto the dimension-tagged side table. Every other read-path test injects
    # the decision through the Mox mock, so on its own it proves nothing about the flag
    # reaching `Knowledge.search_semantic/3`. DataCase's default stub DELEGATES to
    # `SystemConfigReadPath`, so this exercises the production resolution unmodified.
    test "flipping the real flag reroutes Knowledge.search_semantic onto the side table" do
      tenant = fixture(:tenant)
      article = fixture(:article, tenant_id: tenant.id, status: :published)
      vector = test_vec(1536, :primary)

      {:ok, _} = Embeddings.upsert_article_embedding(tenant.id, article, vector, nil, 1536)

      # Flag OFF (default): the LEGACY path, which carries no per-dimension meta.
      refute Embeddings.side_table_reads_enabled?()
      assert {:ok, %{meta: legacy_meta}} = Knowledge.search_semantic(tenant.id, vector, limit: 50)
      refute Map.has_key?(legacy_meta, :embedding_dimension)

      # ONE UPDATE, no redeploy...
      {:ok, _} = SystemConfig.put(Embeddings.read_flag_key(), 1)
      assert Embeddings.side_table_reads_enabled?()

      # ...and the real query is now served from the side table at the tenant's dimension.
      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_semantic(tenant.id, vector, limit: 50)

      assert article.id in Enum.map(results, & &1.id)
      assert meta.embedding_dimension == 1536

      # ...and the REVERT lands on the request path too (AC-41.1.8(iii)).
      {:ok, _} = SystemConfig.put(Embeddings.read_flag_key(), 0)
      assert {:ok, %{meta: reverted}} = Knowledge.search_semantic(tenant.id, vector, limit: 50)
      refute Map.has_key?(reverted, :embedding_dimension)
    end
  end
end
