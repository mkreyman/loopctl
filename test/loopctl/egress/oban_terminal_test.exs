defmodule Loopctl.Egress.ObanTerminalTest do
  @moduledoc """
  US-41.4 (AC-41.4.3, TC-41.4.15) — `:egress_blocked` is TERMINAL for Oban.

  The `{:cancel, :egress_blocked}` clauses are already unit-covered per worker. What
  this file proves is the CONSEQUENCE those clauses exist for: a batch of embedding
  jobs run against a `local_only` scope on a vendor endpoint leaves NO retry
  backlog. `{:error, _}` would retry each job with backoff until `max_attempts`,
  repopulating the queue on every subsequent write against a configuration that
  cannot change on its own; `{:snooze, _}` would re-check forever. Both would turn
  one enable into an unbounded queue.

  `async: false`: the drain runs jobs through the real Oban queue (inserted under a
  process-scoped `:manual` testing mode), and the counts asserted below are
  queue-wide.
  """

  use Loopctl.DataCase, async: false
  use Oban.Testing, repo: Loopctl.Repo

  import Ecto.Query
  import Mox

  alias Loopctl.Egress
  alias Loopctl.Egress.PinCache
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.EmbeddingClient
  alias Loopctl.Llm
  alias Loopctl.Workers.ArticleEmbeddingWorker

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant)

    {:ok, _} =
      Llm.upsert_settings(tenant.id, %{
        "embedding_api_key" => "test-openai-key-EGRESS-OBAN",
        "embedding_model" => "text-embedding-3-small"
      })

    # The REAL client, so the refusal comes from the actual chokepoint.
    stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn scope, text ->
      EmbeddingClient.generate_embedding(scope, text)
    end)

    test_pid = self()

    Req.Test.stub(EmbeddingClient, fn conn ->
      send(test_pid, :unexpected_http_call)
      Req.Test.json(conn, %{"data" => [%{"index" => 0, "embedding" => [0.0]}]})
    end)

    {:ok, _} = Egress.enable_local_only(tenant.id, nil, acknowledge: true)
    PinCache.invalidate_tenant(tenant.id)
    on_exit(fn -> PinCache.invalidate_tenant(tenant.id) end)

    {:ok, tenant: tenant}
  end

  defp published_article(tenant_id) do
    {:ok, article} =
      Knowledge.create_article(tenant_id, %{
        title: "Egress terminal #{System.unique_integer([:positive])}",
        body: "Body #{System.unique_integer([:positive])}",
        category: :pattern,
        status: :draft
      })

    article
    |> Ecto.Changeset.change(%{status: :published})
    |> Loopctl.AdminRepo.update!()
  end

  defp job_states(queue) do
    Loopctl.Repo.all(
      from j in "oban_jobs",
        where: j.queue == ^queue,
        group_by: j.state,
        select: {j.state, count(j.id)}
    )
    |> Map.new()
  end

  describe "a batch against a blocked scope accumulates NO retry backlog (TC-41.4.15)" do
    test "every job CANCELS; nothing is left available/retryable/scheduled", %{tenant: tenant} do
      articles = for _i <- 1..5, do: published_article(tenant.id)

      Oban.Testing.with_testing_mode(:manual, fn ->
        for article <- articles do
          {:ok, _} =
            %{"tenant_id" => tenant.id, "article_id" => article.id}
            |> ArticleEmbeddingWorker.new()
            |> Oban.insert()
        end

        assert 5 == Enum.count(all_enqueued(worker: ArticleEmbeddingWorker))

        # `with_safety: false` would re-raise; these jobs must return cleanly.
        assert %{cancelled: 5} = drained = Oban.drain_queue(queue: :embeddings)

        # The terminal outcome is CANCELLED — never a failure/retry.
        assert Map.get(drained, :failure, 0) == 0
        assert Map.get(drained, :snoozed, 0) == 0

        states = job_states("embeddings")

        # The whole point: no backlog. A retrying job would sit in `retryable` (or be
        # re-scheduled), and every subsequent article write would add another.
        assert Map.get(states, "retryable", 0) == 0
        assert Map.get(states, "available", 0) == 0
        assert Map.get(states, "scheduled", 0) == 0
        assert Map.get(states, "cancelled", 0) == 5
      end)

      # No data ever left the boundary.
      refute_received :unexpected_http_call
    end

    test "the cancel reason is the DISTINCT :egress_blocked, not a generic failure",
         %{tenant: tenant} do
      article = published_article(tenant.id)

      assert {:cancel, :egress_blocked} =
               perform_job(ArticleEmbeddingWorker, %{
                 "tenant_id" => tenant.id,
                 "article_id" => article.id
               })

      refute_received :unexpected_http_call
    end

    test "the breaker stays CLOSED across the whole batch (a refusal is not a provider failure)",
         %{tenant: tenant} do
      Knowledge.reset_circuit_breaker(tenant.id)
      articles = for _i <- 1..5, do: published_article(tenant.id)

      for article <- articles do
        assert {:cancel, :egress_blocked} =
                 perform_job(ArticleEmbeddingWorker, %{
                   "tenant_id" => tenant.id,
                   "article_id" => article.id
                 })
      end

      # Still the egress refusal — NOT :circuit_open, which is what a countable
      # failure run of this length would have produced.
      assert {:error, :egress_blocked} = Knowledge.generate_embedding(tenant.id, "anything")
    end
  end
end
