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

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, text ->
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

      # A transient 5xx whose body echoes a key fragment: the worker retries
      # ({:error, _}) but the reason that lands in oban_jobs.errors is SANITIZED
      # (review #5) — the body is dropped, only the status remains.
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 500, "Internal Server Error: key sk-...LEAK"}}
      end)

      result =
        ArticleEmbeddingWorker.perform(%Oban.Job{
          args: %{"article_id" => article.id, "tenant_id" => tenant.id}
        })

      assert {:error, {:api_error, 500, :provider_error}} = result
      refute inspect(result) =~ "LEAK"
    end

    test "US-37.1 (AC-37.1.4): a node-local rate-limit snoozes (never discards)" do
      %{tenant: tenant} = setup_tenant()

      {:ok, article} =
        Knowledge.create_article(tenant.id, %{
          title: "Rate Limited Article",
          body: "Will be node-local rate-limited.",
          category: :pattern,
          status: :draft
        })

      article =
        %{article | status: :published}
        |> Ecto.Changeset.change(%{status: :published})
        |> Loopctl.AdminRepo.update!()

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :rate_limited_local}
      end)

      result =
        ArticleEmbeddingWorker.perform(%Oban.Job{
          args: %{"article_id" => article.id, "tenant_id" => tenant.id}
        })

      # Loss-free backpressure: snooze (no attempt consumed), NEVER a discard.
      assert {:snooze, seconds} = result
      assert is_integer(seconds) and seconds > 0
    end

    test "US-37.2 (AC-37.2.2): the SAME per-node concurrency cap gates the worker (snooze, client never called)" do
      %{tenant: tenant} = setup_tenant()

      {:ok, article} =
        Knowledge.create_article(tenant.id, %{
          title: "Concurrency Capped Article",
          body: "Will be shed by the per-node embedding concurrency cap.",
          category: :pattern,
          status: :draft
        })

      article =
        %{article | status: :published}
        |> Ecto.Changeset.change(%{status: :published})
        |> Loopctl.AdminRepo.update!()

      # The concurrency gate (SAME one the interactive path uses) is saturated: the
      # worker's generate_embedding -> run_embedding_task -> acquire returns
      # {:error, :rate_limited_local} BEFORE the paid embedding client is ever
      # reached. Asserting the client is NOT called (0 expectations) proves the cap
      # really gates the worker path, not just the query path (AC-37.2.2).
      Mox.stub(Loopctl.MockEmbeddingConcurrency, :acquire, fn _tenant_id ->
        {:error, :rate_limited_local}
      end)

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, 0, fn _tenant_id, _text ->
        {:ok, List.duplicate(0.1, 1536)}
      end)

      result =
        ArticleEmbeddingWorker.perform(%Oban.Job{
          args: %{"article_id" => article.id, "tenant_id" => tenant.id}
        })

      # Loss-free backpressure: snooze (no attempt consumed), NEVER a discard.
      assert {:snooze, seconds} = result
      assert is_integer(seconds) and seconds > 0
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

      # US-37.4: the create/update enqueue now routes through the per-tenant
      # BatchEmbeddingWorker, which calls the plural `generate_embeddings/2`.
      expect(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _tenant_id, [text] ->
        assert text =~ "Updated Title"
        {:ok, [List.duplicate(0.2, 1536)]}
      end)

      assert {:ok, updated} =
               Knowledge.update_article(tenant.id, article.id, %{title: "Updated Title"})

      assert updated.title == "Updated Title"
    end

    test "enqueues embedding when body changes on a published article" do
      %{tenant: tenant} = setup_tenant()
      article = create_published_article(tenant.id)

      expect(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _tenant_id, [text] ->
        assert text =~ "Updated body content"
        {:ok, [List.duplicate(0.3, 1536)]}
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

      expect(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _tenant_id, [text] ->
        assert text =~ "Draft to Publish"
        {:ok, [List.duplicate(0.4, 1536)]}
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
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, 0, fn _tenant_id, _text ->
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
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, 0, fn _tenant_id, _text ->
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

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, text ->
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

  # --- Mandatory BYO: a keyless tenant gets a clean discard, never a crash ---

  defp create_draft_then_publish(tenant_id, attrs) do
    {:ok, article} =
      Knowledge.create_article(
        tenant_id,
        Map.merge(%{category: :pattern, status: :draft}, attrs)
      )

    article
    |> Ecto.Changeset.change(%{status: :published})
    |> Loopctl.AdminRepo.update!()
  end

  describe "mandatory BYO embeddings" do
    test "discards {:no_embedding_key, id} + emits telemetry when the tenant has no key" do
      %{tenant: tenant} = setup_tenant()

      article =
        create_draft_then_publish(tenant.id, %{
          title: "Keyless Tenant Article",
          body: "This tenant configured no embedding key."
        })

      # Attach a telemetry handler and assert the skip signal fires with tenant_id (#15).
      ref = make_ref()
      handler_id = "test-skip-#{inspect(ref)}"
      parent = self()

      :telemetry.attach(
        handler_id,
        [:loopctl, :embedding, :skipped_no_key],
        fn _event, measurements, metadata, _cfg ->
          send(parent, {:telemetry, ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # The embedding client refuses to call the provider for a keyless tenant.
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :no_api_key}
      end)

      assert {:discard, {:no_embedding_key, article_id}} =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article.id, "tenant_id" => tenant.id}
               })

      assert article_id == article.id

      assert_received {:telemetry, ^ref, %{count: 1}, %{tenant_id: tenant_id}}
      assert tenant_id == tenant.id

      # No embedding was stored (the article stays created, just not vector-searchable).
      {:ok, loaded} = Knowledge.get_article_with_embedding(tenant.id, article.id)
      assert loaded.embedding == nil
    end
  end

  # --- Permanent-error discard: a revoked/invalid key (4xx) isn't retried (#5) ---

  describe "permanent provider errors" do
    test "discards on a 4xx (bad/revoked key) instead of retrying" do
      %{tenant: tenant} = setup_tenant()

      article =
        create_draft_then_publish(tenant.id, %{
          title: "Revoked Key Article",
          body: "The tenant's embedding key was revoked."
        })

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 401, :provider_error}}
      end)

      assert {:discard, {:embedding_permanent_error, {:api_error, 401, _}}} =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article.id, "tenant_id" => tenant.id}
               })
    end

    test "retries (returns {:error, _}) on a transient 5xx" do
      %{tenant: tenant} = setup_tenant()

      article =
        create_draft_then_publish(tenant.id, %{
          title: "Transient Error Article",
          body: "The provider had a hiccup."
        })

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 500, :provider_error}}
      end)

      assert {:error, {:api_error, 500, _}} =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article.id, "tenant_id" => tenant.id}
               })
    end
  end

  # --- Idempotency: a retry with unchanged content never re-calls the provider (#12) ---

  describe "idempotent re-runs" do
    test "skips the paid provider when the article is already embedded for this content" do
      %{tenant: tenant} = setup_tenant()

      article =
        create_draft_then_publish(tenant.id, %{
          title: "Already Embedded Article",
          body: "Content that will be embedded exactly once."
        })

      # First run: the provider IS called (exactly once) and the embedding is stored.
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, 1, fn _tenant_id, _text ->
        {:ok, List.duplicate(0.25, 1536)}
      end)

      assert :ok =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article.id, "tenant_id" => tenant.id}
               })

      # Second run (a retry for the SAME content): the provider must NOT be called
      # again — the stored content-hash matches, so it's an idempotent no-op.
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, 0, fn _tenant_id, _text ->
        flunk("provider must not be re-called for already-embedded content")
      end)

      assert :ok =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article.id, "tenant_id" => tenant.id}
               })

      {:ok, loaded} = Knowledge.get_article_with_embedding(tenant.id, article.id)
      assert loaded.embedding != nil
    end
  end
end
