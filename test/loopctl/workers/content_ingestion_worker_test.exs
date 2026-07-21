defmodule Loopctl.Workers.ContentIngestionWorkerTest do
  @moduledoc """
  `async: false` ON PURPOSE. The US-37.4 batching test seeds the NODE-GLOBAL
  `{Loopctl.SystemConfig, "embedding_batch_max"}` `:persistent_term` knob (the
  documented key format, erased on exit) to drive the batch-size math. That key
  is VM-global — NOT ExUnit-sandbox/transaction scoped — and is read globally by
  `Knowledge.embedding_batch_max/0`, so mutating it while an async peer (e.g.
  `KnowledgeLintWorkerTest`, which relies on the default batch_max) runs
  concurrently would cross-contaminate the peer's chunk math. A sync test never
  runs concurrently with any other test, so the seed can't leak — mirrors
  `Loopctl.KnowledgeBreakerLatencyTest`.
  """
  use Loopctl.DataCase, async: false
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  alias Loopctl.Knowledge
  alias Loopctl.Test.AllowlistSource
  alias Loopctl.Workers.ContentIngestionWorker

  defp setup_tenant do
    tenant = fixture(:tenant)
    # Mandatory BYO (Epic 28, #179): configure a tenant Anthropic key so the
    # worker's has_api_key? gate passes and extraction proceeds.
    fixture(:tenant_llm_settings, %{tenant_id: tenant.id})
    %{tenant: tenant}
  end

  # Build a document that ContentChunker splits into exactly `sections` chunks.
  # Each section body is ~5.5KB — under the 8KB threshold (so it is never
  # force-split) but large enough that two adjacent sections (~11KB) can't merge
  # into one chunk. Net: one chunk per section.
  defp multi_chunk_content(sections) do
    1..sections
    |> Enum.map_join("\n\n", fn i ->
      "# Section #{i}\n\n" <> String.duplicate("word#{i} ", 900)
    end)
  end

  # --- Mandatory BYO (Epic 28, #179) ---

  describe "perform/1 mandatory BYO enforcement" do
    test "discards cleanly (no crash, no retry) when the tenant has no Anthropic key" do
      # A tenant WITHOUT an llm settings row (no key configured).
      tenant = fixture(:tenant)

      # The extractor must never be called — we discard before any LLM work.
      Mox.stub(Loopctl.MockContentExtractor, :extract_from_content, fn _t, _c, _o ->
        flunk("extractor should not run without a tenant key")
      end)

      assert {:discard, {:no_api_key, _reason}} =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 1,
                 args: %{
                   "tenant_id" => tenant.id,
                   "content" => "some content",
                   "content_hash" => "nokey123",
                   "source_type" => "newsletter"
                 }
               })

      %{data: articles} = Knowledge.list_articles(tenant.id, source_type: "newsletter")
      assert articles == []
    end
  end

  # --- Success: extracts articles from inline content ---

  describe "perform/1 with inline content" do
    test "extracts articles and inserts them as drafts" do
      %{tenant: tenant} = setup_tenant()

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id, content, opts ->
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

      %{data: articles} =
        Knowledge.list_articles(tenant.id, source_type: "newsletter", include_body: true)

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

      # Drafts are not embedded.
      {:ok, with_embedding} = Knowledge.get_article_with_embedding(tenant.id, article.id)
      assert is_nil(with_embedding.embedding)
    end

    test "publishes extracted articles when publish: true is set" do
      %{tenant: tenant} = setup_tenant()

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                     _content,
                                                                     _opts ->
        {:ok,
         [
           %{
             title: "Published from ingest",
             body: "Visible immediately.",
             category: :pattern,
             tags: ["x"]
           }
         ]}
      end)

      assert :ok =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 43,
                 args: %{
                   "tenant_id" => tenant.id,
                   "content" => "raw",
                   "content_hash" => "pub123",
                   "source_type" => "newsletter",
                   "publish" => true
                 }
               })

      %{data: [article]} = Knowledge.list_articles(tenant.id, source_type: "newsletter")
      assert article.status == :published

      # Published articles are embedded (Oban runs :inline in tests, so the
      # enqueued BatchArticleEmbeddingWorker has already populated the vector).
      {:ok, with_embedding} = Knowledge.get_article_with_embedding(tenant.id, article.id)
      refute is_nil(with_embedding.embedding)
    end

    test "US-37.4: auto-published ingest BATCHES embeddings — M articles => ceil(M/batch_max) provider calls, not M" do
      %{tenant: tenant} = setup_tenant()
      test_pid = self()

      # env-driven batch_max WITHOUT Application.put_env: drive the SystemConfig cache
      # directly and erase on exit. 5 ingested articles / batch_max 2 => ceil = 3 calls.
      pt_key = {Loopctl.SystemConfig, "embedding_batch_max"}
      :persistent_term.put(pt_key, 2)
      on_exit(fn -> :persistent_term.erase(pt_key) end)

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _t, _c, _o ->
        {:ok,
         for i <- 1..5 do
           %{title: "Ingested #{i}", body: "body #{i}", category: :pattern, tags: []}
         end}
      end)

      # Count provider round-trips via a message per BATCH call (the array path),
      # avoiding a Mox exact-count race across the async_nolink task.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _tenant_id, texts ->
        send(test_pid, {:batch_call, length(texts)})
        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 1536) end)}
      end)

      # The single-text path must NEVER be used for bulk ingest.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        flunk("bulk ingest must use the batch path, not per-article generate_embedding/2")
      end)

      assert :ok =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 44,
                 args: %{
                   "tenant_id" => tenant.id,
                   "content" => "raw",
                   "content_hash" => "batch123",
                   "source_type" => "newsletter",
                   "publish" => true
                 }
               })

      # ceil(5 / 2) = 3 provider calls (chunks of 2, 2, 1) — NOT 5.
      calls = drain_batch_calls([])
      assert length(calls) == 3
      assert Enum.sort(calls, :desc) == [2, 2, 1]
    end
  end

  # Collect all {:batch_call, n} messages currently in the mailbox (batch workers ran
  # inline before perform/1 returned, so they're all already delivered).
  defp drain_batch_calls(acc) do
    receive do
      {:batch_call, n} -> drain_batch_calls([n | acc])
    after
      0 -> acc
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

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id, content, _opts ->
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

    test "aborts and rejects a fetch whose body exceeds the network-layer cap (#461 item 4)" do
      %{tenant: tenant} = setup_tenant()

      # A body larger than @max_fetch_body_bytes (5_000_000). The bounded `into:`
      # collector halts the transfer and flags the response, so fetch_url returns
      # a :url_body_too_large error BEFORE any extraction — the extractor is never
      # reached and nothing is persisted.
      oversized = String.duplicate("a", 5_000_001)

      Req.Test.stub(ContentIngestionWorker, fn conn ->
        Req.Test.html(conn, oversized)
      end)

      assert {:error, {:url_body_too_large, cap}} =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 314,
                 args: %{
                   "tenant_id" => tenant.id,
                   "url" => "https://example.com/huge",
                   "content_hash" => "huge1",
                   "source_type" => "web_article"
                 }
               })

      assert cap == 5_000_000
      assert %{data: []} = Knowledge.list_articles(tenant.id, source_type: "web_article")
    end

    test "collect_capped_body/2 halts once CUMULATIVE sub-cap chunks cross the cap (#461 item 4, streaming path)" do
      # The test above feeds an oversized body as ONE chunk, exercising only the
      # single-shot > cap branch. The cap actually defends the STREAMING case: many
      # individually-sub-cap chunks whose running total crosses @max_fetch_body_bytes
      # (5MB). That cumulative `:cont` accumulation cannot be exercised end-to-end via
      # a stub — `Req.Test`/`plug:` buffers `send_chunked`/`chunk` output and delivers
      # it to the `into:` collector as a SINGLE `{:data, _}` message — so drive the
      # collector directly with three 2MB chunks (6MB total).
      req = Req.new()
      resp0 = Req.Response.new()

      # 2MB chunk — well under the 5MB per-nothing cap on its own.
      chunk = String.duplicate("a", 2_000_000)

      # First two chunks (2MB, then 4MB cumulative) stay under the cap → :cont, no flag.
      assert {:cont, {^req, resp1}} =
               ContentIngestionWorker.collect_capped_body({:data, chunk}, {req, resp0})

      refute Req.Response.get_private(resp1, :ingestion_body_capped)

      assert {:cont, {^req, resp2}} =
               ContentIngestionWorker.collect_capped_body({:data, chunk}, {req, resp1})

      refute Req.Response.get_private(resp2, :ingestion_body_capped)

      # Third chunk pushes the running total to 6MB, past the 5MB cap → :halt + flag.
      assert {:halt, {^req, resp3}} =
               ContentIngestionWorker.collect_capped_body({:data, chunk}, {req, resp2})

      assert Req.Response.get_private(resp3, :ingestion_body_capped) == true

      # The accumulated iolist holds the full 6MB intact (never truncated mid-stream);
      # fetch_url/2 flattens it with IO.iodata_to_binary/1.
      assert resp3.body |> IO.iodata_to_binary() |> byte_size() == 6_000_000
    end
  end

  # --- SSRF egress guard (worker-01 / GHSA-j7m9-ffmr-pwhm) ---

  describe "perform/1 refuses blocked URLs (SSRF)" do
    test "refuses to fetch the cloud metadata endpoint" do
      %{tenant: tenant} = setup_tenant()

      # The extractor must never be reached — the guard short-circuits before
      # any HTTP fetch or extraction.
      Req.Test.stub(ContentIngestionWorker, fn _conn ->
        flunk("SSRF guard should have blocked the request before Req.get/1")
      end)

      # US-41.5 review: the SSRF call is made by the ONE policy
      # (`denylist_gate/4` on a `tenant_supplied_url`), not by a second
      # `UrlGuard.pin/1` pre-gate — so the refusal is the PERMANENT
      # `:egress_blocked`, which `Egress.oban_result/1` CANCELS (it was retried as
      # a generic error before). Nothing is fetched either way.
      assert {:cancel, reason} =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 200,
                 args: %{
                   "tenant_id" => tenant.id,
                   "url" => "http://169.254.169.254/latest/meta-data/",
                   "content_hash" => "ssrf1",
                   "source_type" => "web_article"
                 }
               })

      assert reason =~ "egress_blocked"
      assert reason =~ "denylisted"
      assert reason =~ "169.254.169.254"

      assert %{data: []} = Knowledge.list_articles(tenant.id, source_type: "web_article")
    end

    test "refuses a hostname that resolves to a private address (DNS rebinding)" do
      %{tenant: tenant} = setup_tenant()

      expect(Loopctl.MockDnsResolver, :resolve, fn _host ->
        {:ok, [{10, 0, 0, 5}]}
      end)

      assert {:cancel, reason} =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 201,
                 args: %{
                   "tenant_id" => tenant.id,
                   "url" => "https://rebind.example.com/x",
                   "content_hash" => "ssrf2",
                   "source_type" => "web_article"
                 }
               })

      assert reason =~ "egress_blocked"
      assert reason =~ "denylisted"
      assert reason =~ "rebind.example.com"
    end

    # The operator deployment allowlist could not be consulted while the fetch
    # was pre-gated by a bare `UrlGuard.pin/1`: an allowlisted private host was a
    # legal WEBHOOK destination but still a hard refusal as an INGESTION source.
    # Now both paths ask the same policy (US-41.5 review).
    test "an OPERATOR-allowlisted private host is fetchable as an ingestion source" do
      %{tenant: tenant} = setup_tenant()

      stub(Loopctl.MockDnsResolver, :resolve, fn _host -> {:ok, [{10, 0, 0, 5}]} end)

      Req.Test.stub(ContentIngestionWorker, fn conn ->
        Req.Test.html(conn, "<html><body>Allowlisted ingest body</body></html>")
      end)

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                     _content,
                                                                     _opts ->
        {:ok,
         [
           %{
             title: "Allowlisted host finding",
             body: "Important pattern from an allowlisted internal host.",
             category: :finding,
             tags: ["egress"]
           }
         ]}
      end)

      AllowlistSource.put(["10.0.0.0/8"])

      try do
        assert :ok =
                 ContentIngestionWorker.perform(%Oban.Job{
                   id: 202,
                   args: %{
                     "tenant_id" => tenant.id,
                     "url" => "https://internal.example.com/doc",
                     "content_hash" => "allowlisted1",
                     "source_type" => "web_article"
                   }
                 })
      after
        AllowlistSource.clear()
      end

      %{data: articles} = Knowledge.list_articles(tenant.id, source_type: "web_article")
      assert Enum.any?(articles, &(&1.title == "Allowlisted host finding"))
    end
  end

  # --- Validation filters invalid articles ---

  describe "perform/1 validation" do
    test "filters out articles with invalid categories" do
      %{tenant: tenant} = setup_tenant()

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                     _content,
                                                                     _opts ->
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

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                     _content,
                                                                     _opts ->
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

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                     _content,
                                                                     _opts ->
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

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                     _content,
                                                                     _opts ->
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

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                     _content,
                                                                     _opts ->
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
    test "propagates a transient error, sanitized (no provider body reaches the Oban reason)" do
      %{tenant: tenant} = setup_tenant()
      masked = "sk-ant-...5XX-LEAK"

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                     _content,
                                                                     _opts ->
        {:error, {:api_error, 500, "upstream error echoing key #{masked}"}}
      end)

      # The 500 is transient -> {:error, _} (Oban retry), but the reason that lands
      # in oban_jobs.errors is SANITIZED (review #5): status only, never the body.
      result =
        ContentIngestionWorker.perform(%Oban.Job{
          id: 105,
          args: %{
            "tenant_id" => tenant.id,
            "content" => "Failing content",
            "content_hash" => "fail_test",
            "source_type" => "ingestion"
          }
        })

      assert {:error, {:api_error, 500, :provider_error}} = result
      refute inspect(result) =~ masked
    end

    test "a permanent 4xx DISCARDS with a sanitized reason (no key fragment)" do
      %{tenant: tenant} = setup_tenant()
      masked = "sk-ant-...4XX-LEAK"

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                     _content,
                                                                     _opts ->
        {:error, {:api_error, 401, "Invalid x-api-key header: #{masked}"}}
      end)

      result =
        ContentIngestionWorker.perform(%Oban.Job{
          id: 106,
          args: %{
            "tenant_id" => tenant.id,
            "content" => "Failing content",
            "content_hash" => "fail_test_4xx",
            "source_type" => "ingestion"
          }
        })

      # Permanent -> discard; the extraction_failed message embeds the SANITIZED
      # `first` error, so no masked key fragment can reach oban_jobs.errors.
      assert {:discard, {:extraction_failed, message}} = result
      assert message =~ "api_error"
      refute message =~ masked
      refute inspect(result) =~ masked
    end

    test "US-37.1 (AC-37.1.4): a node-local admission rate-limit SNOOZES (never burns an attempt/discards)" do
      %{tenant: tenant} = setup_tenant()

      # The provider admission gate is shut for this tenant -> the extractor returns
      # the new {:error, :rate_limited_local}. This is loss-free backpressure, NOT a
      # failure: the job must snooze (no attempt consumed) rather than retry/discard.
      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                     _content,
                                                                     _opts ->
        {:error, :rate_limited_local}
      end)

      result =
        ContentIngestionWorker.perform(%Oban.Job{
          id: 107,
          args: %{
            "tenant_id" => tenant.id,
            "content" => "Rate limited content",
            "content_hash" => "rate_limited_local_test",
            "source_type" => "ingestion"
          }
        })

      assert {:snooze, seconds} = result
      assert is_integer(seconds) and seconds > 0
    end

    test "US-37.3 (AC-37.3.3): an extraction throttle carrying a Retry-After SNOOZES ~that interval" do
      %{tenant: tenant} = setup_tenant()

      # The Anthropic extraction was throttled (429/503) and surfaced the throttle
      # 4-tuple with a parsed, clamped Retry-After. The whole job snoozes loss-free
      # (no attempt consumed) for ~that interval instead of the blind attempt^4 backoff.
      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                     _content,
                                                                     _opts ->
        {:error, {:api_error, 429, :provider_error, 30}}
      end)

      result =
        ContentIngestionWorker.perform(%Oban.Job{
          id: 108,
          args: %{
            "tenant_id" => tenant.id,
            "content" => "Throttled content",
            "content_hash" => "throttle_retry_after_test",
            "source_type" => "ingestion"
          }
        })

      assert {:snooze, 30} = result
    end
  end

  # --- Project scoping ---

  describe "perform/1 with project_id" do
    test "inserts articles scoped to the project" do
      %{tenant: tenant} = setup_tenant()
      project = fixture(:project, %{tenant_id: tenant.id})

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                     _content,
                                                                     _opts ->
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

  describe "perform/1 with an invalid project_id (kbweb-01 poison pill)" do
    test "a malformed project_id is discarded cleanly (no raise, no crash-loop, nothing inserted)" do
      %{tenant: tenant} = setup_tenant()

      # Discarded BEFORE any extraction, so the extractor is never invoked.
      result =
        ContentIngestionWorker.perform(%Oban.Job{
          id: 201,
          args: %{
            "tenant_id" => tenant.id,
            "content" => "Poison pill content",
            "content_hash" => "poison_malformed",
            "source_type" => "ingestion",
            "project_id" => "not-a-uuid"
          }
        })

      assert {:discard, {:invalid_project_id, "not-a-uuid"}} = result

      assert %{meta: %{total_count: 0}} =
               Knowledge.list_articles(tenant.id, source_type: "ingestion")
    end

    test "a non-string (array/map) project_id is discarded cleanly, not raised" do
      %{tenant: tenant} = setup_tenant()

      result =
        ContentIngestionWorker.perform(%Oban.Job{
          id: 202,
          args: %{
            "tenant_id" => tenant.id,
            "content" => "Array poison content",
            "content_hash" => "poison_array",
            "source_type" => "ingestion",
            "project_id" => ["x"]
          }
        })

      assert {:discard, {:invalid_project_id, ["x"]}} = result
    end

    test "an empty-string project_id is treated as tenant-wide (normalized to nil), still ingests" do
      %{tenant: tenant} = setup_tenant()

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                     _content,
                                                                     _opts ->
        {:ok, [%{title: "Blank pid article", body: "Body.", category: :pattern, tags: []}]}
      end)

      assert :ok =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 203,
                 args: %{
                   "tenant_id" => tenant.id,
                   "content" => "Blank project content",
                   "content_hash" => "blank_pid",
                   "source_type" => "ingestion",
                   "project_id" => ""
                 }
               })

      %{data: articles} = Knowledge.list_articles(tenant.id, source_type: "ingestion")
      assert length(articles) == 1
      assert is_nil(hd(articles).project_id)
    end
  end

  # --- Tenant isolation ---

  describe "tenant isolation" do
    test "articles from tenant A are not visible to tenant B" do
      %{tenant: tenant_a} = setup_tenant()
      %{tenant: tenant_b} = setup_tenant()

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                     _content,
                                                                     _opts ->
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

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                     _content,
                                                                     _opts ->
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

  # --- #263: PDF / non-UTF-8 binary content is discarded, never crash-looped ---

  describe "perform/1 unsupported (PDF/binary) content (#263)" do
    test "URL returning application/pdf is discarded cleanly (no Jason.EncodeError, no retry)" do
      %{tenant: tenant} = setup_tenant()

      # A real PDF magic header + a non-UTF-8 byte (0xE2 as a lone byte). Handing
      # this to the JSON-encoded extractor request would raise Jason.EncodeError.
      pdf_bytes = <<0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34, 0x0A, 0xE2, 0x00, 0xFF>>

      Req.Test.stub(ContentIngestionWorker, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/pdf")
        |> Plug.Conn.send_resp(200, pdf_bytes)
      end)

      # The extractor must NEVER be reached — the guard short-circuits first.
      Mox.stub(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                       _content,
                                                                       _opts ->
        flunk("extractor must not be called for binary content")
      end)

      assert {:discard, {:unsupported_content, reason}} =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 300,
                 args: %{
                   "tenant_id" => tenant.id,
                   "url" => "https://example.com/report.pdf",
                   "content_hash" => "pdf_url",
                   "source_type" => "web_article"
                 }
               })

      assert reason =~ "application/pdf"
      assert %{data: []} = Knowledge.list_articles(tenant.id, source_type: "web_article")
    end

    test "a mislabeled body (text/plain header, non-UTF-8 bytes) is discarded via the String.valid? backstop" do
      %{tenant: tenant} = setup_tenant()

      # Content-Type lies (text/plain) but the bytes are invalid UTF-8.
      binary_body = <<0xFF, 0xFE, 0x00, 0xE2, 0x82>>

      Req.Test.stub(ContentIngestionWorker, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(200, binary_body)
      end)

      Mox.stub(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                       _content,
                                                                       _opts ->
        flunk("extractor must not be called for non-UTF-8 content")
      end)

      assert {:discard, {:unsupported_content, reason}} =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 301,
                 args: %{
                   "tenant_id" => tenant.id,
                   "url" => "https://example.com/mislabeled",
                   "content_hash" => "mislabeled_url",
                   "source_type" => "web_article"
                 }
               })

      assert reason =~ "UTF-8"
    end

    test "direct non-UTF-8 inline content is discarded cleanly" do
      %{tenant: tenant} = setup_tenant()

      Mox.stub(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                       _content,
                                                                       _opts ->
        flunk("extractor must not be called for non-UTF-8 inline content")
      end)

      assert {:discard, {:unsupported_content, _reason}} =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 302,
                 args: %{
                   "tenant_id" => tenant.id,
                   "content" => <<0x25, 0x50, 0x44, 0x46, 0xE2, 0x00>>,
                   "content_hash" => "pdf_inline",
                   "source_type" => "ingestion"
                 }
               })
    end

    test "a normal UTF-8 URL body still ingests (guard does not over-block)" do
      %{tenant: tenant} = setup_tenant()

      Req.Test.stub(ContentIngestionWorker, fn conn ->
        Req.Test.html(conn, "<html><body><p>Perfectly valid text</p></body></html>")
      end)

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id, content, _opts ->
        assert content =~ "Perfectly valid text"

        {:ok, [%{title: "Valid web", body: "Body.", category: :finding, tags: ["web"]}]}
      end)

      assert :ok =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 303,
                 args: %{
                   "tenant_id" => tenant.id,
                   "url" => "https://example.com/ok",
                   "content_hash" => "ok_url",
                   "source_type" => "web_article"
                 }
               })

      %{data: [article]} = Knowledge.list_articles(tenant.id, source_type: "web_article")
      assert article.title == "Valid web"
    end
  end

  # --- #264: multi-chunk documents ingest; partial progress survives failure ---

  describe "perform/1 multi-chunk ingestion (#264)" do
    test "every chunk's articles are persisted (one article per chunk)" do
      %{tenant: tenant} = setup_tenant()

      # 4 sections -> 4 chunks. The extractor returns a distinct article per call.
      counter = :counters.new(1, [])

      Mox.stub(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                       _chunk,
                                                                       _opts ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)

        {:ok, [%{title: "Chunk article #{n}", body: "Body #{n}.", category: :pattern}]}
      end)

      assert :ok =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 400,
                 args: %{
                   "tenant_id" => tenant.id,
                   "content" => multi_chunk_content(4),
                   "content_hash" => "multi_chunk_ok",
                   "source_type" => "newsletter"
                 }
               })

      %{data: articles} = Knowledge.list_articles(tenant.id, source_type: "newsletter")
      # 4 chunks -> 4 articles, all persisted.
      assert length(articles) == 4
    end

    test "partial progress: earlier chunks persist AND a transient later failure is retryable (#264 Finding 2)" do
      %{tenant: tenant} = setup_tenant()

      # First chunk succeeds (persisted immediately); the second simulates a
      # transient failure. The earlier chunk's article MUST survive AND the job
      # must return {:error} (retryable) — not :ok — so Oban re-attempts the
      # failed chunk instead of marking the job :completed and losing it forever.
      counter = :counters.new(1, [])

      Mox.stub(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                       _chunk,
                                                                       _opts ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)

        if n == 1 do
          {:ok, [%{title: "Survivor", body: "Persisted before the failure.", category: :pattern}]}
        else
          {:error, {:request_failed, :timeout}}
        end
      end)

      assert {:error, {:request_failed, :timeout}} =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 401,
                 args: %{
                   "tenant_id" => tenant.id,
                   "content" => multi_chunk_content(3),
                   "content_hash" => "partial_progress",
                   "source_type" => "newsletter"
                 }
               })

      # The earlier chunk's article is durably committed despite the later failure.
      %{data: articles} = Knowledge.list_articles(tenant.id, source_type: "newsletter")
      assert length(articles) == 1
      assert hd(articles).title == "Survivor"
    end

    test "an Oban retry (SAME args) after partial persistence does NOT duplicate rows (#264 Finding 1)" do
      %{tenant: tenant} = setup_tenant()

      job_args = %{
        "tenant_id" => tenant.id,
        "content" => multi_chunk_content(4),
        "content_hash" => "retry_idempotent",
        "source_type" => "newsletter"
      }

      # A distinct article per chunk; titles/bodies vary per CALL (simulating LLM
      # non-determinism) so the idempotency guarantee can't depend on the output.
      call = :counters.new(1, [])

      Mox.stub(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                       _chunk,
                                                                       _opts ->
        :counters.add(call, 1, 1)
        n = :counters.get(call, 1)

        {:ok,
         [
           %{
             title: "Article #{n}",
             body: "Body #{n} at #{System.unique_integer()}.",
             category: :pattern
           }
         ]}
      end)

      # First run persists all 4 chunks.
      assert :ok = ContentIngestionWorker.perform(%Oban.Job{id: 410, args: job_args})

      %{meta: %{total_count: after_first}} =
        Knowledge.list_articles(tenant.id, source_type: "newsletter")

      assert after_first == 4

      # Simulate Oban re-invoking perform/1 with IDENTICAL args (a retry / redeploy
      # after the chunks were already committed). It must NOT double the rows.
      assert :ok = ContentIngestionWorker.perform(%Oban.Job{id: 410, args: job_args})

      %{meta: %{total_count: after_retry}} =
        Knowledge.list_articles(tenant.id, source_type: "newsletter")

      assert after_retry == 4, "retry duplicated rows: #{after_first} -> #{after_retry}"
    end

    test "retry re-attempts ONLY the previously-failed chunk without duplicating the others (#264)" do
      %{tenant: tenant} = setup_tenant()

      job_args = %{
        "tenant_id" => tenant.id,
        "content" => multi_chunk_content(3),
        "content_hash" => "retry_failed_chunk",
        "source_type" => "newsletter"
      }

      # Run 1: chunks 1 & 3 succeed, chunk 2 fails transiently.
      # Run 2 (retry): chunk 2 is re-extracted; chunks 1 & 3 are SKIPPED (already
      # persisted — no re-BILL, #179 review #1). The per-chunk verdict keys off the
      # chunk's CONTENT (its "Section N"), NOT a global call counter, precisely so it
      # stays correct when the retry re-invokes the extractor for ONLY the failed chunk.
      run = :counters.new(1, [])

      section_no = fn chunk ->
        case Regex.run(~r/Section (\d+)/, chunk) do
          [_, n] -> String.to_integer(n)
          _ -> 0
        end
      end

      Mox.stub(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id, chunk, _opts ->
        idx = section_no.(chunk)
        run_no = :counters.get(run, 1)

        if idx == 2 and run_no == 0 do
          {:error, {:request_failed, :timeout}}
        else
          {:ok, [%{title: "Chunk #{idx}", body: "Body #{idx}.", category: :pattern}]}
        end
      end)

      # Run 1 → retryable error, chunks 1 & 3 persisted (2 rows).
      assert {:error, _} = ContentIngestionWorker.perform(%Oban.Job{id: 411, args: job_args})

      %{meta: %{total_count: after_run1}} =
        Knowledge.list_articles(tenant.id, source_type: "newsletter")

      assert after_run1 == 2

      # Advance to run 2 (all chunks succeed).
      :counters.add(run, 1, 1)
      assert :ok = ContentIngestionWorker.perform(%Oban.Job{id: 411, args: job_args})

      %{meta: %{total_count: after_run2}} =
        Knowledge.list_articles(tenant.id, source_type: "newsletter")

      # 3 total: chunks 1 & 3 unchanged (idempotent no-op), chunk 2 newly added.
      assert after_run2 == 3, "expected only the failed chunk to be added, got #{after_run2}"
    end

    test "a retry does NOT re-invoke the extractor for chunks already persisted (no re-bill, review #1)" do
      %{tenant: tenant} = setup_tenant()

      job_args = %{
        "tenant_id" => tenant.id,
        "content" => multi_chunk_content(2),
        "content_hash" => "no_rebill",
        "source_type" => "newsletter"
      }

      # First attempt: both chunks succeed (a distinct title per chunk content).
      Mox.stub(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id, chunk, _opts ->
        n = :erlang.phash2(chunk)
        {:ok, [%{title: "Article #{n}", body: "Body #{n}.", category: :pattern}]}
      end)

      assert :ok = ContentIngestionWorker.perform(%Oban.Job{id: 420, args: job_args})

      %{meta: %{total_count: after_first}} =
        Knowledge.list_articles(tenant.id, source_type: "newsletter")

      assert after_first == 2

      # Retry (SAME args): every chunk is already durably persisted, so the extractor
      # (the TENANT-BILLED Anthropic call) must NOT be invoked even once.
      Mox.expect(Loopctl.MockContentExtractor, :extract_from_content, 0, fn _t, _c, _o ->
        flunk("extractor must not be re-invoked for already-persisted chunks (re-bill)")
      end)

      assert :ok = ContentIngestionWorker.perform(%Oban.Job{id: 420, args: job_args})

      %{meta: %{total_count: after_retry}} =
        Knowledge.list_articles(tenant.id, source_type: "newsletter")

      assert after_retry == 2
    end

    test "a URL whose content CHANGED between attempts RE-EXTRACTS the new bytes (no false skip, round-4 review)" do
      %{tenant: tenant} = setup_tenant()

      # Two DIFFERENT fetch bodies across the two perform/1 calls with the SAME job
      # args. The chunk-skip must key on the FETCHED BYTES, not the enqueue-time
      # content_hash (= sha256(url) for a URL job): keying on the URL would find V1's
      # chunk-0 titles under the same prefix and SILENTLY skip extracting V2 (stale
      # content, zero signal). Keying on sha256(bytes) re-extracts the changed bytes.
      extract_count = :counters.new(1, [])
      fetch_count = :counters.new(1, [])

      Req.Test.stub(ContentIngestionWorker, fn conn ->
        :counters.add(fetch_count, 1, 1)

        body =
          if :counters.get(fetch_count, 1) == 1,
            do: "First version of the page about alpha widgets",
            else: "Second version of the page about beta gadgets"

        Req.Test.text(conn, body)
      end)

      Mox.stub(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                       content,
                                                                       _opts ->
        :counters.add(extract_count, 1, 1)
        title = if content =~ "alpha", do: "V1 article", else: "V2 article"
        {:ok, [%{title: title, body: "Body.", category: :pattern}]}
      end)

      args = %{
        "tenant_id" => tenant.id,
        "url" => "https://example.com/dynamic-page",
        "content_hash" => "url_change_test",
        "source_type" => "web_article"
      }

      # Run 1: fetch V1 → extract "V1 article".
      assert :ok = ContentIngestionWorker.perform(%Oban.Job{id: 430, args: args})

      # Run 2 (retry, IDENTICAL args): fetch V2 (different bytes) → MUST re-extract.
      assert :ok = ContentIngestionWorker.perform(%Oban.Job{id: 430, args: args})

      # The extractor was invoked on BOTH attempts (no false skip on the changed URL).
      assert :counters.get(extract_count, 1) == 2

      # V2's genuinely-new content was captured (not silently kept as stale V1).
      %{data: articles} = Knowledge.list_articles(tenant.id, source_type: "web_article")
      titles = Enum.map(articles, & &1.title)
      assert "V2 article" in titles
    end

    test "a PERMANENT (4xx) extraction failure is discarded, not retried forever (#264 Finding 2)" do
      %{tenant: tenant} = setup_tenant()

      Mox.stub(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                       _chunk,
                                                                       _opts ->
        {:error, {:api_error, 400, "bad request"}}
      end)

      assert {:discard, {:extraction_failed, reason}} =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 412,
                 args: %{
                   "tenant_id" => tenant.id,
                   "content" => multi_chunk_content(3),
                   "content_hash" => "permanent_fail",
                   "source_type" => "newsletter"
                 }
               })

      assert reason =~ "not retryable"
    end

    # US-41.3 review: `:provider_mismatch` (the chat client resolved a DIFFERENT
    # provider than the one it guards — reachable via the settings race the guards
    # exist for) is a deterministic CONFIGURATION state. Retrying re-resolves the
    # same settings and refuses identically, so it must not burn max_attempts.
    test "a :provider_mismatch extraction failure is PERMANENT (discarded, not retried)" do
      %{tenant: tenant} = setup_tenant()

      Mox.stub(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                       _chunk,
                                                                       _opts ->
        {:error, :provider_mismatch}
      end)

      assert {:discard, {:extraction_failed, reason}} =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 413,
                 args: %{
                   "tenant_id" => tenant.id,
                   "content" => multi_chunk_content(3),
                   "content_hash" => "provider_mismatch_permanent",
                   "source_type" => "newsletter"
                 }
               })

      assert reason =~ "not retryable"
    end

    test "unique config excludes :completed so under-captured content can be resubmitted (#264 Finding 2)" do
      states =
        ContentIngestionWorker.__opts__() |> Keyword.fetch!(:unique) |> Keyword.fetch!(:states)

      refute :completed in states
      assert :available in states
      assert :executing in states
    end

    test "a retry writes NO phantom content_ingested audit entries for conflict-skipped chunks (#264 review F1)" do
      %{tenant: tenant} = setup_tenant()

      job_args = %{
        "tenant_id" => tenant.id,
        "content" => multi_chunk_content(3),
        "content_hash" => "audit_no_phantom",
        "source_type" => "newsletter"
      }

      call = :counters.new(1, [])

      Mox.stub(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                       _chunk,
                                                                       _opts ->
        :counters.add(call, 1, 1)
        n = :counters.get(call, 1)
        {:ok, [%{title: "Phantom check #{n}", body: "Body #{n}.", category: :pattern}]}
      end)

      assert :ok = ContentIngestionWorker.perform(%Oban.Job{id: 420, args: job_args})

      {:ok, %{data: after_first}} =
        Loopctl.Audit.list_entries(tenant.id, action: "knowledge.content_ingested")

      # 3 chunks -> 3 real content_ingested audit entries (one per chunk).
      assert length(after_first) == 3

      # Every audit entry points at a REAL persisted row (no phantom ids).
      persisted_ids =
        Knowledge.list_articles(tenant.id, source_type: "newsletter").data
        |> MapSet.new(& &1.id)

      audited_ids =
        after_first
        |> Enum.flat_map(& &1.new_state["article_ids"])
        |> MapSet.new()

      assert MapSet.subset?(audited_ids, persisted_ids)

      # Retry (identical args): every chunk conflict-skips -> NO new rows AND NO new
      # content_ingested audit entries (the phantom-audit defect).
      assert :ok = ContentIngestionWorker.perform(%Oban.Job{id: 420, args: job_args})

      {:ok, %{data: after_retry}} =
        Loopctl.Audit.list_entries(tenant.id, action: "knowledge.content_ingested")

      assert length(after_retry) == 3, "retry wrote phantom audit entries"
    end

    test "a title collision with an existing article is PERMANENT: discarded, not retried (#264 review F2)" do
      %{tenant: tenant} = setup_tenant()

      # A pre-existing ACTIVE article whose title the extractor will re-emit. The
      # idempotency conflict target does NOT cover the title index, so insert_all
      # raises a unique_violation — which must be classified permanent (discard),
      # not burn all 3 retries.
      _existing =
        fixture(:article, %{tenant_id: tenant.id, title: "Clash Title", status: :published})

      Mox.stub(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                       _chunk,
                                                                       _opts ->
        {:ok, [%{title: "Clash Title", body: "A different body.", category: :pattern}]}
      end)

      assert {:discard, {:extraction_failed, reason}} =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 421,
                 args: %{
                   "tenant_id" => tenant.id,
                   "content" => "small content",
                   "content_hash" => "title_clash",
                   "source_type" => "newsletter"
                 }
               })

      assert reason =~ "not retryable"
    end

    test "when NO chunk succeeds, the error propagates so Oban retries (nothing persisted)" do
      %{tenant: tenant} = setup_tenant()

      Mox.stub(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                       _chunk,
                                                                       _opts ->
        {:error, {:request_failed, :timeout}}
      end)

      assert {:error, {:request_failed, :timeout}} =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 402,
                 args: %{
                   "tenant_id" => tenant.id,
                   "content" => multi_chunk_content(3),
                   "content_hash" => "all_fail",
                   "source_type" => "newsletter"
                 }
               })

      assert %{data: []} = Knowledge.list_articles(tenant.id, source_type: "newsletter")
    end

    test "a tiny single-chunk input still ingests" do
      %{tenant: tenant} = setup_tenant()

      expect(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                     _content,
                                                                     _opts ->
        {:ok, [%{title: "Tiny", body: "Small.", category: :pattern}]}
      end)

      assert :ok =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 403,
                 args: %{
                   "tenant_id" => tenant.id,
                   "content" => "just a little text",
                   "content_hash" => "tiny",
                   "source_type" => "newsletter"
                 }
               })

      %{data: articles} = Knowledge.list_articles(tenant.id, source_type: "newsletter")
      assert length(articles) == 1
    end
  end

  # --- #264: the job timeout scales with chunk count (bounded by the cap) ---

  describe "timeout/1 scales with chunk count (#264)" do
    test "a single-chunk job gets the base 60s budget" do
      job = %Oban.Job{args: %{"content" => "small", "content_hash" => "t", "source_type" => "x"}}
      # per-chunk budget is now DB-backed (SystemConfig), default 60s.
      assert ContentIngestionWorker.timeout(job) == :timer.seconds(60)
    end

    test "a multi-chunk job gets a larger, chunk-scaled budget" do
      small = %Oban.Job{args: %{"content" => "small", "source_type" => "x"}}

      big = %Oban.Job{
        args: %{"content" => multi_chunk_content(4), "source_type" => "x"}
      }

      big_timeout = ContentIngestionWorker.timeout(big)

      assert big_timeout > ContentIngestionWorker.timeout(small)
      # 4 chunks * 60s = 240s, still under the 6-min cap.
      assert big_timeout == 4 * :timer.seconds(60)
    end

    test "the timeout is hard-capped for a very large document" do
      # 40 sections -> ~40 chunks; 40 * 60s = 2400s would blow past the cap, so
      # the timeout must clamp to the 6-minute ceiling.
      huge = %Oban.Job{args: %{"content" => multi_chunk_content(40), "source_type" => "x"}}
      assert ContentIngestionWorker.timeout(huge) == :timer.minutes(6)
    end

    test "a URL job (unknown size pre-fetch) is granted the full capped budget" do
      job = %Oban.Job{args: %{"url" => "https://example.com/x", "source_type" => "x"}}
      assert ContentIngestionWorker.timeout(job) == :timer.minutes(6)
    end
  end

  # --- #264: an oversized document is discarded cleanly with partial progress ---

  describe "perform/1 oversized document (#264)" do
    test "a document exceeding the per-job chunk budget persists what fits, then discards cleanly" do
      %{tenant: tenant} = setup_tenant()

      # 14 sections -> 14 chunks, above the 6-chunk per-job budget (max_job 6min /
      # per_chunk 60s). Each chunk yields one article; the first 6 persist, the
      # rest are discarded.
      Mox.stub(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                       _chunk,
                                                                       _opts ->
        {:ok,
         [
           %{
             title: "Oversized #{System.unique_integer([:positive])}",
             body: "Body.",
             category: :pattern
           }
         ]}
      end)

      assert {:discard, {:document_too_large, reason}} =
               ContentIngestionWorker.perform(%Oban.Job{
                 id: 404,
                 args: %{
                   "tenant_id" => tenant.id,
                   "content" => multi_chunk_content(14),
                   "content_hash" => "oversized",
                   "source_type" => "newsletter"
                 }
               })

      assert reason =~ "too large"

      # The @max_articles cap (10) bounds what actually persists, but the point is
      # that partial work IS committed rather than everything lost.
      %{meta: %{total_count: total}} =
        Knowledge.list_articles(tenant.id, source_type: "newsletter")

      assert total > 0
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
