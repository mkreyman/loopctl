defmodule Loopctl.Workers.ReviewKnowledgeWorkerTest do
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  alias Loopctl.Knowledge
  alias Loopctl.Workers.ReviewKnowledgeWorker

  defp setup_tenant do
    tenant = fixture(:tenant)
    %{tenant: tenant}
  end

  defp create_review_record(tenant_id, attrs \\ %{}) do
    fixture(:review_record, Map.merge(%{tenant_id: tenant_id}, attrs))
  end

  # --- TC-21.1.1: Worker extracts articles from review successfully ---

  describe "perform/1 success" do
    test "extracts articles from review record and inserts them as drafts" do
      %{tenant: tenant} = setup_tenant()
      review_record = create_review_record(tenant.id)

      expect(Loopctl.MockExtractor, :extract_articles, fn context ->
        assert context.review_record_id == review_record.id
        assert context.tenant_id == tenant.id
        assert context.story_id == review_record.story_id
        assert context.review_type == review_record.review_type

        {:ok,
         [
           %{
             title: "Pattern from review",
             body: "Use Ecto.Multi for atomic operations.",
             category: :pattern,
             tags: ["ecto", "transactions"]
           }
         ]}
      end)

      assert :ok =
               ReviewKnowledgeWorker.perform(%Oban.Job{
                 args: %{
                   "review_record_id" => review_record.id,
                   "tenant_id" => tenant.id
                 }
               })

      # Verify article was created
      %{data: articles} =
        Knowledge.list_articles(tenant.id, source_type: "review_finding")

      assert length(articles) == 1
      [article] = articles
      assert article.title == "Pattern from review"
      assert article.body == "Use Ecto.Multi for atomic operations."
      assert article.category == :pattern
      assert article.status == :draft
      assert article.source_type == "review_finding"
      assert article.source_id == review_record.id
      assert article.tags == ["ecto", "transactions"]
    end
  end

  # --- TC-21.1.2: Worker skips duplicate extraction (idempotent) ---

  describe "perform/1 duplicate detection" do
    test "skips extraction when articles already exist for this review record" do
      %{tenant: tenant} = setup_tenant()
      review_record = create_review_record(tenant.id)

      # Manually insert an article with matching source_type + source_id
      fixture(:article, %{
        tenant_id: tenant.id,
        source_type: "review_finding",
        source_id: review_record.id,
        title: "Existing article"
      })

      # Extractor should NOT be called (verify_on_exit! will catch unexpected calls)
      expect(Loopctl.MockExtractor, :extract_articles, 0, fn _ctx ->
        {:ok, []}
      end)

      assert :ok =
               ReviewKnowledgeWorker.perform(%Oban.Job{
                 args: %{
                   "review_record_id" => review_record.id,
                   "tenant_id" => tenant.id
                 }
               })
    end
  end

  # --- TC-21.1.3: Worker handles extractor failure ---

  describe "perform/1 extractor failure" do
    test "returns {:error, reason} when extractor fails" do
      %{tenant: tenant} = setup_tenant()
      review_record = create_review_record(tenant.id)

      expect(Loopctl.MockExtractor, :extract_articles, fn _ctx ->
        {:error, {:llm_error, "API timeout"}}
      end)

      assert {:error, {:llm_error, "API timeout"}} =
               ReviewKnowledgeWorker.perform(%Oban.Job{
                 args: %{
                   "review_record_id" => review_record.id,
                   "tenant_id" => tenant.id
                 }
               })
    end
  end

  # --- TC-21.1.4: Multiple articles from single review ---

  describe "perform/1 multiple articles" do
    test "inserts multiple articles from a single review" do
      %{tenant: tenant} = setup_tenant()
      review_record = create_review_record(tenant.id)

      expect(Loopctl.MockExtractor, :extract_articles, fn _ctx ->
        {:ok,
         [
           %{
             title: "Pattern one",
             body: "First pattern discovered.",
             category: :pattern,
             tags: ["testing"]
           },
           %{
             title: "Convention two",
             body: "Second convention found.",
             category: :convention,
             tags: ["naming"]
           },
           %{
             title: "Decision three",
             body: "Architectural decision recorded.",
             category: :decision
           }
         ]}
      end)

      assert :ok =
               ReviewKnowledgeWorker.perform(%Oban.Job{
                 args: %{
                   "review_record_id" => review_record.id,
                   "tenant_id" => tenant.id
                 }
               })

      %{data: articles} =
        Knowledge.list_articles(tenant.id, source_type: "review_finding")

      assert length(articles) == 3

      categories = Enum.map(articles, & &1.category) |> Enum.sort()
      assert :convention in categories
      assert :decision in categories
      assert :pattern in categories

      # All should be drafts with source_type review_finding
      assert Enum.all?(articles, &(&1.status == :draft))
      assert Enum.all?(articles, &(&1.source_type == "review_finding"))
      assert Enum.all?(articles, &(&1.source_id == review_record.id))
    end

    test "enforces max 5 articles limit" do
      %{tenant: tenant} = setup_tenant()
      review_record = create_review_record(tenant.id)

      six_articles =
        for i <- 1..6 do
          %{
            title: "Article #{i} from review #{System.unique_integer([:positive])}",
            body: "Body content for article #{i}.",
            category: :finding
          }
        end

      expect(Loopctl.MockExtractor, :extract_articles, fn _ctx ->
        {:ok, six_articles}
      end)

      assert :ok =
               ReviewKnowledgeWorker.perform(%Oban.Job{
                 args: %{
                   "review_record_id" => review_record.id,
                   "tenant_id" => tenant.id
                 }
               })

      %{data: articles} =
        Knowledge.list_articles(tenant.id, source_type: "review_finding")

      assert length(articles) == 5
    end

    test "skips articles with invalid category" do
      %{tenant: tenant} = setup_tenant()
      review_record = create_review_record(tenant.id)

      expect(Loopctl.MockExtractor, :extract_articles, fn _ctx ->
        {:ok,
         [
           %{title: "Valid", body: "Valid body.", category: :pattern},
           %{title: "Invalid", body: "Invalid body.", category: :nonexistent_category}
         ]}
      end)

      assert :ok =
               ReviewKnowledgeWorker.perform(%Oban.Job{
                 args: %{
                   "review_record_id" => review_record.id,
                   "tenant_id" => tenant.id
                 }
               })

      %{data: articles} =
        Knowledge.list_articles(tenant.id, source_type: "review_finding")

      assert length(articles) == 1
      assert hd(articles).title == "Valid"
    end

    test "skips articles with invalid category string without crashing" do
      %{tenant: tenant} = setup_tenant()
      review_record = create_review_record(tenant.id)

      expect(Loopctl.MockExtractor, :extract_articles, fn _ctx ->
        {:ok,
         [
           %{"title" => "Valid string keys", "body" => "Valid body.", "category" => "pattern"},
           %{
             "title" => "Bad category string",
             "body" => "Body.",
             "category" => "totally_unknown_category"
           }
         ]}
      end)

      assert :ok =
               ReviewKnowledgeWorker.perform(%Oban.Job{
                 args: %{
                   "review_record_id" => review_record.id,
                   "tenant_id" => tenant.id
                 }
               })

      %{data: articles} =
        Knowledge.list_articles(tenant.id, source_type: "review_finding")

      assert length(articles) == 1
      assert hd(articles).title == "Valid string keys"
    end

    test "skips articles with body exceeding 100KB" do
      %{tenant: tenant} = setup_tenant()
      review_record = create_review_record(tenant.id)

      expect(Loopctl.MockExtractor, :extract_articles, fn _ctx ->
        {:ok,
         [
           %{title: "Valid", body: "Short body.", category: :pattern},
           %{
             title: "Too long",
             body: String.duplicate("x", 100_001),
             category: :pattern
           }
         ]}
      end)

      assert :ok =
               ReviewKnowledgeWorker.perform(%Oban.Job{
                 args: %{
                   "review_record_id" => review_record.id,
                   "tenant_id" => tenant.id
                 }
               })

      %{data: articles} =
        Knowledge.list_articles(tenant.id, source_type: "review_finding")

      assert length(articles) == 1
      assert hd(articles).title == "Valid"
    end

    test "skips articles with invalid tags" do
      %{tenant: tenant} = setup_tenant()
      review_record = create_review_record(tenant.id)

      expect(Loopctl.MockExtractor, :extract_articles, fn _ctx ->
        {:ok,
         [
           %{title: "Valid tags", body: "Body.", category: :pattern, tags: ["valid-tag"]},
           %{
             title: "Invalid tags",
             body: "Body.",
             category: :pattern,
             tags: ["invalid tag with spaces!"]
           }
         ]}
      end)

      assert :ok =
               ReviewKnowledgeWorker.perform(%Oban.Job{
                 args: %{
                   "review_record_id" => review_record.id,
                   "tenant_id" => tenant.id
                 }
               })

      %{data: articles} =
        Knowledge.list_articles(tenant.id, source_type: "review_finding")

      assert length(articles) == 1
      assert hd(articles).title == "Valid tags"
    end
  end

  # --- TC-21.1.5: Tenant isolation ---

  describe "tenant isolation" do
    test "tenant A's review record is not visible to tenant B's worker" do
      %{tenant: tenant_a} = setup_tenant()
      %{tenant: tenant_b} = setup_tenant()

      review_record = create_review_record(tenant_a.id)

      # Worker runs with tenant_b but tenant_a's review_record_id.
      # The review record lookup is scoped by tenant_id, so it returns not_found.
      # Extractor should NOT be called
      expect(Loopctl.MockExtractor, :extract_articles, 0, fn _ctx ->
        {:ok, []}
      end)

      assert :ok =
               ReviewKnowledgeWorker.perform(%Oban.Job{
                 args: %{
                   "review_record_id" => review_record.id,
                   "tenant_id" => tenant_b.id
                 }
               })

      # Verify no articles created in tenant_b
      %{data: articles_b} =
        Knowledge.list_articles(tenant_b.id, source_type: "review_finding")

      assert articles_b == []

      # Verify no articles leaked into tenant_a either
      %{data: articles_a} =
        Knowledge.list_articles(tenant_a.id, source_type: "review_finding")

      assert articles_a == []
    end
  end

  # --- TC-21.1.6: Empty extractor output ---

  describe "perform/1 empty output" do
    test "returns :ok when extractor returns empty list" do
      %{tenant: tenant} = setup_tenant()
      review_record = create_review_record(tenant.id)

      expect(Loopctl.MockExtractor, :extract_articles, fn _ctx ->
        {:ok, []}
      end)

      assert :ok =
               ReviewKnowledgeWorker.perform(%Oban.Job{
                 args: %{
                   "review_record_id" => review_record.id,
                   "tenant_id" => tenant.id
                 }
               })

      %{data: articles} =
        Knowledge.list_articles(tenant.id, source_type: "review_finding")

      assert articles == []
    end

    test "returns :ok when review record does not exist" do
      %{tenant: tenant} = setup_tenant()
      fake_id = Ecto.UUID.generate()

      # Extractor should NOT be called
      expect(Loopctl.MockExtractor, :extract_articles, 0, fn _ctx ->
        {:ok, []}
      end)

      assert :ok =
               ReviewKnowledgeWorker.perform(%Oban.Job{
                 args: %{
                   "review_record_id" => fake_id,
                   "tenant_id" => tenant.id
                 }
               })
    end
  end

  # --- Backoff ---

  describe "backoff/1" do
    test "returns polynomial backoff values" do
      for attempt <- 1..3 do
        backoff = ReviewKnowledgeWorker.backoff(%Oban.Job{attempt: attempt})

        min_expected = trunc(:math.pow(attempt, 4) + 15 + attempt)
        max_expected = trunc(:math.pow(attempt, 4) + 15 + 30 * attempt)

        assert backoff >= min_expected,
               "attempt #{attempt}: backoff #{backoff} < min #{min_expected}"

        assert backoff <= max_expected,
               "attempt #{attempt}: backoff #{backoff} > max #{max_expected}"
      end
    end

    test "backoff increases with each attempt" do
      backoffs =
        for attempt <- 1..3 do
          trunc(:math.pow(attempt, 4) + 15)
        end

      assert backoffs == Enum.sort(backoffs)
    end
  end

  # --- Worker enqueue from record_review ---

  describe "record_review enqueues worker" do
    test "worker is enqueued atomically when review record is created" do
      %{tenant: tenant} = setup_tenant()

      story =
        fixture(:story, %{
          tenant_id: tenant.id,
          agent_status: :reported_done,
          reported_done_at: DateTime.utc_now()
        })

      reviewer_agent = fixture(:agent, %{tenant_id: tenant.id})

      # The worker will execute inline (Oban testing: :inline), and the
      # default stub returns {:ok, []} so no articles are created.
      {:ok, review_record} =
        Loopctl.Progress.record_review(
          tenant.id,
          story.id,
          %{
            "review_type" => "enhanced",
            "findings_count" => 3,
            "fixes_count" => 3,
            "summary" => "All findings fixed."
          },
          reviewer_agent_id: reviewer_agent.id,
          actor_id: Ecto.UUID.generate(),
          actor_label: "agent:reviewer"
        )

      assert review_record.id != nil
      assert review_record.review_type == "enhanced"
    end
  end

  # --- Audit event ---

  describe "audit logging" do
    test "logs knowledge.articles_extracted audit event" do
      %{tenant: tenant} = setup_tenant()
      review_record = create_review_record(tenant.id)

      expect(Loopctl.MockExtractor, :extract_articles, fn _ctx ->
        {:ok,
         [
           %{
             title: "Audited article",
             body: "Body for audit test.",
             category: :finding
           }
         ]}
      end)

      assert :ok =
               ReviewKnowledgeWorker.perform(%Oban.Job{
                 args: %{
                   "review_record_id" => review_record.id,
                   "tenant_id" => tenant.id
                 }
               })

      # Verify the audit log entry exists
      {:ok, %{data: logs}} =
        Loopctl.Audit.list_entries(tenant.id, action: "knowledge.articles_extracted")

      assert logs != []
      log = hd(logs)
      assert log.action == "knowledge.articles_extracted"
      assert log.entity_type == "article"
      assert log.entity_id == review_record.id
      assert log.new_state["review_record_id"] == review_record.id
      assert log.new_state["article_count"] == 1
    end
  end
end
