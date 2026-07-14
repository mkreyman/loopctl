defmodule Loopctl.Workers.ArticleEmbeddingWorker do
  @moduledoc """
  Oban worker that generates and stores vector embeddings for articles.

  Runs in the `:embeddings` queue with concurrency 5. When an article is
  created or updated with content changes (title/body) and is in `:published`
  status, this worker is enqueued to generate an embedding vector via the
  configured embedding client.

  ## Flow

  1. Fetch the article (with its embedding + content-hash) by `article_id` + `tenant_id`
  2. If article was deleted, return `:ok` (no-op)
  3. Build embedding text: `"{title}\\n\\n{body}"` truncated to 32K chars
  4. IDEMPOTENCY (review #12): if the article already carries an embedding whose
     stored content-hash matches the current content, skip the paid provider call
     entirely (re-ensure linking, return `:ok`). This stops an Oban retry after a
     post-embed failure from re-billing the tenant for identical content.
  5. Otherwise generate via the GUARDED `Knowledge.generate_embedding/3` (review #4:
     tenant-scoped circuit breaker + timeout) and store via `Knowledge.update_embedding/4`
  6. On `{:error, :no_api_key}` (mandatory BYO — the tenant has no embedding key),
     `{:discard, {:no_embedding_key, article_id}}` — a CLEAN skip: no crash, no
     retry, no operator-key fallback. The article stays created; it is simply not
     vector-searchable until the tenant configures a key.
  7. On a PERMANENT provider error (a 4xx other than 408/429 — bad/revoked key),
     `{:discard, {:embedding_permanent_error, _}}` (review #5): retrying a revoked
     key 3× is pointless. Transient errors (5xx / network / timeout / circuit-open)
     return `{:error, reason}` for Oban retry.

  ## Retry Strategy

  Uses a custom polynomial backoff: `attempt^4 + 15 + rand(0..30*attempt)`.
  With `max_attempts: 4`, approximate delays are ~16s, ~31s, ~96s, ~271s.

  ## Uniqueness

  Unique per `article_id` within a 300-second window. If a new job is
  inserted for the same article while one is pending, it replaces the
  existing job.
  """

  use Oban.Worker,
    queue: :embeddings,
    max_attempts: 4,
    unique: [keys: [:article_id], period: 300],
    replace: [scheduled: [:args, :scheduled_at]]

  require Logger

  alias Loopctl.Knowledge
  alias Loopctl.Llm
  alias Loopctl.Llm.ProviderError
  alias Loopctl.Workers.ArticleLinkingWorker

  # Longer Task.yield budget than the interactive query path: a background embed can
  # afford a little more headroom, but still bounded so a wedged provider can't pin a
  # worker. The client itself caps a single attempt at ~4s (no client retries), so
  # this only adds slack for scheduling/DB.
  @worker_yield_ms 8_000
  @max_text_length 32_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"article_id" => article_id, "tenant_id" => tenant_id}}) do
    case Knowledge.get_article_with_embedding(tenant_id, article_id) do
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
    content_hash = content_hash(text)

    if already_embedded?(article, content_hash) do
      # Idempotent no-op: this exact content is already embedded (review #12). Ensure
      # linking is (re-)enqueued and finish — never re-call the paid provider.
      enqueue_linking(article_id, tenant_id)
      :ok
    else
      generate(tenant_id, article_id, text, content_hash)
    end
  end

  defp generate(tenant_id, article_id, text, content_hash) do
    case Knowledge.generate_embedding(tenant_id, text, timeout: @worker_yield_ms) do
      {:ok, embedding} ->
        store(tenant_id, article_id, embedding, content_hash)

      {:error, :no_api_key} ->
        skip_no_embedding_key(tenant_id, article_id)

      {:error, reason} ->
        # Classify on the raw reason, but the term that becomes an Oban discard/error
        # reason (-> oban_jobs.errors) is SANITIZED (review #5/#6) — never a raw body.
        # US-34.3 (review MED #1): the `[:loopctl, :llm, :provider_error]` telemetry
        # signal is now recorded ONCE, upstream, in
        # `Loopctl.Knowledge.run_embedding_task/3` — the single choke point shared by
        # this worker AND every query-time embedding caller. Do NOT re-record here.
        sanitized = ProviderError.sanitize(reason)

        if Llm.permanent_provider_error?(reason) do
          # A revoked/invalid tenant key (4xx) will never succeed on retry (review #5).
          Logger.debug(
            "ArticleEmbeddingWorker: tenant=#{tenant_id} article=#{article_id} permanent " <>
              "embedding error (#{ProviderError.log_tag(reason)}); discarding."
          )

          {:discard, {:embedding_permanent_error, sanitized}}
        else
          {:error, sanitized}
        end
    end
  end

  defp store(tenant_id, article_id, embedding, content_hash) do
    with {:ok, _article} <-
           Knowledge.update_embedding(tenant_id, article_id, embedding, content_hash) do
      enqueue_linking(article_id, tenant_id)
      :ok
    end
  end

  defp already_embedded?(%{embedding: embedding, embedding_content_hash: hash}, content_hash)
       when not is_nil(embedding) and is_binary(hash),
       do: hash == content_hash

  defp already_embedded?(_article, _content_hash), do: false

  defp content_hash(text) do
    :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)
  end

  # Mandatory BYO: the tenant has no embedding key. Cleanly DISCARD (no retry, no
  # crash, no operator-key fallback) with a distinct, queryable reason + a telemetry
  # signal AND an audit entry (review #9) so the keyless-tenant volume is observable
  # and consistent with the Anthropic mandatory-BYO path.
  defp skip_no_embedding_key(tenant_id, article_id) do
    :telemetry.execute(
      [:loopctl, :embedding, :skipped_no_key],
      %{count: 1},
      # `source: "article"` is the ONE bounded metadata tag US-34.4 (AC-34.4.4) adds at
      # this emit site — lets the `loopctl.embedding.skipped_no_key.count` counter
      # (`Loopctl.Telemetry.ScaleMetrics`) distinguish article vs memory skips without
      # tagging the unbounded `article_id`.
      %{tenant_id: tenant_id, article_id: article_id, source: "article"}
    )

    Llm.record_blocked(tenant_id, :embedding)

    Logger.debug(
      "ArticleEmbeddingWorker: tenant=#{tenant_id} article=#{article_id} skipped — no " <>
        "embedding API key configured (mandatory BYO)."
    )

    {:discard, {:no_embedding_key, article_id}}
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
