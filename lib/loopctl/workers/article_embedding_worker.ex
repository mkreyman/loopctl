defmodule Loopctl.Workers.ArticleEmbeddingWorker do
  @moduledoc """
  Oban worker that generates and stores vector embeddings for articles.

  Runs in the `:embeddings` queue with concurrency 5. When an article is
  created or updated with content changes (title/body) and is in `:published`
  status, this worker is enqueued to generate an embedding vector via the
  configured embedding client.

  ## Flow

  1. Fetch the article by `article_id` + `tenant_id`
  2. If article was deleted, return `:ok` (no-op)
  3. Build embedding text: `"{title}\\n\\n{body}"` truncated to 32K chars
  4. Call `@embedding_client.generate_embedding/1`
  5. On success, store via `Knowledge.update_embedding/3`
  6. On failure, return `{:error, reason}` for Oban retry

  ## Retry Strategy

  Uses a custom polynomial backoff: `attempt^4 + 15 + rand(0..30*attempt)`.
  With `max_attempts: 4`, approximate delays are ~16s, ~31s, ~96s, ~271s.

  ## Uniqueness

  Unique per `article_id` within a 300-second window. If a new job is
  inserted for the same article while one is pending, it replaces the
  existing job.

  ## Linking (AC-20.3.13)

  Once `Loopctl.Workers.ArticleLinkingWorker` (US-21.2) is implemented,
  this worker should enqueue it on successful embedding. Add the enqueue
  call inside `generate_and_store/3` after `update_embedding` succeeds.
  """

  use Oban.Worker,
    queue: :embeddings,
    max_attempts: 4,
    unique: [keys: [:article_id], period: 300],
    replace: [scheduled: [:args, :scheduled_at]]

  require Logger

  alias Loopctl.Knowledge
  alias Loopctl.Workers.ArticleLinkingWorker

  @embedding_client Application.compile_env(
                      :loopctl,
                      :embedding_client,
                      Loopctl.Knowledge.EmbeddingClient
                    )

  @max_text_length 32_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"article_id" => article_id, "tenant_id" => tenant_id}}) do
    case Knowledge.get_article(tenant_id, article_id) do
      {:error, :not_found} ->
        # Article deleted -- no-op
        :ok

      {:ok, article} ->
        generate_and_store(article, tenant_id, article_id)
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    trunc(:math.pow(attempt, 4) + 15 + :rand.uniform(30) * attempt)
  end

  defp generate_and_store(article, tenant_id, article_id) do
    text = build_embedding_text(article)

    with {:ok, embedding} <- @embedding_client.generate_embedding(text),
         {:ok, _article} <- Knowledge.update_embedding(tenant_id, article_id, embedding) do
      enqueue_linking(article_id, tenant_id)
      :ok
    end
  end

  defp enqueue_linking(article_id, tenant_id) do
    ArticleLinkingWorker.new(%{
      article_id: article_id,
      tenant_id: tenant_id
    })
    |> Oban.insert()
  end

  defp build_embedding_text(article) do
    "#{article.title}\n\n#{article.body}"
    |> String.slice(0, @max_text_length)
  end
end
