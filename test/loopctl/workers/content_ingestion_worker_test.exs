defmodule Loopctl.Workers.ContentIngestionWorkerTest do
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  alias Loopctl.Knowledge
  alias Loopctl.Workers.ContentIngestionWorker

  defp setup_tenant do
    tenant = fixture(:tenant)
    %{tenant: tenant}
  end

  # --- Success: extracts articles from inline content ---

  describe "perform/1 with inline content" do
    test "extracts articles and inserts them as drafts" do
      %{tenant: tenant} = setup_tenant()

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn content, opts ->
        assert content == "Some raw content about Elixir patterns"
        assert opts[:source_type] == "newsletter"

        {:ok,
         [
           %{
             title: "Pattern from newsletter",
             body: "Use GenServer for stateful processes.",
             category: :pattern,
             tags: ["genserver", "otp"]
           }
         ]}
      end)

      assert :ok =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 42,
                 args: %{
                   "tenant_id" => tenant.id,
                   "content" => "Some raw content about Elixir patterns",
                   "content_hash" => "abc123",
                   "source_type" => "newsletter"
                 }
               })

      %{data: articles} = Knowledge.list_articles(tenant.id, source_type: "newsletter")
      assert length(articles) == 1
      [article] = articles
      assert article.title == "Pattern from newsletter"
      assert article.body == "Use GenServer for stateful processes."
      assert article.category == :pattern
      assert article.status == :draft
      assert article.source_type == "newsletter"
      # source_id is a deterministic UUID derived from the content_hash
      assert is_binary(article.source_id)
      assert article.tags == ["genserver", "otp"]
    end
  end

  # --- Success: fetches URL and extracts ---

  describe "perform/1 with URL" do
    test "fetches URL content, strips HTML, and extracts articles" do
      %{tenant: tenant} = setup_tenant()

      # Override the default Req.Test stub to return HTML content
      Req.Test.stub(ContentIngestionWorker, fn conn ->
        Req.Test.html(conn, "<html><body><h1>Title</h1><p>Content here</p></body></html>")
      end)

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn content, _opts ->
        # HTML should be stripped
        assert content =~ "Title"
        assert content =~ "Content here"
        refute content =~ "<html>"

        {:ok,
         [
           %{
             title: "Web article finding",
             body: "Important pattern from web.",
             category: :finding,
             tags: ["web"]
           }
         ]}
      end)

      assert :ok =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 99,
                 args: %{
                   "tenant_id" => tenant.id,
                   "url" => "https://example.com/article",
                   "content_hash" => "def456",
                   "source_type" => "web_article"
                 }
               })

      %{data: articles} = Knowledge.list_articles(tenant.id, source_type: "web_article")
      assert length(articles) == 1
      assert hd(articles).title == "Web article finding"
    end
  end

  # --- Validation filters invalid articles ---

  describe "perform/1 validation" do
    test "filters out articles with invalid categories" do
      %{tenant: tenant} = setup_tenant()

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _content, _opts ->
        {:ok,
         [
           %{title: "Valid", body: "Valid body.", category: :pattern},
           %{title: "Invalid", body: "Invalid body.", category: :nonexistent}
         ]}
      end)

      assert :ok =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 100,
                 args: %{
                   "tenant_id" => tenant.id,
                   "content" => "Test content",
                   "content_hash" => "filter_test",
                   "source_type" => "ingestion"
                 }
               })

      %{data: articles} = Knowledge.list_articles(tenant.id, source_type: "ingestion")
      assert length(articles) == 1
      assert hd(articles).title == "Valid"
    end

    test "filters out articles with empty title" do
      %{tenant: tenant} = setup_tenant()

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _content, _opts ->
        {:ok,
         [
           %{title: "Valid", body: "Body.", category: :convention},
           %{title: "", body: "Body.", category: :pattern}
         ]}
      end)

      assert :ok =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 101,
                 args: %{
                   "tenant_id" => tenant.id,
                   "content" => "Test content",
                   "content_hash" => "empty_title_test",
                   "source_type" => "ingestion"
                 }
               })

      %{data: articles} = Knowledge.list_articles(tenant.id, source_type: "ingestion")
      assert length(articles) == 1
      assert hd(articles).title == "Valid"
    end

    test "filters out articles with body exceeding 100KB" do
      %{tenant: tenant} = setup_tenant()

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _content, _opts ->
        {:ok,
         [
           %{title: "Valid", body: "Short body.", category: :pattern},
           %{title: "Too long", body: String.duplicate("x", 100_001), category: :pattern}
         ]}
      end)

      assert :ok =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 102,
                 args: %{
                   "tenant_id" => tenant.id,
                   "content" => "Content",
                   "content_hash" => "long_body_test",
                   "source_type" => "ingestion"
                 }
               })

      %{data: articles} = Knowledge.list_articles(tenant.id, source_type: "ingestion")
      assert length(articles) == 1
      assert hd(articles).title == "Valid"
    end

    test "enforces max 10 articles limit" do
      %{tenant: tenant} = setup_tenant()

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _content, _opts ->
        articles =
          for i <- 1..12 do
            %{
              title: "Article #{i} #{System.unique_integer([:positive])}",
              body: "Body #{i}.",
              category: :finding
            }
          end

        {:ok, articles}
      end)

      assert :ok =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 103,
                 args: %{
                   "tenant_id" => tenant.id,
                   "content" => "Content with many articles",
                   "content_hash" => "max_articles_test",
                   "source_type" => "ingestion"
                 }
               })

      %{data: articles} = Knowledge.list_articles(tenant.id, source_type: "ingestion")
      assert length(articles) == 10
    end
  end

  # --- Empty extractor output ---

  describe "perform/1 empty output" do
    test "returns :ok when extractor returns empty list" do
      %{tenant: tenant} = setup_tenant()

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _content, _opts ->
        {:ok, []}
      end)

      assert :ok =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 104,
                 args: %{
                   "tenant_id" => tenant.id,
                   "content" => "Empty content",
                   "content_hash" => "empty_test",
                   "source_type" => "ingestion"
                 }
               })

      %{data: articles} = Knowledge.list_articles(tenant.id, source_type: "ingestion")
      assert articles == []
    end
  end

  # --- Extractor failure ---

  describe "perform/1 extractor failure" do
    test "propagates error when extractor fails" do
      %{tenant: tenant} = setup_tenant()

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _content, _opts ->
        {:error, {:api_error, 500, "Internal Server Error"}}
      end)

      assert {:error, {:api_error, 500, "Internal Server Error"}} =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 105,
                 args: %{
                   "tenant_id" => tenant.id,
                   "content" => "Failing content",
                   "content_hash" => "fail_test",
                   "source_type" => "ingestion"
                 }
               })
    end
  end

  # --- Project scoping ---

  describe "perform/1 with project_id" do
    test "inserts articles scoped to the project" do
      %{tenant: tenant} = setup_tenant()
      project = fixture(:project, %{tenant_id: tenant.id})

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _content, _opts ->
        {:ok,
         [
           %{
             title: "Project-scoped article",
             body: "Body for project.",
             category: :decision,
             tags: ["project"]
           }
         ]}
      end)

      assert :ok =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 106,
                 args: %{
                   "tenant_id" => tenant.id,
                   "content" => "Project content",
                   "content_hash" => "project_test",
                   "source_type" => "ingestion",
                   "project_id" => project.id
                 }
               })

      %{data: articles} = Knowledge.list_articles(tenant.id, source_type: "ingestion")
      assert length(articles) == 1
      assert hd(articles).project_id == project.id
    end
  end

  # --- Tenant isolation ---

  describe "tenant isolation" do
    test "articles from tenant A are not visible to tenant B" do
      %{tenant: tenant_a} = setup_tenant()
      %{tenant: tenant_b} = setup_tenant()

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _content, _opts ->
        {:ok,
         [
           %{
             title: "Tenant A article",
             body: "Body for tenant A.",
             category: :pattern
           }
         ]}
      end)

      assert :ok =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 107,
                 args: %{
                   "tenant_id" => tenant_a.id,
                   "content" => "Content for A",
                   "content_hash" => "isolation_test",
                   "source_type" => "ingestion"
                 }
               })

      # Tenant A should see the article
      %{data: articles_a} = Knowledge.list_articles(tenant_a.id, source_type: "ingestion")
      assert length(articles_a) == 1

      # Tenant B should NOT see it
      %{data: articles_b} = Knowledge.list_articles(tenant_b.id, source_type: "ingestion")
      assert articles_b == []
    end
  end

  # --- Audit event ---

  describe "audit logging" do
    test "logs knowledge.content_ingested audit event" do
      %{tenant: tenant} = setup_tenant()

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _content, _opts ->
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
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 108,
                 args: %{
                   "tenant_id" => tenant.id,
                   "content" => "Audit test content",
                   "content_hash" => "audit_test",
                   "source_type" => "newsletter"
                 }
               })

      {:ok, %{data: logs}} =
        Loopctl.Audit.list_entries(tenant.id, action: "knowledge.content_ingested")

      assert logs != []
      log = hd(logs)
      assert log.action == "knowledge.content_ingested"
      assert log.entity_type == "article"
      assert log.new_state["source_type"] == "newsletter"
      assert log.new_state["article_count"] == 1
    end
  end

  # --- Backoff ---

  describe "backoff/1" do
    test "returns polynomial backoff values" do
      for attempt <- 1..3 do
        backoff = ContentIngestionWorker.backoff(%Oban.Job{attempt: attempt})

        min_expected = trunc(:math.pow(attempt, 4) + 15 + attempt)
        max_expected = trunc(:math.pow(attempt, 4) + 15 + 30 * attempt)

        assert backoff >= min_expected,
               "attempt #{attempt}: backoff #{backoff} < min #{min_expected}"

        assert backoff <= max_expected,
               "attempt #{attempt}: backoff #{backoff} > max #{max_expected}"
      end
    end
  end
end
