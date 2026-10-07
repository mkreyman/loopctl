defmodule Loopctl.Workers.BatchArticleEmbeddingWorkerTest do
  @moduledoc """
  US-37.4: the batch background embedding worker. Embeds a chunk of articles in ONE
  provider array call, maps vectors back by index, and mirrors the single-article
  worker's error taxonomy — while keeping the interactive memory/promotion path
  per-record (that write-then-recall guarantee is covered by the memory suite).

  The tests that move a `SystemConfig` knob (`embedding_batch_max`, the char and yield
  budgets, the breaker's latency trip) seed it in their OWN namespace and hand that
  namespace to the code — `Knowledge.bulk_publish/3`'s `:system_config`,
  `BatchArticleEmbeddingWorker.perform/2`, `Knowledge.embedding_batch_max/1` — so the
  node-wide knobs every other test reads never move.
  """
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  alias Loopctl.Embeddings.TextBudget
  alias Loopctl.Knowledge
  alias Loopctl.Workers.BatchArticleEmbeddingWorker

  # A deterministic 1536-dim vector keyed to the text, so single-call and batch-call
  # embeddings of the SAME input are byte-for-byte equal (TC-37.4.3). The first slot
  # encodes the text's hash; the rest pad to the model's dimensionality.
  defp vec_for(text) do
    seed = :erlang.phash2(text) / 1_000_000
    [seed | List.duplicate(0.1, 1535)]
  end

  # Create a published article WITHOUT the inline create-time embedding enqueue
  # firing: create as draft, then flip to published via a bare changeset (bypasses
  # the context's enqueue) — mirrors ArticleEmbeddingWorkerTest.
  defp create_published_article(tenant_id, attrs \\ %{}) do
    base = %{
      title: "Batch Article #{System.unique_integer([:positive])}",
      body: "Body #{System.unique_integer([:positive])}",
      category: :pattern,
      status: :draft
    }

    {:ok, article} = Knowledge.create_article(tenant_id, Map.merge(base, attrs))

    article
    |> Ecto.Changeset.change(%{status: :published})
    |> Loopctl.AdminRepo.update!()
  end

  # `cache` is the `SystemConfig` namespace the worker reads its tunables from — the
  # node-wide one unless the test seeded its own with `put_cfg/3`.
  defp perform(tenant_id, article_ids, cache \\ Loopctl.SystemConfig) do
    BatchArticleEmbeddingWorker.perform(
      %Oban.Job{
        id: System.unique_integer([:positive]),
        args: %{"article_ids" => article_ids, "tenant_id" => tenant_id}
      },
      cache
    )
  end

  describe "batch efficiency (AC-37.4.2)" do
    test "embeds N articles in ONE provider array call, storing each" do
      tenant = fixture(:tenant)
      test_pid = self()

      articles = for _ <- 1..5, do: create_published_article(tenant.id)
      ids = Enum.map(articles, & &1.id)

      # A single batch call for all 5 texts (not 5 calls). Send a message per call so
      # we count WITHOUT a Mox exact-count race across the async_nolink task.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _tenant_id, texts ->
        send(test_pid, {:batch_call, length(texts)})
        {:ok, Enum.map(texts, &vec_for/1)}
      end)

      assert :ok = perform(tenant.id, ids)

      # Exactly ONE provider round-trip covered all 5 records.
      assert_received {:batch_call, 5}
      refute_received {:batch_call, _}

      for a <- articles do
        {:ok, loaded} = Knowledge.get_article_with_embedding(tenant.id, a.id)
        assert loaded.embedding != nil
      end
    end

    test "TC-37.4.2: bulk publish of M records issues ceil(M/batch_max) provider calls, not M" do
      tenant = fixture(:tenant)
      test_pid = self()

      # batch_max from this test's own SystemConfig namespace, handed to bulk_publish.
      # Small value keeps the test cheap: 5 records / batch_max 2 => ceil = 3 calls.
      cache = own_config()
      put_cfg(cache, "embedding_batch_max", 2)

      # 5 DRAFTS (no create-time enqueue), published together via bulk_publish. Oban is
      # :inline in test, so the enqueued batch workers execute synchronously.
      drafts =
        for _ <- 1..5 do
          {:ok, a} =
            Knowledge.create_article(tenant.id, %{
              title: "Bulk #{System.unique_integer([:positive])}",
              body: "bulk body",
              category: :pattern,
              status: :draft
            })

          a
        end

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _tenant_id, texts ->
        send(test_pid, {:batch_call, length(texts)})
        {:ok, Enum.map(texts, &vec_for/1)}
      end)

      assert {:ok, %{counts: %{published: 5}}} =
               Knowledge.bulk_publish(tenant.id, Enum.map(drafts, & &1.id), system_config: cache)

      # ceil(5 / 2) = 3 provider calls (chunks of 2, 2, 1) — NOT 5.
      calls = drain_batch_calls([])
      assert length(calls) == 3
      assert Enum.sort(calls, :desc) == [2, 2, 1]
    end
  end

  describe "correctness (TC-37.4.3)" do
    test "each record gets the SAME vector it would from a single-text call" do
      tenant = fixture(:tenant)

      texts = ["distinct alpha", "distinct beta", "distinct gamma"]

      # Deterministic per-text vectors on BOTH the single and batch callbacks.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, text ->
        {:ok, vec_for(text)}
      end)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _t, batch ->
        {:ok, Enum.map(batch, &vec_for/1)}
      end)

      singles =
        Enum.map(texts, fn t ->
          {:ok, v} = Knowledge.generate_embedding(tenant.id, t)
          v
        end)

      {:ok, batched} = Knowledge.generate_embeddings(tenant.id, texts)

      # Per-index equality: batch vectors == the single-call vectors, in input order.
      assert batched == singles
    end
  end

  describe "partial-failure = whole-batch retry (TC-37.4.4)" do
    test "a provider error writes NO vectors and returns {:error, _} (retry as a unit)" do
      tenant = fixture(:tenant)

      articles = for _ <- 1..3, do: create_published_article(tenant.id)
      ids = Enum.map(articles, & &1.id)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _t, _texts ->
        {:error, {:api_error, 500, :provider_error}}
      end)

      assert {:error, {:api_error, 500, :provider_error}} = perform(tenant.id, ids)

      # No half-write: every article is still un-embedded.
      for a <- articles do
        {:ok, loaded} = Knowledge.get_article_with_embedding(tenant.id, a.id)
        assert loaded.embedding == nil
      end
    end
  end

  describe "error taxonomy (mirrors ArticleEmbeddingWorker)" do
    setup do
      tenant = fixture(:tenant)
      article = create_published_article(tenant.id)
      %{tenant: tenant, ids: [article.id]}
    end

    test "no_api_key → discard (mandatory BYO), no crash", %{tenant: tenant, ids: ids} do
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _t, _texts ->
        {:error, :no_api_key}
      end)

      assert {:discard, {:no_embedding_key, _ids}} = perform(tenant.id, ids)
    end

    test "rate_limited_local → loss-free snooze", %{tenant: tenant, ids: ids} do
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _t, _texts ->
        {:error, :rate_limited_local}
      end)

      assert {:snooze, s} = perform(tenant.id, ids)
      assert is_integer(s) and s > 0
    end

    test "permanent 4xx → discard (not retried)", %{tenant: tenant, ids: ids} do
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _t, _texts ->
        {:error, {:api_error, 401, :provider_error}}
      end)

      assert {:discard, {:embedding_permanent_error, {:api_error, 401, _}}} =
               perform(tenant.id, ids)
    end

    test "context_length_exceeded → dissolved into single-article jobs, not discarded" do
      # The provider fails the WHOLE array and never says which input was too long.
      # Discarding would strand every article in the batch; shrinking every text
      # would truncate the innocent ones. So the batch is re-enqueued per article and
      # the per-article ladder pays the cost only where it is owed.
      tenant = fixture(:tenant)
      articles = for _ <- 1..3, do: create_published_article(tenant.id)
      ids = Enum.map(articles, & &1.id)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _t, _texts ->
        {:error, {:api_error, 400, :context_length_exceeded}}
      end)

      # Oban runs `testing: :inline`, so the re-enqueued single jobs execute here.
      # Asserting the OUTCOME is stronger than asserting the enqueue anyway: it
      # proves the dissolve actually rescues the articles rather than just moving
      # them to another queue.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, text ->
        {:ok, vec_for(text)}
      end)

      assert :ok = perform(tenant.id, ids)

      for id <- ids do
        {:ok, stored} = Knowledge.get_article_with_embedding(tenant.id, id)

        refute is_nil(stored.embedding),
               "article #{id} was stranded by the batch rejection instead of being re-embedded"
      end
    end

    test "a NON-length 400 still discards — it is not dissolved into singles" do
      # Guards the classification, not the status: dissolving a malformed-request 400
      # would re-run every article individually against the same rejection.
      tenant = fixture(:tenant)
      article = create_published_article(tenant.id)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _t, _texts ->
        {:error, {:api_error, 400, :provider_error}}
      end)

      # No single-article fallout: if the batch dissolved, these inline jobs would
      # call generate_embedding/2 and this expectation would blow up on arity/count.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        flunk("a non-length 400 must NOT be dissolved into single-article jobs")
      end)

      assert {:discard, {:embedding_permanent_error, _}} = perform(tenant.id, [article.id])

      {:ok, stored} = Knowledge.get_article_with_embedding(tenant.id, article.id)
      assert is_nil(stored.embedding)
    end

    test "batch text is cut by the SAME initial rule as the single-article path" do
      # There is no ladder on the batch path — build_embedding_text/1 IS what gets
      # sent. Both workers write `embedding_content_hash` into one side table and read
      # each other's back as the no-re-bill guard, so a divergent cut here makes every
      # hash miss and re-bills the provider on every enqueue.
      tenant = fixture(:tenant)
      body = String.duplicate("я", 30_000)

      article = create_published_article(tenant.id, %{body: body})

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _t, texts ->
        for text <- texts do
          assert text == TextBudget.initial("#{article.title}\n\n#{body}"),
                 "batch text diverged from the single-article cut"

          assert String.valid?(text), "truncation split a UTF-8 codepoint"
        end

        {:ok, Enum.map(texts, &vec_for/1)}
      end)

      assert :ok = perform(tenant.id, [article.id])
    end

    test "a length rejection hands on the sub-batches BEHIND it too, not just its own" do
      # Continuing after a dissolve let a later sub-batch's snooze/error rerun the whole
      # job, which re-sent the rejected array — guaranteed to be rejected again, for a
      # second paid round trip. Once one array is rejected for length, this job stops
      # sending arrays: everything left goes to the per-article ladder.
      tenant = fixture(:tenant)
      test_pid = self()

      # One article per sub-batch: a tiny cumulative byte budget forces the split.
      cache = own_config()
      put_cfg(cache, "embedding_batch_max_chars", 1)

      articles = for _ <- 1..3, do: create_published_article(tenant.id)
      ids = Enum.map(articles, & &1.id)

      # Only the FIRST array call is rejected; the rest must never be sent as arrays.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _t, texts ->
        send(test_pid, {:batch_call, length(texts)})
        {:error, {:api_error, 400, :context_length_exceeded}}
      end)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, text ->
        {:ok, vec_for(text)}
      end)

      assert :ok = perform(tenant.id, ids, cache)

      assert_received {:batch_call, 1}
      refute_received {:batch_call, _}

      for id <- ids do
        {:ok, stored} = Knowledge.get_article_with_embedding(tenant.id, id)

        refute is_nil(stored.embedding),
               "article #{id} was stranded when the batch stopped sending arrays"
      end
    end

    test "throttle with Retry-After → snooze ~that interval", %{tenant: tenant, ids: ids} do
      Knowledge.reset_circuit_breaker(tenant.id)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _t, _texts ->
        {:error, {:api_error, 429, :provider_error, 30}}
      end)

      assert {:snooze, 30} = perform(tenant.id, ids)
    end

    test "OPEN breaker → loss-free snooze without a provider call", %{tenant: tenant, ids: ids} do
      Knowledge.reset_circuit_breaker(tenant.id)

      # Trip the tenant breaker via 3 countable 429s on the SINGLE path, then the batch
      # entry short-circuits on the OPEN breaker (deterministic ETS) before any call.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:error, {:api_error, 429, :provider_error}}
      end)

      for _ <- 1..3, do: Knowledge.generate_embedding(tenant.id, "x")
      assert {:error, :circuit_open} = Knowledge.generate_embedding(tenant.id, "x")

      assert {:snooze, s} = perform(tenant.id, ids)
      assert is_integer(s) and s > 0
    end
  end

  describe "idempotency" do
    test "an already-embedded article (matching content hash) is not re-embedded" do
      tenant = fixture(:tenant)
      test_pid = self()
      article = create_published_article(tenant.id)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _t, texts ->
        send(test_pid, {:batch_call, length(texts)})
        {:ok, Enum.map(texts, &vec_for/1)}
      end)

      # First run embeds the one article.
      assert :ok = perform(tenant.id, [article.id])
      assert_received {:batch_call, 1}

      # Second run (same content): the provider is NOT called — content-hash matches.
      assert :ok = perform(tenant.id, [article.id])
      refute_received {:batch_call, _}
    end
  end

  describe "tenant isolation" do
    test "batch worker only touches its own tenant's articles" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      test_pid = self()

      article = create_published_article(tenant_a.id)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _t, texts ->
        send(test_pid, {:batch_call, length(texts)})
        {:ok, Enum.map(texts, &vec_for/1)}
      end)

      # Run under tenant B with tenant A's article id: the scoped fetch returns nothing,
      # so no provider call and A's article is untouched.
      assert :ok = perform(tenant_b.id, [article.id])
      refute_received {:batch_call, _}

      {:ok, loaded} = Knowledge.get_article_with_embedding(tenant_a.id, article.id)
      assert loaded.embedding == nil
    end
  end

  describe "cumulative char budget (AC-37.4.4 review MED #2)" do
    test "sub-splits a count-chunk so no single array call exceeds embedding_batch_max_chars" do
      tenant = fixture(:tenant)
      test_pid = self()

      # Budget fits ~2 of these ~320-char texts per array call, not all 3. env-driven
      # WITHOUT Application.put_env (SystemConfig cache), erased on exit.
      cache = own_config()
      put_cfg(cache, "embedding_batch_max_chars", 700)

      body = String.duplicate("a", 300)

      articles =
        for i <- 1..3, do: create_published_article(tenant.id, %{title: "Chars #{i}", body: body})

      ids = Enum.map(articles, & &1.id)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _t, texts ->
        # No single provider array call exceeds the cumulative budget.
        assert Enum.sum(Enum.map(texts, &byte_size/1)) <= 700
        send(test_pid, {:batch_call, length(texts)})
        {:ok, Enum.map(texts, &vec_for/1)}
      end)

      assert :ok = perform(tenant.id, ids, cache)

      # 3 texts, budget fits 2 per call => 2 provider calls (sizes 2 + 1), NOT 1.
      assert Enum.sort(drain_batch_calls([]), :desc) == [2, 1]

      for a <- articles do
        {:ok, loaded} = Knowledge.get_article_with_embedding(tenant.id, a.id)
        assert loaded.embedding != nil
      end
    end
  end

  describe "batch yield budget (review MED #3)" do
    test "the Task.yield budget is live-tunable via SystemConfig and bounds a slow batch" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)

      a1 = create_published_article(tenant.id)
      a2 = create_published_article(tenant.id)

      # Every provider call takes ~200ms.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _t, texts ->
        Process.sleep(200)
        {:ok, Enum.map(texts, &vec_for/1)}
      end)

      # Tiny yield (20ms base + 1ms/item) < 200ms call => the guard shuts the task down
      # => transient error, NO vector written.
      cache = own_config()
      put_cfg(cache, "embedding_batch_yield_base_ms", 20)
      put_cfg(cache, "embedding_batch_yield_per_item_ms", 1)
      assert {:error, _} = perform(tenant.id, [a1.id], cache)
      {:ok, l1} = Knowledge.get_article_with_embedding(tenant.id, a1.id)
      assert l1.embedding == nil

      # Raise the SAME knob live (no redeploy): yield now 2000ms > 200ms => success.
      put_cfg(cache, "embedding_batch_yield_base_ms", 2000)
      assert :ok = perform(tenant.id, [a2.id], cache)
      {:ok, l2} = Knowledge.get_article_with_embedding(tenant.id, a2.id)
      assert l2.embedding != nil
    end
  end

  describe "latency-breaker exemption (review LOW #5)" do
    test "a slow batch success does NOT trip the per-tenant latency breaker" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)

      # Enable the latency trip aggressively: any call slower than 1ms is 'slow', and a
      # single slow call would trip — so the OLD (record_call_outcome) batch path would
      # have opened the breaker here.
      cache = own_config()
      put_cfg(cache, "embedding_breaker_latency_threshold_ms", 1)
      put_cfg(cache, "embedding_breaker_latency_count", 1)

      article = create_published_article(tenant.id)

      # Guarantee wall-clock > 1ms.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _t, texts ->
        Process.sleep(10)
        {:ok, Enum.map(texts, &vec_for/1)}
      end)

      assert :ok = perform(tenant.id, [article.id], cache)

      # Batch path is EXEMPT: the breaker stays CLOSED — a follow-up embedding call
      # reaches the provider instead of short-circuiting on {:error, :circuit_open}.
      refute match?({:error, :circuit_open}, Knowledge.generate_embeddings(tenant.id, ["probe"]))
    end
  end

  describe "embedding_batch_max/0 (AC-37.4.4)" do
    test "reads the live SystemConfig value" do
      cache = own_config()
      put_cfg(cache, "embedding_batch_max", 42)

      assert Knowledge.embedding_batch_max(cache) == 42
    end

    test "floors a non-positive tuned value at 1 (never an empty chunk)" do
      cache = own_config()
      put_cfg(cache, "embedding_batch_max", 0)

      assert Knowledge.embedding_batch_max(cache) == 1
    end
  end

  # Collect all {:batch_call, n} messages currently in the mailbox (batch workers ran
  # inline before bulk_publish returned, so they're all already delivered).
  defp drain_batch_calls(acc) do
    receive do
      {:batch_call, n} -> drain_batch_calls([n | acc])
    after
      0 -> acc
    end
  end

  # A SystemConfig namespace of this test's own — an ETS table this test process owns, gone
  # when it exits: a knob seeded into it reaches only the code this test hands it to.
  defp own_config, do: :ets.new(:batch_worker_config, [:set, :public])

  defp put_cfg(cache, key, value), do: :ets.insert(cache, {key, value})
end
