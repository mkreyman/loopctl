defmodule Loopctl.KnowledgeEmbeddingTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Repo.HnswIndex

  defp setup_tenant do
    tenant = fixture(:tenant)
    %{tenant: tenant}
  end

  defp setup_article do
    %{tenant: tenant} = setup_tenant()
    article = fixture(:article, %{tenant_id: tenant.id})
    %{tenant: tenant, article: article}
  end

  describe "update_embedding/3" do
    # TC-20.2.1: update_embedding stores valid 1536-dim vector
    test "stores a valid 1536-dimension embedding vector" do
      %{tenant: tenant, article: article} = setup_article()
      embedding = List.duplicate(0.1, 1536)

      assert {:ok, %Article{} = updated} =
               Knowledge.update_embedding(tenant.id, article.id, embedding)

      assert updated.id == article.id
      assert updated.embedding != nil

      # Reload from DB with embedding explicitly selected (load_in_query: false)
      assert {:ok, reloaded} = Knowledge.get_article_with_embedding(tenant.id, article.id)
      stored = Pgvector.to_list(reloaded.embedding)
      assert length(stored) == 1536
      assert Enum.all?(stored, &(abs(&1 - 0.1) < 0.001))
    end

    # TC-20.2.2: update_embedding rejects wrong dimension (768-dim)
    test "rejects embedding with wrong dimensions" do
      %{tenant: tenant, article: article} = setup_article()
      embedding = List.duplicate(0.5, 768)

      assert {:error, changeset} =
               Knowledge.update_embedding(tenant.id, article.id, embedding)

      assert %{embedding: [error_msg]} = errors_on(changeset)
      assert error_msg =~ "dimension mismatch"
      assert error_msg =~ "1536"
      assert error_msg =~ "768"
    end

    test "returns :not_found for non-existent article" do
      %{tenant: tenant} = setup_tenant()
      embedding = List.duplicate(0.1, 1536)

      assert {:error, :not_found} =
               Knowledge.update_embedding(tenant.id, Ecto.UUID.generate(), embedding)
    end

    test "overwrites an existing embedding with a new one" do
      %{tenant: tenant, article: article} = setup_article()
      first_embedding = List.duplicate(0.1, 1536)
      second_embedding = List.duplicate(0.9, 1536)

      assert {:ok, _} = Knowledge.update_embedding(tenant.id, article.id, first_embedding)
      assert {:ok, _} = Knowledge.update_embedding(tenant.id, article.id, second_embedding)

      # Reload from DB with embedding explicitly selected (load_in_query: false)
      assert {:ok, reloaded} = Knowledge.get_article_with_embedding(tenant.id, article.id)
      stored = Pgvector.to_list(reloaded.embedding)
      assert Enum.all?(stored, &(abs(&1 - 0.9) < 0.001))
    end
  end

  describe "clear_embedding/2" do
    # TC-20.2.3: clear_embedding sets to nil
    test "sets embedding to nil" do
      %{tenant: tenant, article: article} = setup_article()
      embedding = List.duplicate(0.1, 1536)

      # First set an embedding
      assert {:ok, with_embedding} =
               Knowledge.update_embedding(tenant.id, article.id, embedding)

      assert with_embedding.embedding != nil

      # Now clear it
      assert {:ok, %Article{} = cleared} = Knowledge.clear_embedding(tenant.id, article.id)
      assert cleared.id == article.id
      assert cleared.embedding == nil
    end

    # TC-20.2.4: clear_embedding returns :not_found for missing article
    test "returns :not_found for non-existent article" do
      %{tenant: tenant} = setup_tenant()

      assert {:error, :not_found} =
               Knowledge.clear_embedding(tenant.id, Ecto.UUID.generate())
    end

    test "is idempotent when embedding is already nil" do
      %{tenant: tenant, article: article} = setup_article()

      # Article starts with no embedding
      assert article.embedding == nil

      assert {:ok, %Article{} = cleared} = Knowledge.clear_embedding(tenant.id, article.id)
      assert cleared.embedding == nil
    end
  end

  # TC-20.2.5: Normal update_article doesn't overwrite embedding
  describe "embedding isolation from standard changesets" do
    test "update_article does not overwrite an existing embedding" do
      %{tenant: tenant, article: article} = setup_article()
      embedding = List.duplicate(0.1, 1536)

      # Set an embedding
      assert {:ok, _} = Knowledge.update_embedding(tenant.id, article.id, embedding)

      # Update the article through the normal path
      assert {:ok, updated} =
               Knowledge.update_article(tenant.id, article.id, %{
                 title: "Updated Title"
               })

      assert updated.title == "Updated Title"

      # Reload with embedding explicitly selected (load_in_query: false)
      assert {:ok, reloaded} = Knowledge.get_article_with_embedding(tenant.id, article.id)
      assert reloaded.embedding != nil
      assert length(Pgvector.to_list(reloaded.embedding)) == 1536
    end

    test "create_changeset does not include embedding in cast fields" do
      # Verify :embedding is not in @cast_fields by attempting to cast it
      changeset =
        %Article{tenant_id: Ecto.UUID.generate()}
        |> Article.create_changeset(%{
          title: "Test",
          body: "Body",
          category: :pattern,
          embedding: List.duplicate(0.1, 1536)
        })

      # The embedding should not be set via create_changeset
      refute Ecto.Changeset.get_change(changeset, :embedding)
    end
  end

  # TC-20.2.6: Tenant isolation on embedding operations
  describe "tenant isolation" do
    test "cannot update embedding on another tenant's article" do
      %{article: article_a} = setup_article()
      %{tenant: tenant_b} = setup_tenant()

      embedding = List.duplicate(0.1, 1536)

      assert {:error, :not_found} =
               Knowledge.update_embedding(tenant_b.id, article_a.id, embedding)
    end

    test "cannot clear embedding on another tenant's article" do
      %{article: article_a} = setup_article()
      %{tenant: tenant_b} = setup_tenant()

      assert {:error, :not_found} =
               Knowledge.clear_embedding(tenant_b.id, article_a.id)
    end
  end

  # TC-20.2.7: the ANN index that serves THIS install's read path exists.
  #
  # US-27.14 reconciled the legacy index to the single canonical name
  # `articles_embedding_hnsw_idx`. GH #578 then RETIRED it — but only on installs whose
  # reads have been cut over to the `article_embeddings` side table, because
  # `embedding_side_table_reads` defaults to `0` (= the legacy `articles.embedding`
  # column) in code and no migration seeds the row.
  #
  # So "the legacy index exists" is no longer an invariant, and its negation is not one
  # either. The invariants that survive #578 — and the ones worth a test — are that the
  # index serving the LIVE read path is present and USABLE, and that the legacy index is
  # still present WHENEVER the legacy column is still the live read path. That second one
  # is mechanically the same condition the drop migration guards on
  # (`20260805120000_drop_legacy_articles_embedding_hnsw_index.exs`), so a migration
  # that dropped unconditionally would fail here.
  #
  # The CONVERSE is deliberately NOT asserted. The documented cutover order
  # (`Loopctl.Embeddings` moduledoc) is: deploy the code — running the drop migration
  # while the flag is still `0`, so the index is KEPT — backfill, reconcile, and only
  # THEN flip the flag to `1`. Every install that cuts over from here on therefore has
  # the flag at `1` AND the legacy index still present, which the migration states
  # explicitly ("a migration does not re-run"). Asserting `flag = 1 => no index` would
  # red on exactly the installs that followed the documented procedure.
  describe "HNSW index" do
    test "the live ANN index is present and VALID" do
      # `pg_indexes` also lists INVALID indexes — the leftover a failed
      # `CREATE INDEX CONCURRENTLY` produces (wiki ed00911b) — so presence is checked
      # via `pg_index.indisvalid`, never by name alone (wiki 753fbf69).
      live = HnswIndex.dimension_index_name("article_embeddings", 1536)

      assert index_valid?(live),
             "the per-dimension side-table ANN index #{live} must exist and be valid"
    end

    test "the legacy index is present while the legacy column is the live read path" do
      %{rows: rows} =
        AdminRepo.query!("SELECT value FROM system_configs WHERE key = $1", [
          Embeddings.read_flag_key()
        ])

      # Read from the ROW, not `SystemConfig.get_int/2`: the `:persistent_term` cache
      # answers the in-code default on a miss, which is the same value an absent row
      # means — indistinguishable, and the migration guards on the row.
      legacy_column_is_live? = not match?([[1]], rows)

      # Non-vacuity: every assertion below is conditioned on this premise, so a test DB
      # that ever seeded the flag to `1` would turn the whole test into a silent pass.
      # The flag defaults to `0` IN CODE and no migration seeds the row, so the premise
      # is asserted rather than branched on — a deliberate change to it has to come back
      # here and decide what this test should check instead of quietly disabling it.
      assert legacy_column_is_live?,
             "#{Embeddings.read_flag_key()} is 1 in the test DB, which makes this test " <>
               "assert nothing. Nothing may write that flag (it is :persistent_term-cached " <>
               "VM-globally); if the shipped default genuinely changed, rewrite this test " <>
               "for the side-table read path rather than leaving it vacuous"

      assert index_valid?("articles_embedding_hnsw_idx"),
             "the legacy articles.embedding column is still this install's read path, " <>
               "so its HNSW index must NOT have been dropped — an unindexed legacy " <>
               "read path is a full seq scan + top-N sort over the corpus"

      %{rows: [[indexdef]]} =
        AdminRepo.query!(
          "SELECT indexdef FROM pg_indexes WHERE tablename = 'articles' AND indexname = 'articles_embedding_hnsw_idx'"
        )

      assert indexdef =~ "hnsw"
      assert indexdef =~ "vector_cosine_ops"
    end
  end

  defp index_valid?(name) do
    %{rows: rows} =
      AdminRepo.query!(
        """
        SELECT i.indisvalid
        FROM pg_class c
        JOIN pg_index i ON i.indexrelid = c.oid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = $1 AND n.nspname = 'public'
        """,
        [name]
      )

    rows == [[true]]
  end
end
