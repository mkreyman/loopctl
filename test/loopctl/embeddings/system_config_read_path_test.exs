defmodule Loopctl.Embeddings.SystemConfigReadPathTest do
  @moduledoc """
  US-41.1 — the PRODUCTION read-path decision: the `SystemConfig` cutover flag
  (`0` = legacy column, `1` = side table) and, just as importantly, its REVERT
  (AC-41.1.8(ii)/(iii) — one operator UPDATE, no redeploy).

  This coverage used to live in `Loopctl.EmbeddingsSideTableReadsTest`. Once the
  decision moved behind `Loopctl.Embeddings.ReadPathBehaviour`, asserting it
  there would only have asserted the injected Mox mock — so it moved here, where
  it exercises the real implementation.

  ## Its own flag, not the node's

  Every test writes and reads a flag ROW of its own — a per-test key handed to
  `SystemConfigReadPath.side_table_reads_enabled?/1` — through the real `SystemConfig.put/2`.
  So neither the `embedding_side_table_reads` row (which other tests insert, e.g.
  `Loopctl.Embeddings.LegacyRetirementTest`, and whose row lock a concurrent upsert would
  wait on) nor its node-wide cache entry, which `DataCase.stub_embedding_read_path/0`
  DELEGATES to, is ever touched. If a future test needs the side-table path, stub
  `Loopctl.MockEmbeddingReadPath`, do not flip the real flag
  (`Loopctl.ConfigEmbeddingReadPathTest` fails the build on a writer of it).
  """

  use Loopctl.DataCase, async: true

  # #645 — vacuum the pgvector graph before each test in this module. Rolled-back tests
  # leave DEAD HNSW entries behind, and pgvector's scan skips dead elements rather than
  # traversing through them, which makes a visible row UNREACHABLE and returns `[]`. See
  # `Loopctl.DataCase.vacuum_vector_indexes/0`.
  @moduletag :vacuum_vector_indexes

  setup :verify_on_exit!

  alias Loopctl.Embeddings
  alias Loopctl.Embeddings.SystemConfigReadPath
  alias Loopctl.Knowledge
  alias Loopctl.SystemConfig

  setup do
    key = "side_table_reads_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> :persistent_term.erase({SystemConfig, key}) end)
    {:ok, key: key}
  end

  describe "side_table_reads_enabled?/1" do
    test "defaults to false (legacy column) when the flag is unset/0", %{key: key} do
      {:ok, _} = SystemConfig.put(key, 0)
      refute SystemConfigReadPath.side_table_reads_enabled?(key)
    end

    test "is true when the operator sets the flag to 1", %{key: key} do
      {:ok, _} = SystemConfig.put(key, 1)
      assert SystemConfigReadPath.side_table_reads_enabled?(key)
    end

    test "the cutover is REVERSIBLE with a single UPDATE (AC-41.1.8(iii))", %{key: key} do
      {:ok, _} = SystemConfig.put(key, 1)
      assert SystemConfigReadPath.side_table_reads_enabled?(key)

      {:ok, _} = SystemConfig.put(key, 0)
      refute SystemConfigReadPath.side_table_reads_enabled?(key)
    end

    test "any value other than 1 reads as legacy (fails safe)", %{key: key} do
      {:ok, _} = SystemConfig.put(key, 2)
      refute SystemConfigReadPath.side_table_reads_enabled?(key)
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
    test "flipping the real flag reroutes Knowledge.search_semantic onto the side table",
         %{key: key} do
      # The production resolution, unmodified, reading this test's own flag row.
      stub(Loopctl.MockEmbeddingReadPath, :side_table_reads_enabled?, fn ->
        SystemConfigReadPath.side_table_reads_enabled?(key)
      end)

      tenant = fixture(:tenant)
      article = fixture(:article, tenant_id: tenant.id, status: :published)
      vector = test_vec(1536, :primary)

      {:ok, _} = Embeddings.upsert_article_embedding(tenant.id, article, vector, nil, 1536)

      # Flag OFF (default): the LEGACY path, which carries no per-dimension meta.
      refute Embeddings.side_table_reads_enabled?()
      assert {:ok, %{meta: legacy_meta}} = Knowledge.search_semantic(tenant.id, vector, limit: 50)
      refute Map.has_key?(legacy_meta, :embedding_dimension)

      # ONE UPDATE, no redeploy...
      {:ok, _} = SystemConfig.put(key, 1)
      assert Embeddings.side_table_reads_enabled?()

      # ...and the real query is now served from the side table at the tenant's dimension.
      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_semantic(tenant.id, vector, limit: 50)

      assert article.id in Enum.map(results, & &1.id)
      assert meta.embedding_dimension == 1536

      # ...and the REVERT lands on the request path too (AC-41.1.8(iii)).
      {:ok, _} = SystemConfig.put(key, 0)
      assert {:ok, %{meta: reverted}} = Knowledge.search_semantic(tenant.id, vector, limit: 50)
      refute Map.has_key?(reverted, :embedding_dimension)
    end
  end
end
