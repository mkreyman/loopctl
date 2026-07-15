defmodule Loopctl.KnowledgeEmbeddingTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article

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

    test "review MED #2: a published content update marks the vector STALE without destroying it" do
      %{tenant: tenant} = setup_tenant()
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})
      embedding = List.duplicate(0.1, 1536)

      assert {:ok, _} = Knowledge.update_embedding(tenant.id, article.id, embedding, "old-hash")

      # Manual Oban mode: the content-change enqueues the batch drainer but does NOT
      # run it, so we can observe the intermediate state — the OLD vector must still
      # be present (searchable) with a staleness marker, not nulled.
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, _updated} =
                 Knowledge.update_article(tenant.id, article.id, %{body: "brand new body"})
      end)

      assert {:ok, reloaded} = Knowledge.get_article_with_embedding(tenant.id, article.id)
      # Old vector SURVIVES the async gap (does not drop out of vector search).
      assert reloaded.embedding != nil
      assert length(Pgvector.to_list(reloaded.embedding)) == 1536
      # But it is flagged stale so the drainer re-embeds it.
      assert reloaded.embedding_stale_at != nil

      # And it re-enters the pending set on that stale marker (vector still present).
      pending_ids = Knowledge.list_articles_pending_embedding(tenant.id, 50) |> Enum.map(& &1.id)
      assert article.id in pending_ids
    end

    test "review MED #2: storing a fresh vector clears the staleness marker" do
      %{tenant: tenant} = setup_tenant()
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      assert {:ok, _} =
               Knowledge.update_embedding(
                 tenant.id,
                 article.id,
                 List.duplicate(0.1, 1536),
                 "hash"
               )

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, _} = Knowledge.update_article(tenant.id, article.id, %{body: "changed"})
      end)

      # The drainer's store path re-embeds and must clear the stale flag.
      assert {:ok, _} =
               Knowledge.update_embedding(
                 tenant.id,
                 article.id,
                 List.duplicate(0.2, 1536),
                 "new-hash"
               )

      assert {:ok, reloaded} = Knowledge.get_article_with_embedding(tenant.id, article.id)
      assert reloaded.embedding_stale_at == nil
      assert Knowledge.list_articles_pending_embedding(tenant.id, 50) == []
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

  # TC-20.2.7: HNSW index exists
  # US-27.14: reconciled to the single canonical name `articles_embedding_hnsw_idx`
  # (matches prod). The reconcile migration renames the old migration's
  # `articles_embedding_idx` to this name in every env, so the assertion is now
  # exact rather than name-agnostic (still asserting the hnsw access method).
  describe "HNSW index" do
    test "articles_embedding_hnsw_idx exists on articles table" do
      result =
        Loopctl.AdminRepo.query!(
          "SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'articles' AND indexname = 'articles_embedding_hnsw_idx'"
        )

      assert length(result.rows) == 1
      [[_name, indexdef]] = result.rows
      assert indexdef =~ "hnsw"
      assert indexdef =~ "vector_cosine_ops"
    end
  end
end
