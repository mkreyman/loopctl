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

  Every test writes the flag into its OWN `SystemConfig` namespace (`SystemConfig.put/3`)
  and reads it back through `SystemConfigReadPath.side_table_reads_enabled?/1`, so the
  node-wide flag every other test reads — `DataCase.stub_embedding_read_path/0` DELEGATES to
  this module — is never moved. The row write is the real one, in this test's sandbox
  transaction. If a future test needs the side-table path, stub
  `Loopctl.MockEmbeddingReadPath`, do not flip the node-wide flag
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
    cache = {SystemConfig, make_ref()}
    on_exit(fn -> :persistent_term.erase({cache, Embeddings.read_flag_key()}) end)
    {:ok, cache: cache}
  end

  describe "side_table_reads_enabled?/1" do
    test "defaults to false (legacy column) when the flag is unset/0", %{cache: cache} do
      {:ok, _} = SystemConfig.put(Embeddings.read_flag_key(), 0, cache)
      refute SystemConfigReadPath.side_table_reads_enabled?(cache)
    end

    test "is true when the operator sets the flag to 1", %{cache: cache} do
      {:ok, _} = SystemConfig.put(Embeddings.read_flag_key(), 1, cache)
      assert SystemConfigReadPath.side_table_reads_enabled?(cache)
    end

    test "the cutover is REVERSIBLE with a single UPDATE (AC-41.1.8(iii))", %{cache: cache} do
      {:ok, _} = SystemConfig.put(Embeddings.read_flag_key(), 1, cache)
      assert SystemConfigReadPath.side_table_reads_enabled?(cache)

      {:ok, _} = SystemConfig.put(Embeddings.read_flag_key(), 0, cache)
      refute SystemConfigReadPath.side_table_reads_enabled?(cache)
    end

    test "any value other than 1 reads as legacy (fails safe)", %{cache: cache} do
      {:ok, _} = SystemConfig.put(Embeddings.read_flag_key(), 2, cache)
      refute SystemConfigReadPath.side_table_reads_enabled?(cache)
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
         %{cache: cache} do
      # The production resolution, unmodified, reading this test's namespace.
      stub(Loopctl.MockEmbeddingReadPath, :side_table_reads_enabled?, fn ->
        SystemConfigReadPath.side_table_reads_enabled?(cache)
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
      {:ok, _} = SystemConfig.put(Embeddings.read_flag_key(), 1, cache)
      assert Embeddings.side_table_reads_enabled?()

      # ...and the real query is now served from the side table at the tenant's dimension.
      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_semantic(tenant.id, vector, limit: 50)

      assert article.id in Enum.map(results, & &1.id)
      assert meta.embedding_dimension == 1536

      # ...and the REVERT lands on the request path too (AC-41.1.8(iii)).
      {:ok, _} = SystemConfig.put(Embeddings.read_flag_key(), 0, cache)
      assert {:ok, %{meta: reverted}} = Knowledge.search_semantic(tenant.id, vector, limit: 50)
      refute Map.has_key?(reverted, :embedding_dimension)
    end
  end
end
