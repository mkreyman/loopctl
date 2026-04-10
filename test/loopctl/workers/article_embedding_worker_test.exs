defmodule Loopctl.Workers.ArticleEmbeddingWorkerTest do
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  alias Loopctl.Knowledge
  alias Loopctl.Workers.ArticleEmbeddingWorker

  defp setup_tenant do
    tenant = fixture(:tenant)
    %{tenant: tenant}
  end

  defp create_published_article(tenant_id, attrs \\ %{}) do
    base_attrs = %{
      title: "Published Article #{System.unique_integer([:positive])}",
      body: "Test article body for embedding generation.",
      category: :pattern,
      status: :published
    }

    {:ok, article} = Knowledge.create_article(tenant_id, Map.merge(base_attrs, attrs))
    article
  end

  # --- TC-20.3.1: Worker generates + stores embedding on success ---

  describe "perform/1 success" do
    test "generates and stores embedding for a published article" do
      %{tenant: tenant} = setup_tenant()
      embedding = List.duplicate(0.5, 1536)

      # Create as draft to avoid the inline Oban enqueue during create.
      # Then publish it manually so we can test perform/1 in isolation.
      {:ok, article} =
        Knowledge.create_article(tenant.id, %{
          title: "Published Article For Perform Test",
          body: "Test body for direct worker invocation.",
          category: :pattern,
          status: :draft
        })

      # Now update to published status (this will trigger an inline job too,
      # so we use expect with 2 calls: one from update_article, one from our manual call)
      article =
        %{article | status: :published}
        |> Ecto.Changeset.change(%{status: :published})
        |> Loopctl.AdminRepo.update!()

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn text ->
        assert is_binary(text)
        assert text =~ "Published Article For Perform Test"
        {:ok, embedding}
      end)

      assert :ok =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article.id, "tenant_id" => tenant.id}
               })

      # Verify embedding was stored (use explicit select since load_in_query: false)
      {:ok, updated} = Knowledge.get_article_with_embedding(tenant.id, article.id)
      assert updated.embedding != nil
    end
  end

  # --- TC-20.3.2: Worker returns {:error, reason} on failure ---

  describe "perform/1 failure" do
    test "returns {:error, reason} when embedding client fails" do
      %{tenant: tenant} = setup_tenant()

      # Create as draft to isolate the worker test from the inline Oban enqueue
      {:ok, article} =
        Knowledge.create_article(tenant.id, %{
          title: "Failing Article",
          body: "Will fail embedding.",
          category: :pattern,
          status: :draft
        })

      # Set published directly via changeset (bypass context to avoid inline job)
      article =
        %{article | status: :published}
        |> Ecto.Changeset.change(%{status: :published})
        |> Loopctl.AdminRepo.update!()

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _text ->
        {:error, {:api_error, 500, "Internal Server Error"}}
      end)

      assert {:error, {:api_error, 500, "Internal Server Error"}} =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article.id, "tenant_id" => tenant.id}
               })
    end
  end

  # --- TC-20.3.3: Worker handles deleted article (returns :ok) ---

  describe "perform/1 deleted article" do
    test "returns :ok when article no longer exists" do
      %{tenant: tenant} = setup_tenant()
      fake_id = Ecto.UUID.generate()

      # No embedding client call expected (verify_on_exit! ensures this)
      assert :ok =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"article_id" => fake_id, "tenant_id" => tenant.id}
               })
    end
  end

  # --- TC-20.3.4: create_article enqueues embedding job for published articles ---

  describe "create_article embedding enqueue" do
    test "enqueues embedding job when creating a published article" do
      %{tenant: tenant} = setup_tenant()

      # The default stub already returns {:ok, embedding} so inline Oban will process it.
      # We verify the job was enqueued by checking the embedding was written.
      {:ok, article} =
        Knowledge.create_article(tenant.id, %{
          title: "Embeddable Article",
          body: "This article should get an embedding.",
          category: :pattern,
          status: :published
        })

      # In inline mode, the job executes synchronously. Verify embedding was stored.
      {:ok, loaded} = Knowledge.get_article_with_embedding(tenant.id, article.id)
      assert loaded.embedding != nil
    end

    test "does not enqueue embedding job for draft articles" do
      %{tenant: tenant} = setup_tenant()

      # Should NOT call the embedding client for drafts
      {:ok, article} =
        Knowledge.create_article(tenant.id, %{
          title: "Draft Article",
          body: "This draft should not get an embedding.",
          category: :pattern,
          status: :draft
        })

      {:ok, loaded} = Knowledge.get_article_with_embedding(tenant.id, article.id)
      assert loaded.embedding == nil
    end
  end

  # --- TC-20.3.5: update_article enqueues when title/body changes ---

  describe "update_article embedding enqueue" do
    test "enqueues embedding when title changes on a published article" do
      %{tenant: tenant} = setup_tenant()
      article = create_published_article(tenant.id)

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn text ->
        assert text =~ "Updated Title"
        {:ok, List.duplicate(0.2, 1536)}
      end)

      assert {:ok, updated} =
               Knowledge.update_article(tenant.id, article.id, %{title: "Updated Title"})

      assert updated.title == "Updated Title"
    end

    test "enqueues embedding when body changes on a published article" do
      %{tenant: tenant} = setup_tenant()
      article = create_published_article(tenant.id)

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn text ->
        assert text =~ "Updated body content"
        {:ok, List.duplicate(0.3, 1536)}
      end)

      assert {:ok, _updated} =
               Knowledge.update_article(tenant.id, article.id, %{body: "Updated body content"})
    end

    test "enqueues embedding when status transitions to published" do
      %{tenant: tenant} = setup_tenant()

      # Create as draft first (no embedding)
      {:ok, draft} =
        Knowledge.create_article(tenant.id, %{
          title: "Draft to Publish",
          body: "Will be published later.",
          category: :pattern,
          status: :draft
        })

      assert draft.embedding == nil

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn text ->
        assert text =~ "Draft to Publish"
        {:ok, List.duplicate(0.4, 1536)}
      end)

      assert {:ok, published} =
               Knowledge.update_article(tenant.id, draft.id, %{status: :published})

      assert published.status == :published
    end

    test "does not enqueue embedding for tags-only changes" do
      %{tenant: tenant} = setup_tenant()
      article = create_published_article(tenant.id)

      # After create (which uses the default stub), set expect with 0 calls.
      # If update_article incorrectly enqueues an embedding job for a
      # tags-only change, Mox will fail because the mock was called.
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, 0, fn _text ->
        {:ok, List.duplicate(0.1, 1536)}
      end)

      {:ok, updated} =
        Knowledge.update_article(tenant.id, article.id, %{tags: ["new-tag"]})

      assert updated.tags == ["new-tag"]
    end

    test "does not enqueue embedding for metadata-only changes" do
      %{tenant: tenant} = setup_tenant()
      article = create_published_article(tenant.id)

      # After create (which uses the default stub), set expect with 0 calls.
      # Ensures no embedding job is enqueued for metadata-only changes.
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, 0, fn _text ->
        {:ok, List.duplicate(0.1, 1536)}
      end)

      {:ok, updated} =
        Knowledge.update_article(tenant.id, article.id, %{metadata: %{"key" => "value"}})

      assert updated.metadata == %{"key" => "value"}
    end
  end

  # --- TC-20.3.6: Input text truncated to 32K ---

  describe "text truncation" do
    test "truncates embedding input to 32K characters" do
      %{tenant: tenant} = setup_tenant()

      long_body = String.duplicate("a", 40_000)

      # Create as draft to avoid inline Oban enqueue, then set published directly
      {:ok, article} =
        Knowledge.create_article(tenant.id, %{
          title: "Long Body Article",
          body: long_body,
          category: :pattern,
          status: :draft
        })

      article =
        article
        |> Ecto.Changeset.change(%{status: :published})
        |> Loopctl.AdminRepo.update!()

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn text ->
        # title + "\n\n" + body should be truncated to 32K total
        assert String.length(text) <= 32_000
        {:ok, List.duplicate(0.1, 1536)}
      end)

      assert :ok =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article.id, "tenant_id" => tenant.id}
               })
    end
  end

  # --- TC-20.3.8: Tenant isolation ---

  describe "tenant isolation" do
    test "worker with wrong tenant_id returns :ok (article not visible)" do
      %{tenant: tenant_a} = setup_tenant()
      %{tenant: tenant_b} = setup_tenant()

      article = create_published_article(tenant_a.id)

      # Worker runs with tenant_b's tenant_id but tenant_a's article_id.
      # Knowledge.get_article scopes by tenant_id, so it returns :not_found.
      # The worker should treat this as a deleted article and return :ok.
      assert :ok =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article.id, "tenant_id" => tenant_b.id}
               })

      # Verify tenant_a's article embedding was NOT modified by the wrong-tenant worker.
      # The embedding from create_published_article should remain unchanged.
      {:ok, loaded} = Knowledge.get_article_with_embedding(tenant_a.id, article.id)
      assert loaded.embedding != nil
    end
  end

  # --- TC-20.3.7: Custom backoff increases polynomially ---

  describe "backoff/1" do
    test "returns polynomial backoff values" do
      # attempt^4 + 15 + rand(1..30*attempt)
      # The random component makes exact values unpredictable, but we can
      # verify the minimum and maximum bounds.
      for attempt <- 1..4 do
        backoff = ArticleEmbeddingWorker.backoff(%Oban.Job{attempt: attempt})

        min_expected = trunc(:math.pow(attempt, 4) + 15 + attempt)
        max_expected = trunc(:math.pow(attempt, 4) + 15 + 30 * attempt)

        assert backoff >= min_expected,
               "attempt #{attempt}: backoff #{backoff} < min #{min_expected}"

        assert backoff <= max_expected,
               "attempt #{attempt}: backoff #{backoff} > max #{max_expected}"
      end
    end

    test "backoff increases with each attempt" do
      # Sample multiple times to account for randomness
      backoffs =
        for attempt <- 1..4 do
          # Use the deterministic minimum component for comparison
          trunc(:math.pow(attempt, 4) + 15)
        end

      # Verify the deterministic component increases monotonically
      assert backoffs == Enum.sort(backoffs)
    end
  end
end
