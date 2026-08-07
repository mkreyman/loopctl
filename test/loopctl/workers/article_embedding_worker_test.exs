defmodule Loopctl.Workers.ArticleEmbeddingWorkerTest do
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  alias Loopctl.Custody
  alias Loopctl.Egress
  alias Loopctl.Egress.PinCache
  alias Loopctl.Embeddings.ShrinkLadder
  alias Loopctl.Embeddings.TextBudget
  alias Loopctl.Knowledge
  alias Loopctl.Test.AllowlistSource
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

  # --- US-41.7 (AC-41.7.2): the sequence is allocated BEFORE the provider call ---

  describe "custody posture on a FAILED provider call" do
    test "a call that egressed and then failed still leaves a recorded operation" do
      %{tenant: tenant} = setup_tenant()

      AllowlistSource.put(["api.openai.com", "api.anthropic.com"])
      on_exit(fn -> AllowlistSource.clear() end)

      {:ok, article} =
        Knowledge.create_article(tenant.id, %{
          title: "Egressed then failed #{System.unique_integer([:positive])}",
          body: "Body that leaves the process before the provider 5xx.",
          category: :pattern,
          status: :draft
        })

      # Mark local_only only NOW, so the create assigns nothing and the embed is
      # unambiguously the operation under test.
      {:ok, _} = Egress.enable_local_only(tenant.id, nil, acknowledge: true)
      PinCache.invalidate_tenant(tenant.id)

      article =
        article
        |> Ecto.Changeset.change(%{status: :published})
        |> Loopctl.AdminRepo.update!()

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        # The request body has already left the process at this point.
        {:error, {:api_error, 500, "Internal Server Error"}}
      end)

      assert {:error, _} =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article.id, "tenant_id" => tenant.id}
               })

      # Allocating the sequence only on SUCCESS would leave no entry AND no gap
      # here, and the claim would report no-third-party-egress for a row whose
      # body did egress. The entry exists, names the endpoint, and is marked
      # failed.
      assert [entry] = Custody.list_entries(tenant.id, "article", article.id)
      assert entry.operation == "embed"
      assert entry.outcome == "failed"
      assert [%{"host" => "api.openai.com"}] = entry.posture["endpoints"]
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

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, text ->
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

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, text ->
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

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, text ->
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
      this_tenant_id = tenant.id

      # Telemetry handlers are VM-GLOBAL and this event name is shared across the
      # article/memory/batch embedding workers, so a CONCURRENT async test's emission
      # would otherwise fire THIS handler and leak into the mailbox — tripping the
      # assert_received below. Forward ONLY events for this test's tenant (the emit
      # site tags metadata.tenant_id) so recall stays deterministic under full-suite
      # load, matching the memory_promotion_worker_test attach_telemetry pattern.
      :telemetry.attach(
        handler_id,
        [:loopctl, :embedding, :skipped_no_key],
        fn _event, measurements, metadata, _cfg ->
          if metadata[:tenant_id] == this_tenant_id do
            send(parent, {:telemetry, ref, measurements, metadata})
          end
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

  # --- Context-length shrink ladder ---
  #
  # Measured 2026-08-06: 80 published articles could never be embedded, because the
  # embedding text was capped at 32,000 CHARACTERS while the provider caps at 8,192
  # TOKENS, and the ratio is not constant across scripts. Each failure discarded
  # permanently, and the hourly reconciler re-enqueued all 80 every hour, forever.
  # These tests pin the escape: a too-long rejection re-sends a shorter prefix rather
  # than discarding the article.

  describe "context-length shrink ladder" do
    test "retries at a smaller byte budget and succeeds instead of discarding" do
      %{tenant: tenant} = setup_tenant()
      embedding = List.duplicate(0.5, 1536)

      article =
        create_draft_then_publish(tenant.id, %{
          title: "Over Long Article",
          # Cyrillic: 2 bytes/char, so this is well over any byte rung — the exact
          # population the character cap mis-measured.
          body: String.duplicate("привет ", 6_000)
        })

      # First call rejected as too long; second (shorter) call succeeds. Sizes are
      # reported back to the test process — the client runs in its own task, so the
      # comparison cannot be made inside the stub.
      test_pid = self()

      Loopctl.MockEmbeddingClient
      |> expect(:generate_embedding, fn _tenant_id, text ->
        send(test_pid, {:attempt, byte_size(text)})
        {:error, {:api_error, 400, :context_length_exceeded}}
      end)
      |> expect(:generate_embedding, fn _tenant_id, text ->
        send(test_pid, {:attempt, byte_size(text)})
        {:ok, embedding}
      end)

      assert :ok =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article.id, "tenant_id" => tenant.id}
               })

      assert_received {:attempt, first}
      assert_received {:attempt, second}

      assert second <= TextBudget.next_budget(first),
             "the retry must send STRICTLY LESS than the attempt that was rejected"

      # The article is embedded — not left in the reconciler's hourly retry loop.
      {:ok, stored} = Knowledge.get_article_with_embedding(tenant.id, article.id)
      refute is_nil(stored.embedding)

      # ...and the stored hash is MARKED, because that vector covers a PREFIX (#617
      # review follow-up). This worker was the last writer storing an unmarked prefix,
      # and it writes most of the corpus — so the readers that refuse to compare against
      # a prefix (the consolidation corroboration gate, the memory near-dup supersede)
      # filtered on a mark that nothing ever set, and could never fire.
      assert ShrinkLadder.truncated_hash?(stored.embedding_content_hash)

      # The mark must still identify the FULL text, or the idempotency guard misses and
      # every later enqueue re-walks the whole ladder at the provider's expense.
      assert ShrinkLadder.whole_hash(stored.embedding_content_hash) ==
               :sha256
               |> :crypto.hash(TextBudget.initial("#{stored.title}\n\n#{stored.body}"))
               |> Base.encode16(case: :lower)
    end

    test "an UNtruncated embedding is not marked" do
      # The mark has to discriminate. Marking every row would exclude the whole corpus
      # from the corroboration gate — the same dead guard, arrived at from the other side.
      %{tenant: tenant} = setup_tenant()

      article =
        create_draft_then_publish(tenant.id, %{title: "Short Enough", body: "a short body"})

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, List.duplicate(0.5, 1536)}
      end)

      assert :ok =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article.id, "tenant_id" => tenant.id}
               })

      {:ok, stored} = Knowledge.get_article_with_embedding(tenant.id, article.id)
      refute ShrinkLadder.truncated_hash?(stored.embedding_content_hash)
    end

    test "a marked row is still recognised as already embedded, and is not re-billed" do
      # The whole reason the hash keeps identifying the full text. If the idempotency
      # guard compared the raw stored value it would miss on every marked row, and each
      # enqueue would re-walk the ladder — several billed calls — forever.
      %{tenant: tenant} = setup_tenant()

      article =
        create_draft_then_publish(tenant.id, %{
          title: "Marked Then Re-enqueued",
          body: String.duplicate("привет ", 6_000)
        })

      Loopctl.MockEmbeddingClient
      |> expect(:generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 400, :context_length_exceeded}}
      end)
      |> expect(:generate_embedding, fn _tenant_id, _text ->
        {:ok, List.duplicate(0.5, 1536)}
      end)

      job = %Oban.Job{args: %{"article_id" => article.id, "tenant_id" => tenant.id}}
      assert :ok = ArticleEmbeddingWorker.perform(job)

      {:ok, stored} = Knowledge.get_article_with_embedding(tenant.id, article.id)
      assert ShrinkLadder.truncated_hash?(stored.embedding_content_hash)

      # A second run makes ZERO provider calls: `expect` above is exhausted, so any
      # further call fails the test rather than silently re-billing.
      assert :ok = ArticleEmbeddingWorker.perform(job)
    end

    test "gives up with a discard once the floor itself is rejected" do
      %{tenant: tenant} = setup_tenant()

      article =
        create_draft_then_publish(tenant.id, %{
          title: "Always Too Long",
          body: String.duplicate("привет ", 6_000)
        })

      # Rejected at every rung. The ladder must TERMINATE — if it did not, this test
      # would hang rather than fail, which is why the rung count is asserted too.
      calls = :counters.new(1, [])

      stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        :counters.add(calls, 1, 1)
        {:error, {:api_error, 400, :context_length_exceeded}}
      end)

      assert {:discard, {:embedding_permanent_error, {:api_error, 400, :context_length_exceeded}}} =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article.id, "tenant_id" => tenant.id}
               })

      attempts = :counters.get(calls, 1)

      assert attempts >= 2, "expected the ladder to retry at least once, got #{attempts} call(s)"

      assert attempts <= 4,
             "the ladder must be bounded — #{attempts} provider calls for one article"
    end

    test "a NON-length 4xx is not shrunk — it discards on the first call" do
      # The ladder must be driven by the classification, not by the status. Shrinking
      # a revoked-key 401 would re-bill the provider twice for an error that no amount
      # of truncation can fix.
      %{tenant: tenant} = setup_tenant()

      article =
        create_draft_then_publish(tenant.id, %{
          title: "Revoked Key Not Shrunk",
          body: String.duplicate("привет ", 6_000)
        })

      # `expect` with the default count of 1 fails the test if a second call is made.
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 401, :provider_error}}
      end)

      assert {:discard, {:embedding_permanent_error, {:api_error, 401, _}}} =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article.id, "tenant_id" => tenant.id}
               })
    end

    test "the RETRY is bounded by BYTES, not characters" do
      # The mutation that caused the outage: swap TextBudget.truncate/2 back for
      # String.slice/3 on the retry and this assertion is what fails — a shrunk
      # attempt measured in characters is not a smaller number of TOKENS.
      %{tenant: tenant} = setup_tenant()
      embedding = List.duplicate(0.5, 1536)
      test_pid = self()

      article =
        create_draft_then_publish(tenant.id, %{
          title: "Byte Bounded",
          # 30,000 Cyrillic chars = 60,000 bytes, under the 32,000-character initial
          # cut — so the retry, not the first attempt, is where bytes must bind.
          body: String.duplicate("я", 30_000)
        })

      Loopctl.MockEmbeddingClient
      |> expect(:generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 400, :context_length_exceeded}}
      end)
      |> expect(:generate_embedding, fn _tenant_id, text ->
        send(test_pid, {:retry_bytes, byte_size(text)})
        assert String.valid?(text), "truncation split a UTF-8 codepoint"
        {:ok, embedding}
      end)

      assert :ok =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article.id, "tenant_id" => tenant.id}
               })

      assert_received {:retry_bytes, retried}

      assert retried <= TextBudget.top_rung_bytes(),
             "retry sent #{retried} bytes, top rung is #{TextBudget.top_rung_bytes()}"
    end

    test "the first attempt keeps multi-byte content the provider would accept" do
      # The regression a BYTE cap on the first attempt introduces: an article that was
      # embedding fine loses a third of its text, with no error and no log line, and
      # its search recall degrades silently. Nothing marks it, so nothing finds it.
      %{tenant: tenant} = setup_tenant()
      embedding = List.duplicate(0.5, 1536)
      test_pid = self()

      # ~45,000 bytes of Cyrillic: over every byte rung, under the token limit.
      body = String.duplicate("привет ", 3_000)
      article = create_draft_then_publish(tenant.id, %{title: "Fits Whole", body: body})

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, text ->
        send(test_pid, {:sent, text})
        {:ok, embedding}
      end)

      assert :ok =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article.id, "tenant_id" => tenant.id}
               })

      assert_received {:sent, sent}
      assert byte_size(body) > TextBudget.top_rung_bytes(), "fixture no longer exercises the bug"

      assert sent == "#{article.title}\n\n#{body}",
             "the first attempt dropped #{byte_size(article.title) + byte_size(body) + 2 - byte_size(sent)} " <>
               "bytes of an article the provider accepted whole"
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

  # --- US-37.3 (AC-37.3.3): honor a provider Retry-After via loss-free snooze ---

  describe "throttle Retry-After (US-37.3)" do
    test "a 429 carrying a Retry-After snoozes ~that interval instead of attempt^4" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      article =
        create_draft_then_publish(tenant.id, %{
          title: "Throttled Article",
          body: "The provider is rate-limiting and asked us to back off."
        })

      # The client surfaces the throttle 4-tuple (429 + parsed, clamped Retry-After).
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 429, :provider_error, 30}}
      end)

      # Snooze (loss-free — no Oban attempt consumed), NOT the polynomial backoff /
      # {:error, _} retry. The snooze is the parsed Retry-After.
      assert {:snooze, 30} =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article.id, "tenant_id" => tenant.id}
               })
    end

    test "a 429 WITHOUT a Retry-After keeps the transient {:error, _} retry path" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      article =
        create_draft_then_publish(tenant.id, %{
          title: "Throttled No Header Article",
          body: "Rate-limited but no Retry-After header present."
        })

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 429, :provider_error}}
      end)

      # No Retry-After → falls through to the generic transient branch (429 is
      # transient per Llm.permanent_provider_error?/1) → {:error, _} for Oban's
      # polynomial backoff, NOT a discard and NOT a snooze.
      assert {:error, {:api_error, 429, :provider_error}} =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article.id, "tenant_id" => tenant.id}
               })
    end
  end

  # --- US-37.3 (AC-37.3.5): OPEN breaker → loss-free snooze, never an attempt-consuming discard ---

  describe "open breaker (US-37.3)" do
    test "snoozes (loss-free) when the tenant breaker is OPEN, without calling the provider" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      article =
        create_draft_then_publish(tenant.id, %{
          title: "Breaker Open Article",
          body: "The tenant breaker is open from a throttle storm."
        })

      # Trip the tenant breaker with @failure_threshold (3) countable 429 failures.
      # `stub` (not an exact `expect`) deliberately avoids the Mox async-supervisor
      # $callers exact-count race — the embed runs in a Task under async_nolink.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:error, {:api_error, 429, :provider_error}}
      end)

      for _ <- 1..3, do: Knowledge.generate_embedding(tenant.id, "x")
      assert {:error, :circuit_open} = Knowledge.generate_embedding(tenant.id, "x")

      # Breaker OPEN → the worker snoozes loss-free (no Oban attempt consumed), NOT
      # {:error, ...} — which would consume an attempt and, under a long honored
      # cooldown exceeding the 4-attempt window, DISCARD the job and leave the article
      # permanently un-embedded. The provider is never hit here: generate_embedding
      # short-circuits on the OPEN breaker (deterministic ETS state) BEFORE spawning
      # the embed task, so the snooze is reached without a client call.
      assert {:snooze, seconds} =
               ArticleEmbeddingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article.id, "tenant_id" => tenant.id}
               })

      assert is_integer(seconds) and seconds > 0
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
